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

class AffiliateoState {
  final String? refCode;
  final bool isMatched;
  final bool isLoading;
  final String? visitorId;

  const AffiliateoState({
    this.refCode,
    this.isMatched = false,
    this.isLoading = true,
    this.visitorId,
  });

  AffiliateoState copyWith({
    String? refCode,
    bool? isMatched,
    bool? isLoading,
    String? visitorId,
  }) {
    return AffiliateoState(
      refCode: refCode ?? this.refCode,
      isMatched: isMatched ?? this.isMatched,
      isLoading: isLoading ?? this.isLoading,
      visitorId: visitorId ?? this.visitorId,
    );
  }
}
