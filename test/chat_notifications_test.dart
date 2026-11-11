import 'dart:convert';

import 'package:affiliateo/src/chat_rules.dart';
import 'package:flutter_test/flutter_test.dart';

// The Flutter SDK's side of Live Chat notifications (4.17.0): the same cases
// as the React Native SDK's (the website's react-native-chat-push.test.ts).
// The body it registers a phone with must be one the website's route keeps
// (lib/live-chat/visitor-push.ts), it must know a chat notification in both
// shapes the website sends, and its banner must say what the push says.

const app = '0b9c2f1e-6a7d-4c3b-9e8f-1a2b3c4d5e6f';
final apns = 'ab' * 32;
final fcm = 'dQw4w9WgXcQ:APA91bHuN7xK${'Zq-9_Lm' * 20}';

/// The iPhone's payload as the website builds it (visitorPushApnsMessage).
Map<String, Object?> apnsPayload() => {
      'aps': {
        'alert': {'title': 'Copydraw', 'body': 'We fixed it'},
        'sound': 'default',
        'thread-id': 'affiliateo-chat',
      },
      'affiliateo_chat': {'app': app, 'conversation_id': 'c-1', 'message_id': 'm-1'},
    };

/// Android's data as the website builds it (visitorPushFcmData): every value a string.
Map<String, String> fcmData() => {
      'affiliateo_chat': '1',
      'app': app,
      'conversation_id': 'c-1',
      'message_id': 'm-1',
      'title': 'Copydraw',
      'body': 'We fixed it',
    };

/// The 16 languages Affiliateo speaks, with the website's words for a
/// message with no text (SENT_YOU_A_MESSAGE, the list in IOS-NOTES.md).
const sentYouAMessage = {
  'en': 'Sent you a message',
  'es': 'Te envió un mensaje',
  'fr': 'Vous a envoyé un message',
  'pt': 'Enviou uma mensagem para você',
  'de': 'Hat dir eine Nachricht gesendet',
  'ja': 'メッセージが届きました',
  'it': 'Ti ha inviato un messaggio',
  'nl': 'Heeft je een bericht gestuurd',
  'ko': '메시지를 보냈습니다',
  'zh': '给你发了一条消息',
  'ru': 'Вам пришло сообщение',
  'ar': 'أرسل لك رسالة',
  'hi': 'आपको एक संदेश भेजा',
  'pl': 'Masz nową wiadomość',
  'tr': 'Size bir mesaj gönderdi',
  'vi': 'Đã gửi cho bạn một tin nhắn',
};

void main() {
  group('the push token', () {
    test('is Apple\'s device token in hex on an iPhone, however it was written out', () {
      expect(chatPushToken(apns.toUpperCase(), 'ios'), apns);
      expect(chatPushToken('<${apns.substring(0, 8)} ${apns.substring(8)}>', 'ios'), apns);
      // Not a Firebase token: Affiliateo sends an iPhone's through Apple.
      expect(chatPushToken(fcm, 'ios'), isNull);
      expect(chatPushToken('ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]', 'ios'), isNull);
    });

    test('is Firebase\'s token exactly as given on Android', () {
      expect(chatPushToken(' $fcm ', 'android'), fcm);
      expect(chatPushToken('short', 'android'), isNull);
      expect(chatPushToken(null, 'android'), isNull);
      expect(chatPushToken(42, 'android'), isNull);
    });
  });

  group('the body that registers a phone', () {
    Map<String, String>? iphone({
      String appId = app,
      String platform = 'ios',
      String? token,
      String? bundleId = 'com.nicogs.copydraw',
      String? environment = 'sandbox',
      String? deviceId = 'device-1',
      String? visitorId = 'vis-1',
      String? userId,
      String? language = 'es-MX',
    }) =>
        chatPushBody(
          appId: appId,
          platform: platform,
          token: token ?? apns.toUpperCase(),
          bundleId: bundleId,
          environment: environment,
          deviceId: deviceId,
          visitorId: visitorId,
          userId: userId,
          language: language,
        );

    test('is what the website keeps, field for field', () {
      expect(iphone(), {
        'app': app,
        'platform': 'ios',
        'token': apns,
        'bundle_id': 'com.nicogs.copydraw',
        'environment': 'sandbox',
        'device_id': 'device-1',
        'visitor_id': 'vis-1',
        'language': 'es-MX',
        'display': 'system',
      });
    });

    test('asks the phone to draw the notification, since Flutter cannot', () {
      expect(iphone()?['display'], 'system');
      expect(iphone(platform: 'android', token: fcm)?['display'], 'system');
    });

    test('names no environment for Android, and takes it without a package name', () {
      expect(iphone(platform: 'android', token: fcm, bundleId: null, userId: 'user-9'), {
        'app': app,
        'platform': 'android',
        'token': fcm,
        'device_id': 'device-1',
        'visitor_id': 'vis-1',
        'user_id': 'user-9',
        'language': 'es-MX',
        'display': 'system',
      });
    });

    test('an iPhone build is production unless it says sandbox; no language is English', () {
      expect(iphone(environment: null)?['environment'], 'production');
      expect(iphone(environment: 'development')?['environment'], 'production');
      expect(iphone(language: null)?['language'], 'en');
      expect(iphone(language: '')?['language'], 'en');
    });

    test('is not sent at all when the website would refuse it', () {
      expect(iphone(token: fcm), isNull);
      expect(iphone(deviceId: ''), isNull);
      expect(iphone(deviceId: null), isNull);
      expect(iphone(bundleId: null), isNull);
      expect(iphone(appId: ''), isNull);
      expect(iphone(platform: 'windows'), isNull);
    });

    test('every value is text, so the body is plain JSON', () {
      final body = iphone(userId: 'user-9')!;
      expect(jsonDecode(jsonEncode(body)), body);
    });
  });

  group('the server\'s answer', () {
    test('ok, not taken, failed, or no answer at all', () {
      expect(chatPushAnswer(200, '{"ok":true}'), ChatPushAnswer.ok);
      expect(chatPushAnswer(200, '{"ok":false,"reason":"chat_off"}'), ChatPushAnswer.notTaken);
      expect(chatPushAnswer(200, 'not json'), ChatPushAnswer.notTaken);
      expect(chatPushAnswer(200, null), ChatPushAnswer.notTaken);
      expect(chatPushAnswer(429, '{"error":"Too many requests"}'), ChatPushAnswer.failed);
      expect(chatPushAnswer(500, '{"ok":false}'), ChatPushAnswer.failed);
      expect(chatPushAnswer(404, ''), ChatPushAnswer.failed);
      expect(chatPushAnswer(null, null), ChatPushAnswer.noAnswer);
      expect(chatPushRetryAfter, const Duration(minutes: 5));
    });
  });

  group('knowing a chat notification', () {
    test('reads the iPhone\'s payload, as the website builds it', () {
      final payload = apnsPayload();
      expect(isChatNotification(payload), isTrue);
      expect(
        chatNotificationData(payload),
        const ChatNotificationData(app: app, conversationId: 'c-1', messageId: 'm-1'),
      );
      // A plugin that hands the nested object over as its JSON text.
      final asText = chatNotificationData({'affiliateo_chat': jsonEncode(payload['affiliateo_chat'])});
      expect(asText?.conversationId, 'c-1');
      expect(asText?.messageId, 'm-1');
      // What a method channel hands over: a map with no types.
      final untyped = Map<Object?, Object?>.from(payload);
      expect(isChatNotification(untyped), isTrue);
    });

    test('reads Android\'s data, with the words the phone drew', () {
      final data = fcmData();
      expect(isChatNotification(data), isTrue);
      expect(
        chatNotificationData(data),
        const ChatNotificationData(
          app: app,
          conversationId: 'c-1',
          messageId: 'm-1',
          title: 'Copydraw',
          body: 'We fixed it',
        ),
      );
      // The whole Firebase message as a map works too.
      expect(isChatNotification({'messageId': 'x', 'data': data}), isTrue);
    });

    test('says no to anything else', () {
      expect(isChatNotification(null), isFalse);
      expect(isChatNotification('affiliateo_chat'), isFalse);
      expect(isChatNotification(<String, Object?>{}), isFalse);
      expect(isChatNotification({'aps': {'alert': 'Sale!'}}), isFalse);
      expect(isChatNotification({'affiliateo_chat': ''}), isFalse);
      expect(isChatNotification({'affiliateo_chat': '0'}), isFalse);
      expect(isChatNotification({'affiliateo_chat': false}), isFalse);
      expect(isChatNotification({'affiliateo_chat': null}), isFalse);
      expect(isChatNotification({'data': {'other': '1'}}), isFalse);
      expect(isChatNotification(['affiliateo_chat']), isFalse);
    });
  });

  group('the config says whose chat it is', () {
    const greeting = 'Hi! Need help?';
    Map<String, Object?> config() => {
          'enabled': true,
          'show_bubble': true,
          'online': true,
          'app': {'id': app, 'name': 'Copydraw'},
          'business': {'name': 'Nico Apps', 'logo_url': 'https://cdn.affiliateo.com/logos/nico.png'},
          'greeting': greeting,
          'greetings': {'es': '¡Hola! ¿Dudas?'},
          'bubble': {'greeting_id': 'g-1'},
        };

    test('the Live Chat app\'s name and the business logo, or nothing', () {
      final read = readChatConfig(config());
      expect(read.name, 'Copydraw');
      expect(read.logoUrl, 'https://cdn.affiliateo.com/logos/nico.png');
      // No app name: the business's.
      expect(readChatConfig({...config(), 'app': {'id': app}}).name, 'Nico Apps');
      expect(readChatConfig({...config(), 'business': {'name': 'Nico Apps', 'logo_url': null}}).logoUrl, isNull);
      // Only an https picture is drawn.
      expect(readChatConfig({...config(), 'business': {'logo_url': 'http://plain.example/logo.png'}}).logoUrl, isNull);
      expect(readChatConfig({...config(), 'business': {'logo_url': 'javascript:alert(1)'}}).logoUrl, isNull);
      final odd = readChatConfig({'enabled': true, 'app': 'Copydraw', 'business': 7});
      expect(odd.name, isNull);
      expect(odd.logoUrl, isNull);
      expect(ChatConfig.off.name, isNull);
    });

    test('picks the greeting the chat window would show: the phone\'s language version, else the main one', () {
      final read = readChatConfig(config());
      expect(chatGreetingText(read, 'es'), '¡Hola! ¿Dudas?');
      expect(chatGreetingText(read, 'es-MX'), '¡Hola! ¿Dudas?');
      expect(chatGreetingText(read, 'es_ES'), '¡Hola! ¿Dudas?');
      expect(chatGreetingText(read, 'ES'), '¡Hola! ¿Dudas?');
      expect(chatGreetingText(read, 'fr'), greeting);
      expect(chatGreetingText(read, 'en'), greeting);
      expect(chatGreetingText(read, null), greeting);
      // A server from before `greetings`: the main greeting.
      expect(chatGreetingText(readChatConfig({'enabled': true, 'greeting': greeting}), 'es'), greeting);
      expect(chatGreetingText(readChatConfig({'enabled': true, 'greeting': '  '}), 'es'), isNull);
      // A version that is not text, or empty, is not a version.
      final odd = readChatConfig({...config(), 'greetings': {'es': '  ', 'de': 7, 'ja': 'こんにちは'}});
      expect(chatGreetingText(odd, 'es'), greeting);
      expect(chatGreetingText(odd, 'de'), greeting);
      expect(chatGreetingText(odd, 'ja-JP'), 'こんにちは');
      expect(chatGreetingText(null, 'es'), isNull);
    });
  });

  group('the in-app banner', () {
    const greeting = 'Hi! Need help?';
    const logo = 'https://cdn.affiliateo.com/logos/nico.png';
    final config = readChatConfig({
      'enabled': true,
      'show_bubble': true,
      'online': true,
      'app': {'id': app, 'name': 'Copydraw'},
      'business': {'name': 'Nico Apps', 'logo_url': logo},
      'greeting': greeting,
      'greetings': {'es': '¡Hola! ¿Dudas?'},
      'bubble': {'greeting_id': 'g-1'},
    });

    Map<String, Object?> reply([Map<String, Object?> over = const {}]) => {
          'kind': 'live_chat',
          'conversation_id': 'c-1',
          'event': 'message',
          'message': {
            'id': 'm-1',
            'sender': 'team',
            'body': 'We fixed it.\nTry again?',
            'created_at': '2026-11-11T10:00:00Z',
            ...over,
          },
        };

    ChatBanner? replyWith(
      Object? frame, {
      ChatConfig? config,
      bool noConfig = false,
      bool enabled = true,
      bool chatOpen = false,
      bool appActive = true,
      String language = 'en-US',
    }) =>
        replyBanner(
          frame,
          config: noConfig ? null : config,
          enabled: enabled,
          chatOpen: chatOpen,
          appActive: appActive,
          language: language,
        );

    test('stays five seconds', () {
      expect(chatBannerStay, const Duration(seconds: 5));
    });

    test('says what the push says: one line, cut at the same length, the same words for a message with no text', () {
      expect(chatBannerBodyMax, 180);
      expect(chatBannerText('Hi there!', 'en'), 'Hi there!');
      expect(chatBannerText('  First line\n\nSecond   line\t ', 'en'), 'First line Second line');
      // Cut to 180 characters, the last of them the ellipsis.
      final long = chatBannerText('b' * 400, 'en');
      expect(long.length, 180);
      expect(long, '${'b' * 179}…');
      // Never through the middle of an emoji (each one is two code units).
      final emoji = chatBannerText('😀' * 300, 'en');
      expect(emoji.runes.length, 180);
      expect(emoji, '${'😀' * 179}…');
      // Exactly 180 fits as it is.
      expect(chatBannerText('c' * 180, 'en'), 'c' * 180);
      // No space is left hanging before the ellipsis.
      expect(chatBannerText('${'d' * 178} ${'e' * 50}', 'en'), '${'d' * 178}…');
      for (final entry in sentYouAMessage.entries) {
        expect(chatBannerText(null, entry.key), entry.value, reason: entry.key);
        expect(chatBannerText('', entry.key), entry.value, reason: entry.key);
        expect(chatBannerText('   ', entry.key), entry.value, reason: entry.key);
      }
      expect(chatBannerText(null, 'es-MX'), 'Te envió un mensaje');
      expect(chatBannerText(null, 'zh_Hans'), '给你发了一条消息');
      expect(chatBannerText(null, 'sv'), 'Sent you a message');
      expect(chatBannerText(42, null), 'Sent you a message');
    });

    test('shows a reply from the team while the app is in front and the chat is closed', () {
      expect(
        replyWith(reply(), config: config),
        const ChatBanner(
          id: 'm-1',
          kind: ChatBannerKind.reply,
          title: 'Copydraw',
          body: 'We fixed it. Try again?',
          logoUrl: logo,
        ),
      );
      // No name anywhere: "Chat", in the phone's language.
      expect(replyWith(reply(), config: readChatConfig({'enabled': true}), language: 'tr')?.title, 'Sohbet');
      expect(replyWith(reply({'body': ''}), config: config, language: 'es')?.body, 'Te envió un mensaje');
      // A message with no id still shows.
      expect(replyWith(reply({'id': null}), config: config)?.id, 'reply');
    });

    test('shows nothing while the chat is open, the app is at the back, the banner is off or the chat is off', () {
      expect(replyWith(reply(), config: config, chatOpen: true), isNull);
      expect(replyWith(reply(), config: config, appActive: false), isNull);
      expect(replyWith(reply(), config: config, enabled: false), isNull);
      expect(replyWith(reply(), config: ChatConfig.off), isNull);
      expect(replyWith(reply(), noConfig: true), isNull);
    });

    test('shows nothing for the person\'s own message, a read receipt, a closed line or another kind of frame', () {
      expect(replyWith(reply({'sender': 'visitor'}), config: config), isNull);
      expect(replyWith(reply({'sender': 'system', 'body': 'closed'}), config: config), isNull);
      expect(replyWith({'kind': 'live_chat', 'event': 'read', 'by': 'team'}, config: config), isNull);
      expect(
        replyWith({
          'kind': 'message',
          'event': 'message',
          'message': {'sender': 'team', 'body': 'x'},
        }, config: config),
        isNull,
      );
      expect(replyWith('pong', config: config), isNull);
      expect(replyWith(null, config: config), isNull);
    });

    ChatBanner? greetingWith({
      ChatConfig? config,
      bool noConfig = false,
      bool enabled = true,
      bool chatOpen = false,
      bool appActive = true,
      String language = 'en-US',
      bool allowed = true,
      bool greetingPending = true,
      String? notifiedId,
    }) =>
        greetingBanner(
          config: noConfig ? null : config,
          enabled: enabled,
          chatOpen: chatOpen,
          appActive: appActive,
          language: language,
          allowed: allowed,
          greetingPending: greetingPending,
          notifiedId: notifiedId,
        );

    test('shows the greeting once notifications are allowed, while it is still the red 1, and only once per greeting', () {
      expect(
        greetingWith(config: config),
        const ChatBanner(
          id: 'greeting-g-1',
          kind: ChatBannerKind.greeting,
          greetingId: 'g-1',
          title: 'Copydraw',
          body: greeting,
          logoUrl: logo,
        ),
      );
      expect(greetingWith(config: config, language: 'es-MX')?.body, '¡Hola! ¿Dudas?');
      // Not before the app says notifications are allowed.
      expect(greetingWith(config: config, allowed: false), isNull);
      // Not once the chat was opened or the person wrote (no red 1 any more).
      expect(greetingWith(config: config, greetingPending: false), isNull);
      // Not twice for the same greeting on this phone; a new greeting shows again.
      expect(greetingWith(config: config, notifiedId: 'g-1'), isNull);
      expect(greetingWith(config: config, notifiedId: 'an-older-greeting'), isNotNull);
      // Not when the owner switched "show as unread" off (no greeting id), or there is no greeting.
      final noId = readChatConfig({
        'enabled': true,
        'greeting': greeting,
        'bubble': {'greeting_id': null},
      });
      expect(greetingWith(config: noId), isNull);
      final noWords = readChatConfig({
        'enabled': true,
        'greeting': null,
        'bubble': {'greeting_id': 'g-1'},
      });
      expect(greetingWith(config: noWords), isNull);
      // And under the same roof as every banner: closed chat, app in front, banner on, chat on.
      expect(greetingWith(config: config, chatOpen: true), isNull);
      expect(greetingWith(config: config, appActive: false), isNull);
      expect(greetingWith(config: config, enabled: false), isNull);
      expect(greetingWith(config: ChatConfig.off), isNull);
      expect(greetingWith(noConfig: true), isNull);
    });

    test('remembers the greeting it showed under the app\'s own key', () {
      expect(chatGreetingNotifiedKey('app_1'), 'affiliateo_chat_greeting_notified_app_1');
    });
  });
}
