import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'queue.dart';

/// Main entry point for the Affiliateo SDK.
///
/// Initialize in your `main()` or `initState()`:
///
/// ```dart
/// await Affiliateo.configure(appId: 'YOUR_APP_ID');
/// ```
///
/// Access the attribution state:
/// ```dart
/// final state = Affiliateo.state;
/// if (state.isMatched) {
///   print('Referred by: ${state.refCode}');
/// }
/// ```
class Affiliateo with WidgetsBindingObserver {
  Affiliateo._();

  static final Affiliateo _instance = Affiliateo._();

  String _apiUrl = 'https://affiliateo.com';
  String? _campaignId;
  String? _deviceId;
  bool _configured = false;
  EventQueue? _queue;

  // Debug flag. When true, every SDK decision (init, page, track, identify,
  // flush, opt in/out, reset) is printed to the Flutter DevTools console
  // via dart:developer log(). Only useful during development. ship with
  // debug=false (the default) so production apps don't pay the log
  // overhead AND don't leak SDK internals to anyone running their app
  // attached to a debugger. Mirrors @affiliateo/web, affiliateo-swift,
  // affiliateo-kotlin.
  bool _debug = false;

  // Persistent opt-out flag. Mirrors the rest of the SDK family
  // (@affiliateo/web 3.0.0, @affiliateo/react-native 4.0.0,
  // affiliateo-swift, affiliateo-kotlin). Stored in SharedPreferences
  // so the flag survives app restart. Hot-path check inside every
  // page/track/identify call so a mid-session decision applies
  // immediately without waiting for the next launch.
  static const _optOutKey = 'affiliateo_opt_out';
  bool _optedOut = false;

  static AffiliateoState _state = const AffiliateoState();

  /// Current attribution state.
  static AffiliateoState get state => _state;

  /// Configure and start the Affiliateo SDK.
  /// Call this once at app startup.
  ///
  /// Pass your app ID via [appId]. The [campaignId] parameter is the
  /// pre-4.5.0 name for the same value (Affiliateo campaigns are now
  /// called apps) and keeps working; [appId] wins when both are set.
  ///
  /// Pass `debug: true` (typically gated on `kDebugMode`) to print every
  /// SDK decision to the Flutter DevTools console. Defaults to false.
  static Future<void> configure({
    String? appId,
    @Deprecated('Affiliateo campaigns are now apps — use appId') String? campaignId,
    String apiUrl = 'https://affiliateo.com',
    bool debug = false,
    int flushIntervalMs = 5000,
    int maxQueueSize = 100,
  }) async {
    final resolvedAppId = appId ?? campaignId;
    if (resolvedAppId == null) {
      developer.log('Missing appId — pass your app ID to Affiliateo.configure().', name: 'Affiliateo');
      return;
    }
    if (_instance._configured) return;
    _instance._configured = true;
    _instance._campaignId = resolvedAppId;
    _instance._apiUrl = apiUrl.endsWith('/') ? apiUrl.substring(0, apiUrl.length - 1) : apiUrl;
    // Pick up the debug flag BEFORE any other side effect so the next _log
    // call (in the opted-out branch or _identify below) actually fires.
    _instance._debug = debug;
    _instance._log('init', {'app': resolvedAppId});

    // Hydrate opt-out flag BEFORE anything else touches the network. A
    // previously opted-out user staying opted out is the whole point of
    // persistence.
    final prefs = await SharedPreferences.getInstance();
    _instance._optedOut = prefs.getString(_optOutKey) == 'true';

    // Get stable device ID
    _instance._deviceId = await _instance._getStableDeviceId();

    if (_instance._optedOut) {
      _instance._log('blocked: opted out (call optIn() to re-enable)');
      // Opted-out path: skip identify + foreground ping entirely. Set
      // isLoading=false so any host UI gated on it unblocks. Public
      // methods stay available and noop until optIn() flips the flag.
      _state = const AffiliateoState(isLoading: false);
      return;
    }

    // Initialize the event queue. Constructor kicks off async hydration
    // from SharedPreferences and starts the connectivity listener +
    // periodic flush timer in the background. Queue tuning is clamped
    // inside EventQueue so out-of-range values can't break things.
    _instance._queue = EventQueue(
      flushIntervalMs: flushIntervalMs,
      maxQueueSize: maxQueueSize,
    );

    // Listen for app lifecycle (foreground keep-alive only). Screens are
    // NOT auto-tracked. the host app calls Affiliateo.page(name) per
    // screen, matching the Mixpanel / Amplitude mobile model.
    // predictable + debuggable + no ghost events.
    WidgetsBinding.instance.addObserver(_instance);

    await _instance._identify();
  }

  /// Fire a screen_view event for a specific screen.
  /// Call from `initState()` of each screen or from a route observer.
  /// Returns immediately; the queue handles delivery + retry.
  static Future<void> page(String screenName, [Map<String, dynamic>? metadata]) async {
    if (_instance._optedOut) return;
    _instance._log('page', {'screen': screenName, 'metadata': metadata});
    _instance._enqueueEvent({
      'type': 'screen_view',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'screen': screenName,
      if (metadata != null) 'metadata': metadata,
    });
  }

  /// Fire a custom event with arbitrary name + metadata. Returns
  /// immediately; the queue handles delivery + retry.
  static Future<void> track(String eventName, [Map<String, dynamic>? metadata]) async {
    if (_instance._optedOut) return;
    _instance._log('track', {'event': eventName, 'metadata': metadata});
    final merged = <String, dynamic>{'event': eventName};
    if (metadata != null) merged.addAll(metadata);
    _instance._enqueueEvent({
      'type': 'custom',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'metadata': merged,
    });
  }

  /// Link this anonymous device install to a merchant user_id so the
  /// funnel can stitch the same person across devices, reinstalls,
  /// and the anonymous to logged-in handoff. Call once after sign-in.
  /// Idempotent: safe to call on every app launch when a user is
  /// signed in.
  ///
  /// user_id only. the SDK does NOT accept, collect, or transmit
  /// email or any other PII. Best-effort: network failures are
  /// swallowed so analytics never breaks the host app.
  static Future<void> identify(String userId) async {
    if (_instance._optedOut) return;
    final cleanId = userId.trim();
    if (cleanId.isEmpty || cleanId.length > 128) return;
    final deviceId = _instance._deviceId;
    final campaignId = _instance._campaignId;
    if (deviceId == null || campaignId == null) return;
    _instance._log('identify (user)', {'user_id': cleanId});

    final body = <String, dynamic>{
      'campaign_id': campaignId,
      'device_id': deviceId,
      'user_id': cleanId,
    };

    try {
      await http.post(
        Uri.parse('${_instance._apiUrl}/api/v1/mobile/identify-user'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (_) {
      // Swallow. analytics never throws in the host app.
    }
  }

  /// Report the host app's RevenueCat App User ID (`Purchases.appUserID`).
  ///
  /// This is what lets an app owner grant an individual affiliate
  /// complimentary access to the app from their Affiliateo dashboard.
  /// Without it, Affiliateo can only match an affiliate to a RevenueCat
  /// customer by email, which requires the host app to be setting
  /// RevenueCat's `$email` attribute AND the affiliate to have used the same
  /// address they used on Affiliateo.
  ///
  /// Deliberately separate from [identify]: sign-in and RevenueCat
  /// configuration happen at different moments, and an app may do one without
  /// the other. The server accepts either field on its own and writes only
  /// what the request carried, so neither wipes the other.
  ///
  /// Write-once per device server-side. Re-sending the same id on every launch
  /// is a no-op; a DIFFERENT id for an already-bound device is rejected, so a
  /// tampered client cannot repoint an established device at somebody else's
  /// RevenueCat customer.
  ///
  /// Call after RevenueCat has configured. Failures are swallowed so analytics
  /// never breaks the host app.
  static Future<void> setRevenueCatUser(String appUserId) async {
    if (_instance._optedOut) return;
    final rcId = appUserId.trim();
    // 255 matches the server. RevenueCat's anonymous form
    // (`$RCAnonymousID:<32 hex>`) is already ~50 characters.
    if (rcId.isEmpty || rcId.length > 255) return;
    final deviceId = _instance._deviceId;
    final campaignId = _instance._campaignId;
    if (deviceId == null || campaignId == null) return;
    _instance._log('setRevenueCatUser', {'revenuecat_user_id': rcId});

    final body = <String, dynamic>{
      'campaign_id': campaignId,
      'device_id': deviceId,
      'revenuecat_user_id': rcId,
    };

    try {
      await http.post(
        Uri.parse('${_instance._apiUrl}/api/v1/mobile/identify-user'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (_) {
      // Swallow. analytics never throws in the host app.
    }
  }

  /// Wipe the device identity. Drains pending events first (they land
  /// server-side under the OLD device_id which is correct), then clears
  /// the queue, regenerates the device_id, and resets state. Call on
  /// app logout when a different user might sign in afterwards.
  static Future<void> reset() async {
    _instance._log('reset');
    await _instance._queue?.flush();
    await _instance._queue?.clear();
    // Clear the persisted UUID fallback so the next getStableDeviceId
    // call mints fresh. The platform IDFV / androidId is tied to the
    // install and can't be changed; only the UUID fallback gets fresh
    // entropy.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('affiliateo_device_id');
    _instance._deviceId = await _instance._getStableDeviceId();
    _state = const AffiliateoState(isLoading: false);
  }

  /// Stop tracking on this device. Sets a persistent opt-out flag in
  /// SharedPreferences and silences ALL subsequent page / track /
  /// identify calls until optIn() is called. Survives app restart.
  /// Pending queued events are dropped — the visitor explicitly said
  /// no, sending events captured before the decision would still
  /// violate consent. Use for GDPR/CCPA "Don't track me" consent.
  static Future<void> optOut() async {
    _instance._log('optOut');
    _instance._optedOut = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_optOutKey, 'true');
    await _instance._queue?.clear();
  }

  /// Re-enable tracking after a previous optOut(). Removes the
  /// persistent flag. To resume the auto session_start that fires on
  /// app foreground, the host should restart the app or call
  /// configure() again on a fresh process.
  static Future<void> optIn() async {
    _instance._log('optIn');
    _instance._optedOut = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_optOutKey);
  }

  /// Force-drain the event queue immediately. Useful before a known
  /// unrecoverable transition (entering an in-app purchase flow, app
  /// about to be backgrounded for a long time). Best-effort: if offline
  /// the flush noops and events stay queued for the next retry cycle.
  static Future<void> flush() async {
    _instance._log('flush requested');
    await _instance._queue?.flush();
  }

  /// Internal debug logger. No-op unless debug=true was passed to
  /// configure(). Goes through dart:developer log() with name='Affiliateo'
  /// so it shows up cleanly in DevTools / IDE consoles and survives the
  /// `flutter run` log filter.
  void _log(String msg, [Object? data]) {
    if (!_debug) return;
    if (data != null) {
      developer.log('$msg | $data', name: 'Affiliateo');
    } else {
      developer.log(msg, name: 'Affiliateo');
    }
  }

  /// Internal: enqueue a mobile event with the wire payload shape the
  /// server expects. Used by page() / track() and the foreground
  /// keep-alive ping.
  void _enqueueEvent(Map<String, dynamic> event) {
    final cid = _campaignId;
    final did = _deviceId;
    final queue = _queue;
    if (cid == null || did == null || queue == null) return;
    // Dedup key, stamped once HERE so it is fixed for the life of the queued
    // payload. Every retry then sends the identical id and the server, which
    // holds a unique index on it, keeps exactly one row.
    //
    // This is the choke point every event type flows through, so stamping
    // here rather than at each call site means a new event type cannot
    // forget it. It has to be at enqueue and not at send: the queue survives
    // app launches, and an id minted per attempt would differ every time,
    // which is precisely the duplicate this prevents.
    //
    // Without it, a request the server received and wrote but whose response
    // was lost on a flaky connection comes back on the next flush and counts
    // twice. For a `custom` event that is a duplicated funnel conversion.
    event.putIfAbsent('event_id', _generateUuidV4);
    queue.enqueue(
      '$_apiUrl/api/v1/mobile/event',
      {
        'campaign_id': cid,
        'device_id': did,
        'events': [event],
      },
    );
  }

  /// Get a stable device ID. Uses platform ID first, falls back to saved UUID.
  Future<String> _getStableDeviceId() async {
    final deviceInfoPlugin = DeviceInfoPlugin();

    try {
      if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        final idfv = iosInfo.identifierForVendor;
        if (idfv != null && idfv.isNotEmpty) {
          return 'ios-$idfv';
        }
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        final androidId = androidInfo.id;
        if (androidId.isNotEmpty) {
          return 'android-$androidId';
        }
      }
    } catch (_) {}

    // Fallback: generate UUID and save it
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('affiliateo_device_id');
    if (saved != null) return saved;

    // RFC 4122 v4 UUID via the same generator used for the IAP tokens
    // below. The old microsecondsSinceEpoch + Object().hashCode scheme
    // had a non-zero collision risk for two devices minting fallback IDs
    // in the same microsecond, and Object().hashCode is bucketed (16-bit
    // on the VM) so it added less entropy than it looked like.
    final newId = '${Platform.isIOS ? "ios" : "android"}-${_generateUuidV4()}';
    await prefs.setString('affiliateo_device_id', newId);
    return newId;
  }

  Future<DeviceInfo> _collectDeviceInfo() async {
    final deviceInfoPlugin = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();
    final window = PlatformDispatcher.instance.views.first;

    String model = 'Unknown';
    String os = Platform.operatingSystem;
    String osVersion = Platform.operatingSystemVersion;

    try {
      if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        model = iosInfo.model;
        os = 'iOS';
        osVersion = iosInfo.systemVersion;
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        model = '${androidInfo.manufacturer} ${androidInfo.model}';
        os = 'Android';
        osVersion = androidInfo.version.release;
      }
    } catch (_) {}

    return DeviceInfo(
      deviceModel: model,
      os: os,
      osVersion: osVersion,
      appVersion: packageInfo.version,
      screenWidth: window.physicalSize.width ~/ window.devicePixelRatio,
      screenHeight: window.physicalSize.height ~/ window.devicePixelRatio,
      timezone: DateTime.now().timeZoneName,
      language: PlatformDispatcher.instance.locale.languageCode,
    );
  }

  /// Android only: the Play Install Referrer — the link (and its utm /
  /// click-id tags) that installed the app. How a paid-ad install (Meta /
  /// TikTok / Google Ads) gets its source labelled server-side. Read once,
  /// then cached in SharedPreferences; transient failures retry next launch.
  Future<String?> _getInstallReferrer() async {
    if (!Platform.isAndroid) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('affiliateo_install_referrer_done') == true) {
        return prefs.getString('affiliateo_install_referrer');
      }
      final details = await AndroidPlayInstallReferrer.installReferrer;
      final raw = details.installReferrer?.trim();
      final value = (raw == null || raw.isEmpty)
          ? null
          : (raw.length > 2048 ? raw.substring(0, 2048) : raw);
      if (value != null) await prefs.setString('affiliateo_install_referrer', value);
      await prefs.setBool('affiliateo_install_referrer_done', true);
      return value;
    } catch (_) {
      // Play Store unavailable / non-Play install — retry next launch.
      return null;
    }
  }

  Future<void> _identify() async {
    final deviceId = _deviceId;
    final campaignId = _campaignId;
    if (deviceId == null || campaignId == null) return;

    try {
      final deviceInfo = await _collectDeviceInfo();
      final installReferrer = await _getInstallReferrer();

      final response = await http.post(
        Uri.parse('$_apiUrl/api/v1/mobile/identify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'campaign_id': campaignId,
          'device_id': deviceId,
          'device_model': deviceInfo.deviceModel,
          'os': deviceInfo.os,
          'os_version': deviceInfo.osVersion,
          'app_version': deviceInfo.appVersion,
          'screen_width': deviceInfo.screenWidth,
          'screen_height': deviceInfo.screenHeight,
          'timezone': deviceInfo.timezone,
          'language': deviceInfo.language,
          if (installReferrer != null) 'install_referrer': installReferrer,
        }),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final result = IdentifyResponse.fromJson(json);

        // Apple native IAP attribution. Mint a stable UUID per
        // (campaignId, refCode) so the customer's purchase chain (initial
        // buy + every renewal + refund) all carry the same token Apple
        // stamped at first purchase. Customer's purchase code reads it via
        // Affiliateo.state.appAccountToken and passes it to their IAP
        // plugin (in_app_purchase / flutter_inapp_purchase / etc.) as
        // StoreKit's appAccountToken.
        //
        // Best-effort: registration failure here means the next launch
        // retries (backend dedups via mobile_app_visitors unique constraint).
        String? appleToken;
        if (Platform.isIOS && result.refCode != null) {
          appleToken = await _getOrMintAppleAccountToken(campaignId, result.refCode!);
          // Fire-and-forget; don't block identify completion
          unawaited(_registerAppleToken(campaignId, result.visitorId, appleToken));
        }

        // Google Play native attribution. Same UUID shape as Apple, different
        // platform + endpoint. Customer reads it via
        // Affiliateo.state.obfuscatedAccountId and passes it to in_app_purchase
        // as PurchaseParam.applicationUserName (surfaces as obfuscatedAccountId
        // on Android).
        String? obfuscatedAccountId;
        if (Platform.isAndroid && result.refCode != null) {
          obfuscatedAccountId = await _getOrMintGoogleAccountId(campaignId, result.refCode!);
          unawaited(_registerGoogleAccountId(campaignId, result.visitorId, obfuscatedAccountId));
        }

        _state = AffiliateoState(
          refCode: result.refCode,
          isMatched: result.matched,
          isLoading: false,
          visitorId: result.visitorId,
          appAccountToken: appleToken,
          obfuscatedAccountId: obfuscatedAccountId,
        );
        _log('identify success', {
          'visitor': result.visitorId,
          'matched': result.matched,
          'ref': result.refCode,
        });

        // No RevenueCat auto-set here: Dart can't dynamically import
        // purchases_flutter, so the app developer sets the subscriber
        // attributes themselves (affiliateo_visitor_id for every user +
        // affiliateo_ref when matched) — see the note at the bottom of
        // this file and the README's RevenueCat Integration section.
      } else {
        _log('identify failed', 'http_status=${response.statusCode}');
        _state = _state.copyWith(isLoading: false);
      }
    } catch (_) {
      _log('identify failed (network error)');
      _state = _state.copyWith(isLoading: false);
    }
  }

  /// Get or mint a stable StoreKit 2 appAccountToken for this affiliate match.
  /// Persisted in SharedPreferences keyed by (campaignId, refCode) so the same
  /// UUID is reused across app launches for the same affiliate.
  Future<String> _getOrMintAppleAccountToken(String campaignId, String refCode) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'affiliateo_apple_token:$campaignId:$refCode';
    final existing = prefs.getString(key);
    if (existing != null && _isUuidV4(existing)) return existing;
    final fresh = _generateUuidV4();
    await prefs.setString(key, fresh);
    return fresh;
  }

  Future<void> _registerAppleToken(String campaignId, String visitorId, String token) async {
    try {
      await http.post(
        Uri.parse('$_apiUrl/api/v1/mobile/apple-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'campaign_id': campaignId,
          'visitor_id': visitorId,
          'token': token,
        }),
      );
    } catch (_) {
      // Best-effort: backend dedups so next launch retries safely.
    }
  }

  /// Get or mint a stable Play Billing obfuscatedAccountId for this affiliate.
  /// Persisted in SharedPreferences keyed by (campaignId, refCode) so the same
  /// UUID is reused across launches.
  Future<String> _getOrMintGoogleAccountId(String campaignId, String refCode) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'affiliateo_google_obfuscated_account_id:$campaignId:$refCode';
    final existing = prefs.getString(key);
    if (existing != null && _isUuidV4(existing)) return existing;
    final fresh = _generateUuidV4();
    await prefs.setString(key, fresh);
    return fresh;
  }

  Future<void> _registerGoogleAccountId(String campaignId, String visitorId, String obfuscatedAccountId) async {
    try {
      await http.post(
        Uri.parse('$_apiUrl/api/v1/mobile/google-account-id'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'campaign_id': campaignId,
          'visitor_id': visitorId,
          'obfuscated_account_id': obfuscatedAccountId,
        }),
      );
    } catch (_) {
      // Best-effort: backend dedups so next launch retries safely.
    }
  }

  // RFC 4122 v4 UUID. Dart doesn't ship a built-in UUID generator and we
  // don't want to add a transitive dep just for this, so we use the same
  // string-replace pattern as the React Native and Vanilla JS SDKs.
  String _generateUuidV4() {
    final r = Random.secure();
    String hex(int n) => n.toRadixString(16).padLeft(2, '0');
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  static final _uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);
  bool _isUuidV4(String s) => _uuidRe.hasMatch(s);

  Future<void> _sendSessionEvent(String type) async {
    if (_optedOut) return;
    // Route through the queue so foreground pings survive a flaky
    // network the way regular page/track events do. The server's
    // start_mobile_session RPC is idempotent so a duplicate from a
    // queue retry just no-ops.
    _enqueueEvent({
      'type': type,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Foreground keep-alive ping. The server's start_mobile_session RPC
      // handles rotation based on the 10-minute inactivity timeout. No
      // background screen_view. that was a ghost event polluting funnels.
      _sendSessionEvent('session_start');
    }
  }

  // _sendEvent used to live here: an unqueued http.post straight to
  // /api/v1/mobile/event. Nothing called it. Every real send path goes
  // through _enqueueEvent so it gets persistence, retry, and the dedup id,
  // which is why this one had quietly rotted — a direct post would have
  // dropped the event on any network blip with no second attempt.
  //
  // Deleted rather than wired up: it duplicated _enqueueEvent's job with
  // worse delivery guarantees, and `flutter analyze` fails on the
  // unused_element warning it produced.

  // Note: There is intentionally no setRevenueCatRef() method here. Dart
  // does not support dynamic imports the way JS/Swift/Kotlin do, so we
  // cannot auto-detect or call into the purchases_flutter SDK from this
  // package without making it a hard dependency (which would bloat every
  // install). The README documents the snippet the app developer writes
  // themselves after configure(). affiliateo_visitor_id goes on EVERY
  // user (matched or organic): the RevenueCat webhook stamps it onto the
  // conversion row, powering per-buyer spend, funnel journeys, and ad
  // ROAS joins. affiliateo_ref only exists for affiliate-referred installs:
  //
  //   final state = Affiliateo.state;
  //   final attributes = <String, String>{
  //     if (state.visitorId != null) "affiliateo_visitor_id": state.visitorId!,
  //     if (state.refCode != null) "affiliateo_ref": state.refCode!,
  //   };
  //   if (attributes.isNotEmpty) {
  //     await Purchases.setAttributes(attributes);
  //   }
  //
  // Exposing an empty stub method was misleading. it advertised an
  // integration the SDK doesn't actually provide.
}
