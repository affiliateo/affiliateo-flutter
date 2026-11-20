import 'package:affiliateo/affiliateo.dart';
import 'package:flutter_test/flutter_test.dart';

/// Affiliate codes typed inside the app (4.18.0): a coupon code without the
/// coupon. The rules are pure, so they are tested without a server; the
/// server's own half is the website's `affiliate-code/route.test.ts`.
void main() {
  const failed = AffiliateCode.refused(AffiliateCodeReason.failed);

  group('what the buyer typed', () {
    test('keeps a code as typed, minus the space around it and a leading @', () {
      expect(AffiliateCodeRules.normalize('elliotalton'), 'elliotalton');
      expect(AffiliateCodeRules.normalize('  ElliotAlton \n'), 'ElliotAlton');
      expect(AffiliateCodeRules.normalize('@elliotalton'), 'elliotalton');
      expect(AffiliateCodeRules.normalize('@@ elliot'), 'elliot');
    });

    test('refuses nothing, a sentence and anything too long', () {
      for (final raw in <String?>[null, '', '   ', '@', 'two words', 'tab\there', 'line\nbreak']) {
        expect(AffiliateCodeRules.normalize(raw), isNull, reason: '$raw');
      }
      final longest = 'a' * AffiliateCodeRules.maxLength;
      expect(AffiliateCodeRules.normalize(longest), longest);
      expect(AffiliateCodeRules.normalize('${longest}a'), isNull);
    });
  });

  group('what the server answered', () {
    test('a matched code carries the affiliate\'s code', () {
      expect(
        AffiliateCodeRules.parseReply(200, '{"ok":true,"matched":true,"ref_code":"elliotalton"}'),
        const AffiliateCode.applied('elliotalton'),
      );
    });

    test('a code nobody has is not found', () {
      expect(AffiliateCodeRules.parseReply(200, '{"ok":true,"matched":false}'), const AffiliateCode.refused(AffiliateCodeReason.notFound));
    });

    test('the owner\'s switch off, the device unknown and a bad code each say why', () {
      expect(AffiliateCodeRules.parseReply(403, '{"error":"Affiliate codes are off for this app.","code":"affiliate_codes_off"}'),
          const AffiliateCode.refused(AffiliateCodeReason.off));
      expect(AffiliateCodeRules.parseReply(404, '{"error":"Unknown device: call identify first.","code":"unknown_device"}'),
          const AffiliateCode.refused(AffiliateCodeReason.notReady));
      expect(AffiliateCodeRules.parseReply(400, '{"error":"code required","code":"invalid_code"}'),
          const AffiliateCode.refused(AffiliateCodeReason.invalid));
    });

    test('anything else is a failure worth a retry, never a match', () {
      expect(AffiliateCodeRules.parseReply(404, '{"error":"App not found"}'), failed);
      expect(AffiliateCodeRules.parseReply(429, '{"error":"Too many requests"}'), failed);
      expect(AffiliateCodeRules.parseReply(500, null), failed);
      expect(AffiliateCodeRules.parseReply(200, 'not json'), failed);
      expect(AffiliateCodeRules.parseReply(200, '{"ok":true,"matched":true}'), failed);
      expect(AffiliateCodeRules.parseReply(403, '{"error":"Forbidden"}'), failed);
    });
  });

  test('before configure, the answer is not ready', () async {
    expect(await Affiliateo.setAffiliateCode('elliotalton'), const AffiliateCode.refused(AffiliateCodeReason.notReady));
  });

  test('nothing typed is invalid, without a call', () async {
    expect(await Affiliateo.setAffiliateCode('   '), const AffiliateCode.refused(AffiliateCodeReason.invalid));
  });
}
