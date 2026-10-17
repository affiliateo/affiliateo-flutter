import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// The signed-in person's email as Affiliateo receives it (4.12.0): the
/// SHA-256 of the trimmed, lowercased address, in lowercase hex, or null when
/// there is no address (null, empty or only spaces). The address itself never
/// leaves the phone. Affiliateo hashes the address an app owner types for free
/// access the same way and compares the two.
///
/// KEEP IN SYNC with the server and with the copies in the other SDKs.
String? affiliateoEmailSha256(String? email) {
  if (email == null) return null;
  final normalized = email.trim().toLowerCase();
  if (normalized.isEmpty) return null;
  return sha256.convert(utf8.encode(normalized)).toString();
}

/// One saved answer of the free access check.
class FreeAccessEntry {
  final bool active;
  final String? productId;

  /// Milliseconds since 1970, null for no end.
  final int? expiresAtMs;

  /// When the server gave this answer, milliseconds since 1970.
  final int checkedAtMs;

  const FreeAccessEntry({
    required this.active,
    this.productId,
    this.expiresAtMs,
    required this.checkedAtMs,
  });

  FreeAccessEntry.of(FreeAccess answer, DateTime checkedAt)
      : active = answer.active,
        productId = answer.productId,
        expiresAtMs = answer.expiresAt?.millisecondsSinceEpoch,
        checkedAtMs = checkedAt.millisecondsSinceEpoch;

  @override
  bool operator ==(Object other) =>
      other is FreeAccessEntry &&
      other.active == active &&
      other.productId == productId &&
      other.expiresAtMs == expiresAtMs &&
      other.checkedAtMs == checkedAtMs;

  @override
  int get hashCode => Object.hash(active, productId, expiresAtMs, checkedAtMs);
}

/// The last answer the server gave, kept on the phone so an app opened
/// offline still unlocks for a while (4.12.0). Cleared on sign-out and when a
/// different user signs in, since it belongs to the person who was asked
/// about.
class FreeAccessCache {
  FreeAccessCache._();

  static const key = 'affiliateo_free_access';

  /// How long a saved answer counts without a new one from the server.
  static const maxAge = Duration(days: 7);

  /// A saved answer dated further ahead than this is not trusted, so a clock
  /// set back cannot stretch the 7 days.
  static const clockSkew = Duration(minutes: 5);

  /// The answer when the server could not be asked: the saved one while it is
  /// still good (its end, if any, is in the future and the server gave it at
  /// most 7 days ago), otherwise no free access.
  static FreeAccess offlineAnswer(FreeAccessEntry? entry, DateTime now) {
    if (entry == null || !entry.active) return FreeAccess.inactive;
    final nowMs = now.millisecondsSinceEpoch;
    final age = nowMs - entry.checkedAtMs;
    if (age > maxAge.inMilliseconds || age < -clockSkew.inMilliseconds) {
      return FreeAccess.inactive;
    }
    final end = entry.expiresAtMs;
    if (end != null && end <= nowMs) return FreeAccess.inactive;
    return FreeAccess(
      active: true,
      productId: entry.productId,
      expiresAt: end == null ? null : DateTime.fromMillisecondsSinceEpoch(end, isUtc: true),
    );
  }

  static String encode(FreeAccessEntry entry) => jsonEncode({
        'active': entry.active,
        'product_id': entry.productId,
        'expires_at': entry.expiresAtMs,
        'checked_at': entry.checkedAtMs,
      });

  static FreeAccessEntry? decode(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      final active = json['active'];
      final productId = json['product_id'];
      final expiresAt = json['expires_at'];
      final checkedAt = json['checked_at'];
      if (active is! bool || checkedAt is! int) return null;
      return FreeAccessEntry(
        active: active,
        productId: productId is String ? productId : null,
        expiresAtMs: expiresAt is int ? expiresAt : null,
        checkedAtMs: checkedAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// The server's reply `{ active, product_id, expires_at }`, or null when it
  /// is not one (the check then counts as failed).
  static FreeAccess? parseReply(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    final active = json['active'];
    if (active is! bool) return null;
    if (!active) return FreeAccess.inactive;
    final rawProduct = json['product_id'];
    final product = rawProduct is String ? rawProduct.trim() : null;
    DateTime? expiresAt;
    final rawEnd = json['expires_at'];
    if (rawEnd != null) {
      // An end the SDK cannot read must not turn into "no end".
      if (rawEnd is! String) return null;
      expiresAt = parseDate(rawEnd);
      if (expiresAt == null) return null;
    }
    return FreeAccess(
      active: true,
      productId: product == null || product.isEmpty ? null : product,
      expiresAt: expiresAt,
    );
  }

  static final _zone = RegExp(r'(Z|[+-]\d{2}(:?\d{2})?)$', caseSensitive: false);

  /// ISO 8601 ("2026-11-17T12:00:00.000Z", "2026-11-17T12:00:00+00:00") in
  /// UTC, or null. No zone counts as UTC, not the phone's time zone.
  static DateTime? parseDate(String text) {
    final trimmed = text.trim();
    final hasZone = _zone.hasMatch(trimmed);
    final parsed = DateTime.tryParse(hasZone ? trimmed : '${trimmed}Z');
    return parsed?.toUtc();
  }
}
