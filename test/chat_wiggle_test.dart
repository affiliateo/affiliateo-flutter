import 'dart:math';

import 'package:affiliateo/src/chat_rules.dart';
import 'package:flutter_test/flutter_test.dart';

// The wiggle's rules (4.17.0), the same cases as the website's
// bubble-options.test.ts ("the wiggle") and the Swift, Kotlin and React
// Native SDK tests: a bubble must wiggle the same way everywhere.

void main() {
  group('how often', () {
    // What the SDK makes of bubble.wiggle_seconds: the config's value, the seconds.
    final configCases = <(Object?, int)>[
      (30, 30),
      (10, 10),
      (0, 0),
      (null, 0),
      ('30', 0),
      (true, 0),
      (-5, 0),
      (double.nan, 0),
      (double.infinity, 0),
      (1, 3),
      (2.9, 3),
      (3, 3),
      (7.8, 7),
      (100000, 86400),
    ];
    for (final (value, seconds) in configCases) {
      test('a config that says $value wiggles every $seconds seconds', () {
        expect(readWiggleSeconds(value), seconds);
        expect(readBubbleConfig({'wiggle_seconds': value}).wiggleSeconds, seconds);
      });
    }

    test('a config from before the wiggle does not wiggle', () {
      expect(readBubbleConfig({'size': 'auto', 'size_points': 56}).wiggleSeconds, 0);
      expect(readBubbleConfig({'wiggle_seconds': 20}).wiggleSeconds, 20);
      expect(const ChatBubbleConfig().wiggleSeconds, 0);
      expect(readChatConfig({'enabled': true}).bubble.wiggleSeconds, 0);
    });

    // What the app's own code asks for: what it wrote, the seconds (null for "not set").
    final codeCases = <(int?, int?)>[
      (null, null),
      (0, 0),
      (20, 20),
      (1, 3),
      (2, 3),
      (7, 7),
      (90, 90),
      (-4, 0),
      (100000, 86400),
    ];
    for (final (value, seconds) in codeCases) {
      test('code that says $value means $seconds', () {
        expect(wiggleOverride(value), seconds);
      });
    }

    test('the code wins over the dashboard when it says something, off included', () {
      final dashboard = readBubbleConfig({'wiggle_seconds': 30});
      expect(applyChatLook(dashboard, const ChatLook()).wiggleSeconds, 30);
      expect(applyChatLook(dashboard, const ChatLook(wiggleSeconds: 12)).wiggleSeconds, 12);
      expect(applyChatLook(dashboard, const ChatLook(wiggleSeconds: 0)).wiggleSeconds, 0);
      expect(applyChatLook(dashboard, const ChatLook(wiggleSeconds: 1)).wiggleSeconds, 3);
      expect(applyChatLook(const ChatBubbleConfig(), const ChatLook(wiggleSeconds: 5)).wiggleSeconds, 5);
      // The rest of the look is untouched by it.
      expect(applyChatLook(dashboard, const ChatLook(wiggleSeconds: 12)).color, ChatBubbleConfig.defaultColor);
      expect(const ChatLook(wiggleSeconds: 12) == const ChatLook(wiggleSeconds: 12), isTrue);
      expect(const ChatLook(wiggleSeconds: 12) == const ChatLook(), isFalse);
    });

    test('only while the bubble shows, the chat is closed, the app is in front and nobody drags it', () {
      bool may({
        int seconds = 30,
        bool visible = true,
        bool chatOpen = false,
        bool appActive = true,
        bool dragging = false,
        bool reduceMotion = false,
      }) =>
          mayWiggle(
            seconds: seconds,
            visible: visible,
            chatOpen: chatOpen,
            appActive: appActive,
            dragging: dragging,
            reduceMotion: reduceMotion,
          );
      expect(may(), isTrue);
      expect(may(seconds: 0), isFalse);
      expect(may(visible: false), isFalse);
      expect(may(chatOpen: true), isFalse);
      expect(may(appActive: false), isFalse);
      expect(may(dragging: true), isFalse);
      // Never with Reduce Motion.
      expect(may(reduceMotion: true), isFalse);
    });
  });

  // Version 2 of the motion (Nico, 2026-11-11: "a little bit more", and smooth):
  // 900 ms, angle(p) = 16 * sin(6 * PI * p) * (1 - p)^1.2, scale(p) = 1 + 0.06 * sin(PI * p).
  group('the motion', () {
    test('is one smooth wiggle of 900 ms that starts and ends exactly at rest', () {
      expect(wiggleDuration, const Duration(milliseconds: 900));
      expect(wiggleAngle(0), 0);
      expect(wiggleAngle(1), 0);
      expect(wiggleScale(0), 1);
      expect(wiggleScale(1), 1);
      // Outside a wiggle the bubble is at rest too.
      expect([wiggleAngle(-0.2), wiggleAngle(1.5), wiggleAngle(double.nan)], [0, 0, 0]);
      expect([wiggleScale(-0.2), wiggleScale(1.5), wiggleScale(double.nan)], [1, 1, 1]);
    });

    test('follows the shared formula', () {
      for (var i = 1; i < 200; i++) {
        final p = i / 200;
        expect(wiggleAngle(p), closeTo(16 * sin(6 * pi * p) * pow(1 - p, 1.2), 1e-12));
        expect(wiggleScale(p), closeTo(1 + 0.06 * sin(pi * p), 1e-12));
      }
    });

    test('swings three times, the first about 14 degrees, each one smaller, never past 16', () {
      final samples = [for (var i = 0; i <= 9000; i++) i / 9000];
      final angles = samples.map(wiggleAngle).toList();
      expect(angles.map((a) => a.abs()).reduce(max), lessThanOrEqualTo(wiggleMaxDegrees));
      expect(wiggleMaxDegrees, 16);
      // The first peak: to the right, between 13 and 15 degrees, early in the wiggle.
      final firstPeak = angles.reduce(max);
      expect(firstPeak, greaterThan(13));
      expect(firstPeak, lessThan(15));
      expect(samples[angles.indexOf(firstPeak)], lessThan(1 / 6));
      expect(wiggleAngle(1 / 12), closeTo(14.41, 0.05));
      // Three full left-right swings: it passes through rest five times on the way.
      var crossings = 0;
      for (var i = 2; i < angles.length - 1; i++) {
        if (angles[i - 1] != 0 && angles[i] != 0 && angles[i].sign != angles[i - 1].sign) crossings++;
      }
      expect(crossings, 5);
      // Each swing is smaller than the one before, and the last is about a degree.
      final peaks = [for (final n in [1, 3, 5, 7, 9, 11]) wiggleAngle(n / 12).abs()];
      for (var i = 1; i < peaks.length; i++) {
        expect(peaks[i], lessThan(peaks[i - 1]));
      }
      expect(peaks[5], greaterThan(0.5));
      expect(peaks[5], lessThan(1.5));
    });

    test('grows a touch and settles back: 6% at the middle', () {
      expect(wiggleScale(0.5), closeTo(1.06, 1e-10));
      final scales = [for (var i = 0; i <= 1000; i++) wiggleScale(i / 1000)];
      expect(scales.reduce(max), closeTo(1.06, 1e-10));
      expect(scales.reduce(min), 1);
      expect(wiggleScale(0.25), closeTo(wiggleScale(0.75), 1e-10));
    });

    test('is smooth: drawn on every frame, no frame of a 60 Hz screen is a jump', () {
      // 900 ms at 60 frames a second is 54 frames.
      const frames = 54;
      for (var i = 1; i <= frames; i++) {
        expect((wiggleAngle(i / frames) - wiggleAngle((i - 1) / frames)).abs(), lessThan(6));
        expect((wiggleScale(i / frames) - wiggleScale((i - 1) / frames)).abs(), lessThan(0.01));
      }
    });
  });
}
