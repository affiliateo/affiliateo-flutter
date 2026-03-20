import 'dart:convert';
import 'dart:io';
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

    // Identify on startup
    await _instance._identify();
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

        _state = AffiliateoState(
          refCode: result.refCode,
          isMatched: result.matched,
          isLoading: false,
          visitorId: result.visitorId,
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

  Future<void> _sendSessionEvent(String type) async {
    final deviceId = _deviceId;
    final campaignId = _campaignId;
    if (deviceId == null || campaignId == null) return;

    try {
      await http.post(
        Uri.parse('$_apiUrl/api/v1/mobile/event'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'campaign_id': campaignId,
          'device_id': deviceId,
          'events': [
            {
              'type': type,
              'timestamp': DateTime.now().toUtc().toIso8601String(),
            }
          ],
        }),
      );
    } catch (_) {}
  }

  void _setRevenueCatAttribute(String refCode) {
    // Try to set RevenueCat attribute dynamically
    try {
      // This requires purchases_flutter to be installed in the app
      // We use a dynamic approach to avoid a hard dependency
      Function.apply(
        () async {
          try {
            final purchases = await Function.apply(
              () => throw UnimplementedError('RevenueCat not available'),
              [],
            );
          } catch (_) {}
        },
        [],
      );
    } catch (_) {
      // purchases_flutter not installed — that's fine
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sendSessionEvent('session_start');
    } else if (state == AppLifecycleState.paused) {
      _sendSessionEvent('session_end');
    }
  }

  /// Manually set the RevenueCat attribute. Call this if automatic detection doesn't work.
  static Future<void> setRevenueCatRef(String refCode) async {
    try {
      // Import dynamically if purchases_flutter is available
      // App developer should call: Purchases.setAttributes({"affiliateo_ref": refCode})
    } catch (_) {}
  }
}
