import 'package:affiliateo/affiliateo.dart';
import 'package:affiliateo/src/free_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('email hash', () {
    const known = '973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b';

    test('known address', () {
      expect(affiliateoEmailSha256('test@example.com'), known);
    });

    test('trims and lowercases first', () {
      expect(affiliateoEmailSha256('  Test@Example.COM \n'), known);
    });

    test('no address, no hash', () {
      expect(affiliateoEmailSha256(null), isNull);
      expect(affiliateoEmailSha256(''), isNull);
      expect(affiliateoEmailSha256('   '), isNull);
    });
  });

  group('saved answer', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000000, isUtc: true);
    const day = 24 * 60 * 60 * 1000;

    FreeAccessEntry saved({
      bool active = true,
      String? productId = 'pro_monthly',
      int? expiresAtMs,
      required int checkedAtMs,
    }) =>
        FreeAccessEntry(active: active, productId: productId, expiresAtMs: expiresAtMs, checkedAtMs: checkedAtMs);

    final nowMs = now.millisecondsSinceEpoch;

    test('nothing saved is no access', () {
      expect(FreeAccessCache.offlineAnswer(null, now), FreeAccess.inactive);
    });

    test('recent answer with no end is kept', () {
      expect(
        FreeAccessCache.offlineAnswer(saved(checkedAtMs: nowMs - day), now),
        const FreeAccess(active: true, productId: 'pro_monthly'),
      );
    });

    test('recent answer with a future end is kept', () {
      final end = nowMs + 3 * day;
      final answer = FreeAccessCache.offlineAnswer(saved(expiresAtMs: end, checkedAtMs: nowMs - day), now);
      expect(answer.active, isTrue);
      expect(answer.expiresAt, DateTime.fromMillisecondsSinceEpoch(end, isUtc: true));
    });

    test('a passed end is no access', () {
      final entry = saved(expiresAtMs: nowMs - 60000, checkedAtMs: nowMs - day);
      expect(FreeAccessCache.offlineAnswer(entry, now), FreeAccess.inactive);
    });

    test('7 days is still good, older is not', () {
      expect(FreeAccessCache.offlineAnswer(saved(checkedAtMs: nowMs - 7 * day), now).active, isTrue);
      expect(FreeAccessCache.offlineAnswer(saved(checkedAtMs: nowMs - 7 * day - 1), now).active, isFalse);
    });

    test('an answer from the future is not trusted', () {
      // A clock set back would otherwise stretch the 7 days.
      expect(FreeAccessCache.offlineAnswer(saved(checkedAtMs: nowMs + day), now).active, isFalse);
      expect(FreeAccessCache.offlineAnswer(saved(checkedAtMs: nowMs + 60000), now).active, isTrue);
    });

    test('a saved no is no', () {
      expect(FreeAccessCache.offlineAnswer(saved(active: false, checkedAtMs: nowMs), now), FreeAccess.inactive);
    });

    test('encode and decode round trip', () {
      final entry = saved(expiresAtMs: nowMs + day, checkedAtMs: nowMs);
      expect(FreeAccessCache.decode(FreeAccessCache.encode(entry)), entry);
      final fullAccess = saved(productId: null, checkedAtMs: nowMs);
      expect(FreeAccessCache.decode(FreeAccessCache.encode(fullAccess)), fullAccess);
      expect(FreeAccessCache.decode(null), isNull);
      expect(FreeAccessCache.decode('not json'), isNull);
    });
  });

  group('server reply', () {
    final end = DateTime.utc(2026, 11, 17, 12);

    test('active with a plan and an end', () {
      expect(
        FreeAccessCache.parseReply('{"active":true,"product_id":"pro_yearly","expires_at":"2026-11-17T12:00:00.000Z"}'),
        FreeAccess(active: true, productId: 'pro_yearly', expiresAt: end),
      );
    });

    test('full access with no end', () {
      expect(
        FreeAccessCache.parseReply('{"active":true,"product_id":null,"expires_at":null}'),
        const FreeAccess(active: true),
      );
    });

    test('inactive', () {
      expect(
        FreeAccessCache.parseReply('{"active":false,"product_id":null,"expires_at":null}'),
        FreeAccess.inactive,
      );
    });

    test('other date shapes', () {
      expect(FreeAccessCache.parseDate('2026-11-17T12:00:00Z'), end);
      expect(FreeAccessCache.parseDate('2026-11-17T13:00:00+01:00'), end);
      expect(FreeAccessCache.parseDate('2026-11-17T12:00:00'), end);
      expect(FreeAccessCache.parseDate('2026-11-17T12:00:00.123456+00:00'), end.add(const Duration(microseconds: 123456)));
      expect(FreeAccessCache.parseDate('next tuesday'), isNull);
    });

    test('not a reply', () {
      expect(FreeAccessCache.parseReply('not json'), isNull);
      expect(FreeAccessCache.parseReply('{"error":"rate limited"}'), isNull);
      // An end that cannot be read must not become "no end".
      expect(FreeAccessCache.parseReply('{"active":true,"expires_at":"next tuesday"}'), isNull);
    });
  });

  group('before configure()', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('freeAccess answers from the saved answer and never throws', () async {
      final checkedAt = DateTime.now().subtract(const Duration(days: 1));
      SharedPreferences.setMockInitialValues({
        FreeAccessCache.key: FreeAccessCache.encode(
          FreeAccessEntry.of(const FreeAccess(active: true, productId: 'pro_monthly'), checkedAt),
        ),
      });
      final answer = await Affiliateo.freeAccess();
      expect(answer, const FreeAccess(active: true, productId: 'pro_monthly'));
    });

    test('logout forgets the saved answer', () async {
      SharedPreferences.setMockInitialValues({
        FreeAccessCache.key: FreeAccessCache.encode(
          FreeAccessEntry.of(const FreeAccess(active: true), DateTime.now()),
        ),
        'affiliateo_user_id': 'user_1',
        'affiliateo_email_sha256': '973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b',
      });
      await Affiliateo.logout();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(FreeAccessCache.key), isNull);
      expect(prefs.getString('affiliateo_user_id'), isNull);
      expect(prefs.getString('affiliateo_email_sha256'), isNull);
      expect(await Affiliateo.freeAccess(), FreeAccess.inactive);
    });

    test('identify stores the email hash, never the address', () async {
      SharedPreferences.setMockInitialValues({});
      await Affiliateo.identify('user_2', email: ' Test@Example.com ');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('affiliateo_user_id'), 'user_2');
      expect(prefs.getString('affiliateo_email_sha256'),
          '973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b');
      expect(prefs.getKeys().any((k) => '${prefs.get(k)}'.contains('@')), isFalse);
    });
  });
}
