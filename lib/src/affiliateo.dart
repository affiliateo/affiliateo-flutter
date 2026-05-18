import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Main entry point for the Affiliateo SDK.
///
/// Initialize in your `main()` or `initState()`:
///
/// ```dart
/// await Affiliateo.configure(campaignId: 'YOUR_CAMPAIGN_ID');
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

  static AffiliateoState _state = const AffiliateoState();

  /// Current attribution state.
  static AffiliateoState get state => _state;

  /// Configure and start the Affiliateo SDK.
  /// Call this once at app startup.
  static Future<void> configure({
    required String campaignId,
    String apiUrl = 'https://affiliateo.com',
  }) async {
    if (_instance._configured) return;
    _instance._configured = true;
    _instance._campaignId = campaignId;
    _instance._apiUrl = apiUrl.endsWith('/') ? apiUrl.substring(0, apiUrl.length - 1) : apiUrl;

    // Get stable device ID
    _instance._deviceId = await _instance._getStableDeviceId();

    // Listen for app lifecycle
    WidgetsBinding.instance.addObserver(_instance);

    // Identify on startup + auto-fire one screen_view so session_time has
    // >= 2 timestamps (otherwise max - min = 0).
    await _instance._identify();
    await _instance._sendEvent(
      'screen_view',
      screen: '[Entry]',
      metadata: {'auto': true},
    );
  }

  /// Fire a screen_view event for a specific screen.
  /// Call from `initState()` of each screen or from a route observer.
  static Future<void> page(String screenName, [Map<String, dynamic>? metadata]) async {
    await _instance._sendEvent('screen_view', screen: screenName, metadata: metadata);
  }

  /// Fire a custom event with arbitrary name + metadata.
  static Future<void> track(String eventName, [Map<String, dynamic>? metadata]) async {
    final merged = <String, dynamic>{'event': eventName};
    if (metadata != null) merged.addAll(metadata);
    await _instance._sendEvent('custom', metadata: merged);
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

    final newId = '${Platform.isIOS ? "ios" : "android"}-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Object().hashCode.toRadixString(36)}';
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

  Future<void> _identify() async {
    final deviceId = _deviceId;
    final campaignId = _campaignId;
    if (deviceId == null || campaignId == null) return;

    try {
      final deviceInfo = await _collectDeviceInfo();

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

        // Auto-set RevenueCat attribute if matched
        if (result.refCode != null) {
          _setRevenueCatAttribute(result.refCode!);
        }
      } else {
        _state = _state.copyWith(isLoading: false);
      }
    } catch (_) {
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
    await _sendEvent(type);
  }

  void _setRevenueCatAttribute(String refCode) {
    // RevenueCat must be set by the app developer since Dart doesn't support dynamic imports.
    // Store the ref code so the app can read it via Affiliateo.instance.state.refCode
    // and call: Purchases.setAttributes({"affiliateo_ref": refCode})
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sendSessionEvent('session_start');
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Fire one final screen_view on background. Overrides the older
      // "server uses 10-min timeout" design so session_time has a real
      // "last activity" stamp close to when the user actually left.
      _sendEvent(
        'screen_view',
        screen: '[Background]',
        metadata: {'reason': 'background'},
      );
    }
  }

  Future<void> _sendEvent(
    String type, {
    String? screen,
    Map<String, dynamic>? metadata,
  }) async {
    final deviceId = _deviceId;
    final campaignId = _campaignId;
    if (deviceId == null || campaignId == null) return;

    final event = <String, dynamic>{
      'type': type,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };
    if (screen != null) event['screen'] = screen;
    if (metadata != null) event['metadata'] = metadata;

    try {
      await http.post(
        Uri.parse('$_apiUrl/api/v1/mobile/event'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'campaign_id': campaignId,
          'device_id': deviceId,
          'events': [event],
        }),
      );
    } catch (_) {}
  }

  /// Manually set the RevenueCat attribute. Call this after initialization:
  /// ```dart
  /// final ref = Affiliateo.instance.state.refCode;
  /// if (ref != null) {
  ///   Purchases.setAttributes({"affiliateo_ref": ref});
  /// }
  /// ```
  static Future<void> setRevenueCatRef(String refCode) async {
    // App developer should call Purchases.setAttributes directly
    // since Dart doesn't support dynamic imports like JS/Swift/Kotlin
  }
}
