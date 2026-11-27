import 'package:affiliateo/src/chat_rules.dart';
import 'package:flutter_test/flutter_test.dart';

// Hold to hide's rules (4.19.0), the same numbers and words as the Swift,
// Kotlin, React Native and web SDKs: a bubble must hide the same way
// everywhere. What the bubble does on screen is in chat_hide_widget_test.dart.

void main() {
  group('the numbers', () {
    test('a one second hold, five seconds of hide mode', () {
      expect(holdToHideDuration, const Duration(milliseconds: 1000));
      expect(hideModeDuration, const Duration(milliseconds: 5000));
    });

    test('the rock: 2.5 degrees each way, 130 ms a swing', () {
      expect(jiggleDegrees, 2.5);
      expect(jiggleSwingDuration, const Duration(milliseconds: 130));
    });

    test('the X: an 18 point square, corners of 6, at (-3, -3), a 36 point target, the unread red', () {
      expect(hideXSize, 18);
      expect(hideXRadius, 6);
      expect(hideXOffset, -3);
      expect(hideXTarget, 36);
      // At least 9 points past the square on each side.
      expect((hideXTarget - hideXSize) / 2, 9);
      expect(hideXColor, 0xFFEF4444);
      expect(hideXCrossLength, 8);
      expect(hideXCrossWidth, 2);
    });
  });

  group('the rock', () {
    test('runs from -2.5 through level to +2.5 over one swing', () {
      expect(jiggleAngle(0), -2.5);
      expect(jiggleAngle(0.5), 0);
      expect(jiggleAngle(1), 2.5);
      expect(jiggleAngle(0.25), -1.25);
      expect(jiggleAngle(0.75), 1.25);
    });

    test('never past 2.5 either way, and level for anything that is not a number', () {
      expect(jiggleAngle(-1), -2.5);
      expect(jiggleAngle(3), 2.5);
      expect(jiggleAngle(double.infinity), 2.5);
      expect(jiggleAngle(double.negativeInfinity), -2.5);
      expect(jiggleAngle(double.nan), 0);
    });

    test('the attention wiggle never plays in hide mode', () {
      bool may({bool hideMode = false}) => mayWiggle(
            seconds: 10,
            visible: true,
            chatOpen: false,
            appActive: true,
            dragging: false,
            reduceMotion: false,
            hideMode: hideMode,
          );
      expect(may(), isTrue);
      expect(may(hideMode: true), isFalse);
    });
  });

  group('remembered on the phone', () {
    test('under affiliateo_chat_hidden_<appId>', () {
      expect(chatHiddenKey('app_123'), 'affiliateo_chat_hidden_app_123');
      expect(chatHiddenKey('a'), isNot(chatHiddenKey('b')));
    });

    test('the bubble stays away while it is remembered, and until the note is read', () {
      bool hidden({bool remembered = false, bool read = true, bool configured = true}) =>
          bubbleHiddenByUser(remembered: remembered, read: read, configured: configured);
      expect(hidden(), isFalse);
      expect(hidden(remembered: true), isTrue);
      // Configured, but the phone's note not read yet: no bubble for a moment.
      expect(hidden(read: false), isTrue);
      // Before configure() there is no note to read.
      expect(hidden(read: false, configured: false), isFalse);
      expect(hidden(remembered: true, configured: false), isTrue);
    });
  });

  group('the words', () {
    const words = <String, String>{
      'en': 'Hide chat bubble',
      'ar': 'إخفاء فقاعة الدردشة',
      'de': 'Chat-Blase ausblenden',
      'es': 'Ocultar burbuja de chat',
      'fr': 'Masquer la bulle de chat',
      'hi': 'चैट बबल छिपाएँ',
      'it': 'Nascondi la bolla della chat',
      'ja': 'チャットバブルを非表示',
      'ko': '채팅 버블 숨기기',
      'nl': 'Chatbubbel verbergen',
      'pl': 'Ukryj dymek czatu',
      'pt': 'Ocultar balão do chat',
      'ru': 'Скрыть значок чата',
      'tr': 'Sohbet balonunu gizle',
      'vi': 'Ẩn bong bóng trò chuyện',
      'zh': '隐藏聊天气泡',
    };

    test('all 16 languages Affiliateo speaks', () {
      expect(words.length, 16);
      for (final MapEntry(key: language, value: hide) in words.entries) {
        expect(hideBubbleWords(language), hide, reason: language);
        // Next to the bubble's other words, the same lookup.
        expect(chatWords(language)[3], hide, reason: language);
        expect(chatWords(language).length, 4, reason: language);
      }
    });

    test('by the first two letters of the tag', () {
      expect(hideBubbleWords('pt-BR'), 'Ocultar balão do chat');
      expect(hideBubbleWords('zh_Hans'), '隐藏聊天气泡');
      expect(hideBubbleWords('DE-at'), 'Chat-Blase ausblenden');
    });

    test('English for any other language, or none', () {
      expect(hideBubbleWords('xx'), 'Hide chat bubble');
      expect(hideBubbleWords('sv-SE'), 'Hide chat bubble');
      expect(hideBubbleWords('e'), 'Hide chat bubble');
      expect(hideBubbleWords(''), 'Hide chat bubble');
    });

    test('the bubble\'s older words did not move', () {
      expect(chatWords('en').sublist(0, 3), ['Chat', 'Close chat', 'Chat, {n} unread']);
      expect(chatWords('de')[1], 'Chat schließen');
    });
  });
}
