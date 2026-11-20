import 'dart:convert';

/// Why an affiliate code did not match.
enum AffiliateCodeReason {
  /// No affiliate of this app has that code. Nothing changed.
  notFound,

  /// Nothing was typed, or it is not one word of at most 64 characters.
  invalid,

  /// The app's owner has affiliate codes switched off in Affiliateo.
  off,

  /// The SDK has not reached Affiliateo for this device yet (or the person
  /// opted out), so there is nothing to put the code on. Try again in a
  /// moment.
  notReady,

  /// Offline, too many tries, or the server did not answer. Try again.
  failed,
}

/// What `Affiliateo.setAffiliateCode()` answered (4.18.0).
///
/// An affiliate code is a coupon code without the coupon. The buyer types an
/// affiliate's code in a box YOUR app shows, you hand it to the SDK, and that
/// affiliate gets the sale. No discount, the store is not involved, and
/// nothing is matched by IP address for that buyer. The code is the one each
/// affiliate already has: the end of their link.
///
/// ```dart
/// final result = await Affiliateo.setAffiliateCode(codeController.text);
/// if (result.matched) {
///   // Say "Code applied".
/// } else {
///   // Say "Code not found". result.reason says why.
/// }
/// ```
class AffiliateCode {
  /// The code is an affiliate's, and it is on this device now.
  final bool matched;

  /// The affiliate's code as Affiliateo keeps it. Null unless [matched].
  final String? refCode;

  /// Why it did not match. Null when it did.
  final AffiliateCodeReason? reason;

  const AffiliateCode({required this.matched, this.refCode, this.reason});

  const AffiliateCode.applied(String this.refCode)
      : matched = true,
        reason = null;

  const AffiliateCode.refused(AffiliateCodeReason this.reason)
      : matched = false,
        refCode = null;

  @override
  bool operator ==(Object other) =>
      other is AffiliateCode && other.matched == matched && other.refCode == refCode && other.reason == reason;

  @override
  int get hashCode => Object.hash(matched, refCode, reason);

  @override
  String toString() => 'AffiliateCode(matched: $matched, refCode: $refCode, reason: $reason)';
}

/// The rules of a typed code, kept pure so they are tested without a server.
class AffiliateCodeRules {
  /// The longest code the server reads.
  static const int maxLength = 64;

  /// What the buyer typed, ready to send: the space around it and a leading
  /// "@" dropped, or null when there is nothing usable (empty, more than one
  /// word, too long). The server applies the same rule.
  static String? normalize(String? raw) {
    if (raw == null) return null;
    final code = raw.trim().replaceFirst(RegExp(r'^@+'), '').trim();
    if (code.isEmpty || code.length > maxLength) return null;
    if (RegExp(r'[\s\u0000-\u001f]').hasMatch(code)) return null;
    return code;
  }

  /// The server's answer as the app reads it. POST
  /// /api/v1/mobile/affiliate-code answers 200 with `matched` (and the
  /// `ref_code` when true), 403 `affiliate_codes_off` while the owner's switch
  /// is off, 404 `unknown_device` before identify has run, 400
  /// `invalid_code`, and anything else is a failure worth a retry.
  static AffiliateCode parseReply(int status, String? body) {
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(body ?? '');
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}
    final code = json['code'];
    if (status >= 200 && status <= 299) {
      final matched = json['matched'];
      if (matched is! bool) return const AffiliateCode.refused(AffiliateCodeReason.failed);
      if (!matched) return const AffiliateCode.refused(AffiliateCodeReason.notFound);
      final refCode = json['ref_code'];
      return refCode is String && refCode.isNotEmpty
          ? AffiliateCode.applied(refCode)
          : const AffiliateCode.refused(AffiliateCodeReason.failed);
    }
    if (status == 403 && code == 'affiliate_codes_off') return const AffiliateCode.refused(AffiliateCodeReason.off);
    if (status == 404 && code == 'unknown_device') return const AffiliateCode.refused(AffiliateCodeReason.notReady);
    if (status == 400 && code == 'invalid_code') return const AffiliateCode.refused(AffiliateCodeReason.invalid);
    return const AffiliateCode.refused(AffiliateCodeReason.failed);
  }
}
