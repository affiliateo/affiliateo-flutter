class DeviceInfo {
  final String deviceModel;
  final String os;
  final String osVersion;
  final String appVersion;
  final int screenWidth;
  final int screenHeight;
  final String timezone;
  final String language;

  DeviceInfo({
    required this.deviceModel,
    required this.os,
    required this.osVersion,
    required this.appVersion,
    required this.screenWidth,
    required this.screenHeight,
    required this.timezone,
    required this.language,
  });
}

class IdentifyResponse {
  final String visitorId;
  final String? refCode;
  final bool matched;

  IdentifyResponse({
    required this.visitorId,
    this.refCode,
    required this.matched,
  });

  factory IdentifyResponse.fromJson(Map<String, dynamic> json) {
    return IdentifyResponse(
      visitorId: json['visitor_id'] as String,
      refCode: json['ref_code'] as String?,
      matched: json['matched'] as bool,
    );
  }
}

/// What `Affiliateo.freeAccess()` answered (4.12.0): whether the app owner
/// gave the signed-in person free access from their Affiliateo dashboard.
///
/// ```dart
/// final access = await Affiliateo.freeAccess();
/// if (access.active) unlock(access.productId);
/// ```
class FreeAccess {
  /// Unlock the app when true.
  final bool active;

  /// The store product id of the plan the owner chose. Null means full access
  /// (every paid feature).
  final String? productId;

  /// When the free access ends (UTC). Null means it has no end date.
  final DateTime? expiresAt;

  const FreeAccess({
    required this.active,
    this.productId,
    this.expiresAt,
  });

  /// No free access.
  static const inactive = FreeAccess(active: false);

  @override
  bool operator ==(Object other) =>
      other is FreeAccess &&
      other.active == active &&
      other.productId == productId &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(active, productId, expiresAt);

  @override
  String toString() =>
      'FreeAccess(active: $active, productId: $productId, expiresAt: $expiresAt)';
}

/// What a purchase reported with `Affiliateo.purchase` bought.
enum PurchaseKind {
  /// The first payment of a subscription.
  subscription('subscription'),

  /// A one-time purchase (lifetime access, a pack of credits).
  oneTime('one_time');

  const PurchaseKind(this.wireName);

  /// The name the server reads.
  final String wireName;
}

class AffiliateoState {
  final String? refCode;
  final bool isMatched;
  final bool isLoading;
  final String? visitorId;

  /// StoreKit appAccountToken UUID (iOS only): the Affiliateo visitor id of
  /// this device. Every user gets one, whether or not they came through an
  /// affiliate. Always pass it to your IAP plugin's purchase call
  /// (in_app_purchase's PurchaseParam.applicationUserName), so Apple stamps it
  /// onto the transaction and Affiliateo ties the sale (and every renewal and
  /// refund after it) to this phone, and to the affiliate when there is one.
  ///
  /// Null before identify succeeds (so also when the SDK starts opted out)
  /// and on Android. Since 4.11.0 logout() and reset() keep it.
  final String? appAccountToken;

  /// Play Billing obfuscatedAccountId (Android only): the Affiliateo visitor
  /// id of this device. Every user gets one, whether or not they came through
  /// an affiliate. Always pass it to your IAP plugin's purchase call
  /// (in_app_purchase's PurchaseParam.applicationUserName), so Google stamps
  /// it onto the purchase and Affiliateo ties the sale (and every renewal and
  /// refund after it) to this phone, and to the affiliate when there is one.
  ///
  /// Null before identify succeeds (so also when the SDK starts opted out)
  /// and on iOS. Since 4.11.0 logout() and reset() keep it.
  final String? obfuscatedAccountId;

  const AffiliateoState({
    this.refCode,
    this.isMatched = false,
    this.isLoading = true,
    this.visitorId,
    this.appAccountToken,
    this.obfuscatedAccountId,
  });

  AffiliateoState copyWith({
    String? refCode,
    bool? isMatched,
    bool? isLoading,
    String? visitorId,
    String? appAccountToken,
    String? obfuscatedAccountId,
  }) {
    return AffiliateoState(
      refCode: refCode ?? this.refCode,
      isMatched: isMatched ?? this.isMatched,
      isLoading: isLoading ?? this.isLoading,
      visitorId: visitorId ?? this.visitorId,
      appAccountToken: appAccountToken ?? this.appAccountToken,
      obfuscatedAccountId: obfuscatedAccountId ?? this.obfuscatedAccountId,
    );
  }
}
