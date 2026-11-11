import 'dart:async';

import 'package:affiliateo/src/chat_push.dart';
import 'package:affiliateo/src/chat_rules.dart';
import 'package:affiliateo/src/chat_token_store.dart';
import 'package:flutter_test/flutter_test.dart';

// When the phone is registered for chat replies, and when it is taken off
// Affiliateo's list (4.17.0): the rules in IOS-NOTES.md and WEB-NOTES.md,
// the same as the Swift, Kotlin and React Native SDKs.

class FakeStore implements ChatPlainStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> remove(String key) async => data.remove(key);
}

const app = 'app_1';
final fcm = 'dQw4w9WgXcQ:APA91bHuN7xK${'Zq-9_Lm' * 20}';
final fcm2 = 'eRx5x0XhYdR:APA91bHuN7xK${'Zq-9_Lm' * 20}';
final apns = 'cd' * 32;

/// One phone and one server, as the registrar sees them.
class Phone {
  Phone() {
    registrar = ChatPushRegistrar(
      store: store,
      send: (method, body) async {
        sent.add((method, Map<String, String>.of(body)));
        final hold = this.hold;
        if (hold != null) await hold.future;
        return answer;
      },
      state: () => configured
          ? ChatPushState(
              appId: app,
              chatOn: chatOn,
              optedOut: optedOut,
              deviceId: deviceId,
              visitorId: 'vis-1',
              userId: userId,
              language: language,
              token: token,
              platform: platform,
              bundleId: 'com.example.app',
              environment: 'sandbox',
            )
          : null,
      hasThread: (_) async => hasThread,
      now: () => now,
      log: logs.add,
    );
  }

  final store = FakeStore();
  final sent = <(String, Map<String, String>)>[];
  final logs = <String>[];
  late final ChatPushRegistrar registrar;

  ChatPushAnswer answer = ChatPushAnswer.ok;
  Completer<void>? hold;
  DateTime now = DateTime.utc(2026, 11, 11, 12);

  bool configured = true;
  bool chatOn = true;
  bool optedOut = false;
  bool hasThread = false;
  String? deviceId = 'device-1';
  String? userId;
  String language = 'en-US';
  String? token = fcm;
  String platform = 'android';

  List<String> get methods => [for (final (method, _) in sent) method];
  Map<String, String> get last => sent.last.$2;
}

void main() {
  test('registers once the token is handed over and the chat is on, with display "system"', () async {
    final phone = Phone();
    await phone.registrar.sync();
    expect(phone.methods, ['POST']);
    expect(phone.last, {
      'app': app,
      'platform': 'android',
      'token': fcm,
      'device_id': 'device-1',
      'language': 'en-US',
      'display': 'system',
      'bundle_id': 'com.example.app',
      'visitor_id': 'vis-1',
    });
    // The server confirmed this token: a sign-out knows which one to forget.
    expect(phone.store.data[chatPushKey(app)], fcm);
  });

  test('an iPhone registers its APNs token with the bundle id and the environment', () async {
    final phone = Phone()
      ..platform = 'ios'
      ..token = apns.toUpperCase();
    await phone.registrar.sync();
    expect(phone.last['token'], apns);
    expect(phone.last['bundle_id'], 'com.example.app');
    expect(phone.last['environment'], 'sandbox');
    expect(phone.last['display'], 'system');
  });

  test('nothing is sent before configure(), without a token, or while the chat is not known to be on', () async {
    final phone = Phone()..configured = false;
    await phone.registrar.sync();
    phone
      ..configured = true
      ..token = null;
    await phone.registrar.sync();
    phone
      ..token = fcm
      ..chatOn = false;
    await phone.registrar.sync();
    expect(phone.sent, isEmpty);
    // A later config read says the chat is on: now it registers.
    phone.chatOn = true;
    await phone.registrar.sync();
    expect(phone.methods, ['POST']);
  });

  test('the same registration is sent once a launch; a new token, language or user sends it again', () async {
    final phone = Phone();
    await phone.registrar.sync();
    await phone.registrar.sync();
    await phone.registrar.sync();
    expect(phone.methods, ['POST']);

    phone.token = fcm2;
    await phone.registrar.sync();
    expect(phone.methods, ['POST', 'POST']);
    expect(phone.last['token'], fcm2);

    phone.language = 'es-MX';
    await phone.registrar.sync();
    expect(phone.last['language'], 'es-MX');

    // Signing in from anonymous: registered again at once, as that person.
    phone.userId = 'user-9';
    await phone.registrar.sync();
    expect(phone.methods, ['POST', 'POST', 'POST', 'POST']);
    expect(phone.last['user_id'], 'user-9');
    await phone.registrar.sync();
    expect(phone.methods.length, 4);
  });

  test('an answer of any kind is final for the launch: nothing is sent in a loop', () async {
    for (final answer in [ChatPushAnswer.notTaken, ChatPushAnswer.failed]) {
      final phone = Phone()..answer = answer;
      await phone.registrar.sync();
      await phone.registrar.sync();
      phone.now = phone.now.add(const Duration(hours: 1));
      await phone.registrar.sync();
      expect(phone.methods, ['POST'], reason: '$answer');
      // Not confirmed: nothing to forget later.
      expect(phone.store.data.containsKey(chatPushKey(app)), isFalse, reason: '$answer');
    }
  });

  test('a token the server stops taking is no longer kept as registered', () async {
    final phone = Phone();
    await phone.registrar.sync();
    expect(phone.store.data[chatPushKey(app)], fcm);
    phone
      ..answer = ChatPushAnswer.notTaken
      ..language = 'fr';
    await phone.registrar.sync();
    expect(phone.store.data.containsKey(chatPushKey(app)), isFalse);
  });

  test('no answer (offline) is tried again, 5 minutes apart at least', () async {
    final phone = Phone()..answer = ChatPushAnswer.noAnswer;
    await phone.registrar.sync();
    await phone.registrar.sync();
    expect(phone.methods, ['POST']);
    phone.now = phone.now.add(const Duration(minutes: 4, seconds: 59));
    await phone.registrar.sync();
    expect(phone.methods, ['POST']);
    phone
      ..now = phone.now.add(const Duration(seconds: 1))
      ..answer = ChatPushAnswer.ok;
    await phone.registrar.sync();
    expect(phone.methods, ['POST', 'POST']);
    expect(phone.store.data[chatPushKey(app)], fcm);
    // A clock set back does not stop it for good.
    final back = Phone()..answer = ChatPushAnswer.noAnswer;
    await back.registrar.sync();
    back.now = back.now.subtract(const Duration(days: 1));
    await back.registrar.sync();
    expect(back.methods, ['POST', 'POST']);
  });

  test('a token that cannot be registered is said once in the log and never sent', () async {
    final phone = Phone()
      ..platform = 'ios'
      ..token = fcm;
    await phone.registrar.sync();
    await phone.registrar.sync();
    expect(phone.sent, isEmpty);
    expect(phone.logs.where((line) => line.contains('push token not registered')).length, 1);
    // No device id: the reply could not find the phone.
    final noDevice = Phone()..deviceId = null;
    await noDevice.registrar.sync();
    expect(noDevice.sent, isEmpty);
  });

  group('sign-out', () {
    test('the server forgets the phone, and it is not registered again until the next person has a thread', () async {
      final phone = Phone()..userId = 'user-1';
      await phone.registrar.sync();
      expect(phone.methods, ['POST']);

      // logout(): the person is gone.
      phone.userId = null;
      await phone.registrar.forget(app, token: phone.token, platform: phone.platform);
      expect(phone.methods, ['POST', 'DELETE']);
      expect(phone.last, {'app': app, 'token': fcm});
      expect(phone.store.data.containsKey(chatPushKey(app)), isFalse);
      expect(phone.store.data.containsKey(chatPushForgetKey(app)), isFalse);
      expect(phone.store.data[chatPushHeldKey(app)], '1');

      // The app comes to the front, the config is read again: still held.
      await phone.registrar.sync();
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE']);

      // The next person writes their first message: a thread of their own.
      phone.hasThread = true;
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE', 'POST']);
      expect(phone.last.containsKey('user_id'), isFalse);
      expect(phone.store.data.containsKey(chatPushHeldKey(app)), isFalse);
      expect(phone.store.data[chatPushKey(app)], fcm);
    });

    test('a different user signing in is held the same way, then registered under their id', () async {
      final phone = Phone()..userId = 'user-1';
      await phone.registrar.sync();
      phone.userId = 'user-2';
      await phone.registrar.forget(app, token: phone.token, platform: phone.platform);
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE']);
      phone.hasThread = true;
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE', 'POST']);
      expect(phone.last['user_id'], 'user-2');
    });

    test('the hold survives the app being closed and opened', () async {
      final first = Phone();
      await first.registrar.sync();
      await first.registrar.forget(app, token: first.token, platform: first.platform);

      // The next launch: the same phone storage, a registrar that remembers nothing.
      final next = Phone();
      next.store.data.addAll(first.store.data);
      await next.registrar.sync();
      expect(next.sent, isEmpty);
      next.hasThread = true;
      await next.registrar.sync();
      expect(next.methods, ['POST']);
    });

    test('a sign-out made offline is finished later, before anything is registered', () async {
      final phone = Phone();
      await phone.registrar.sync();
      phone.answer = ChatPushAnswer.noAnswer;
      await phone.registrar.forget(app, token: phone.token, platform: phone.platform);
      expect(phone.methods, ['POST', 'DELETE']);
      // Still to forget, and kept across launches.
      expect(phone.store.data[chatPushForgetKey(app)], fcm);

      // The next person already has a thread, but the old phone goes first.
      phone.hasThread = true;
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE']);
      phone
        ..now = phone.now.add(const Duration(minutes: 5))
        ..answer = ChatPushAnswer.ok;
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE', 'DELETE', 'POST']);
      expect(phone.store.data.containsKey(chatPushForgetKey(app)), isFalse);
    });

    test('a forget the server cannot take is not sent in a loop', () async {
      final phone = Phone();
      await phone.registrar.sync();
      phone.answer = ChatPushAnswer.failed;
      await phone.registrar.forget(app, token: phone.token, platform: phone.platform);
      phone.hasThread = true;
      await phone.registrar.sync();
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE']);
    });

    test('a sign-out while a registration is on its way still ends with the phone forgotten', () async {
      final phone = Phone()..hold = Completer<void>();
      final registering = phone.registrar.sync();
      await Future<void>.delayed(Duration.zero);
      expect(phone.methods, ['POST']);

      // The person signs out before the server answered.
      final forgetting = phone.registrar.forget(app, token: phone.token, platform: phone.platform);
      phone.hold!.complete();
      phone.hold = null;
      await registering;
      await forgetting;
      expect(phone.methods, ['POST', 'DELETE']);
      expect(phone.last, {'app': app, 'token': fcm});
      // The answer to the last person's registration was not kept.
      expect(phone.store.data.containsKey(chatPushKey(app)), isFalse);
      expect(phone.store.data[chatPushHeldKey(app)], '1');
    });

    test('a phone that was never registered sends nothing, and is held all the same', () async {
      final phone = Phone()..token = null;
      await phone.registrar.forget(app);
      expect(phone.sent, isEmpty);
      expect(phone.store.data[chatPushHeldKey(app)], '1');
      phone.token = fcm;
      await phone.registrar.sync();
      expect(phone.sent, isEmpty);
    });

    test('an iPhone\'s token is forgotten in the form it was registered in', () async {
      final phone = Phone()
        ..platform = 'ios'
        ..token = apns.toUpperCase()
        ..chatOn = false;
      // Handed over but not registered yet (the chat's switch not read): the
      // server may still know it from an earlier launch.
      await phone.registrar.forget(app, token: phone.token, platform: phone.platform);
      expect(phone.methods, ['DELETE']);
      expect(phone.last, {'app': app, 'token': apns});
    });
  });

  group('opted out of tracking', () {
    test('nothing is registered', () async {
      final phone = Phone()..optedOut = true;
      await phone.registrar.sync();
      expect(phone.sent, isEmpty);
    });

    test('a phone registered before is forgotten, and opting in registers it again', () async {
      final phone = Phone();
      await phone.registrar.sync();
      phone.optedOut = true;
      await phone.registrar.sync();
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE']);
      expect(phone.last, {'app': app, 'token': fcm});
      expect(phone.store.data.containsKey(chatPushKey(app)), isFalse);
      // Not a sign-out: nobody else holds the phone, so nothing is held.
      expect(phone.store.data.containsKey(chatPushHeldKey(app)), isFalse);

      phone.optedOut = false;
      await phone.registrar.sync();
      expect(phone.methods, ['POST', 'DELETE', 'POST']);
    });
  });

  test('calls made at the same moment run one after the other and say the same thing once', () async {
    final phone = Phone()..hold = Completer<void>();
    final all = [phone.registrar.sync(), phone.registrar.sync(), phone.registrar.sync()];
    await Future<void>.delayed(Duration.zero);
    phone.hold!.complete();
    phone.hold = null;
    await Future.wait(all);
    expect(phone.methods, ['POST']);
  });

  test('a phone storage that fails does not stop the registration', () async {
    final phone = Phone();
    final registrar = ChatPushRegistrar(
      store: _BrokenStore(),
      send: (method, body) async {
        phone.sent.add((method, Map<String, String>.of(body)));
        return ChatPushAnswer.ok;
      },
      state: () => const ChatPushState(
        appId: app,
        chatOn: true,
        optedOut: false,
        deviceId: 'device-1',
        visitorId: null,
        userId: null,
        language: 'en',
        token: 'dQw4w9WgXcQ:APA91bHuN7xKZq-9_LmZq-9_LmZq-9_Lm',
        platform: 'android',
        bundleId: null,
        environment: null,
      ),
      hasThread: (_) async => false,
    );
    await registrar.sync();
    expect(phone.methods, ['POST']);
    // And a sign-out still has the server forget the token this launch registered.
    await registrar.forget(app);
    expect(phone.methods, ['POST', 'DELETE']);
  });
}

class _BrokenStore implements ChatPlainStore {
  @override
  Future<String?> read(String key) async => throw StateError('no storage');

  @override
  Future<void> write(String key, String value) async => throw StateError('no storage');

  @override
  Future<void> remove(String key) async => throw StateError('no storage');
}
