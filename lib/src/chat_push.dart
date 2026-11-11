import 'dart:convert';

import 'chat_rules.dart';
import 'chat_token_store.dart';

// The phone's push token, kept in step with Affiliateo (4.17.0), so a reply
// from the team finds this phone while the app is closed. The same rules as
// the Swift, Kotlin and React Native SDKs:
//
// - The phone is registered (POST /api/live-chat/push-devices) once each
//   launch after the app handed its token over and the server said the chat
//   is on, and again when the token, the app, the language or the signed-in
//   user changes.
// - An answer of any kind is final for that launch: nothing is sent in a
//   loop. Only a request with no answer at all (offline) is tried again, and
//   not sooner than chatPushRetryAfter.
// - A sign-out (logout(), reset(), a different user signing in) has the
//   server forget the phone (DELETE), and the phone is NOT registered again
//   until the next person has a thread of their own: the server finds a
//   phone by its device id, which outlives a sign-out, so a reply to the
//   last person's chat would otherwise show up for whoever holds the phone
//   next.
// - Opted out of tracking: the chat page gets no device id then, so no reply
//   could find the phone. Nothing is registered, and a phone registered
//   before is forgotten.
//
// Plain Dart: the tests run it with fakes.

/// What a registration is built from, read fresh each time.
class ChatPushState {
  const ChatPushState({
    required this.appId,
    required this.chatOn,
    required this.optedOut,
    required this.deviceId,
    required this.visitorId,
    required this.userId,
    required this.language,
    required this.token,
    required this.platform,
    required this.bundleId,
    required this.environment,
  });

  final String appId;

  /// The server said the chat is on for this app.
  final bool chatOn;
  final bool optedOut;

  /// Exactly what the chat page gets as `d=`.
  final String? deviceId;
  final String? visitorId;
  final String? userId;
  final String language;

  /// The token the app handed over in this launch, or null.
  final String? token;

  /// 'ios' or 'android'.
  final String platform;
  final String? bundleId;

  /// iPhone only: 'sandbox' or 'production'.
  final String? environment;
}

class ChatPushRegistrar {
  ChatPushRegistrar({
    required ChatPlainStore store,
    required Future<ChatPushAnswer> Function(String method, Map<String, String> body) send,
    required ChatPushState? Function() state,
    required Future<bool> Function(String appId) hasThread,
    DateTime Function()? now,
    void Function(String message)? log,
  })  : _store = store,
        _send = send,
        _state = state,
        _hasThread = hasThread,
        _now = now ?? DateTime.now,
        _log = log ?? ((_) {});

  final ChatPlainStore _store;
  final Future<ChatPushAnswer> Function(String method, Map<String, String> body) _send;
  final ChatPushState? Function() _state;
  final Future<bool> Function(String appId) _hasThread;
  final DateTime Function() _now;
  final void Function(String message) _log;

  /// One step at a time, in the order they came, so a sign-out never runs
  /// ahead of a registration.
  Future<void> _queue = Future<void>.value();

  /// A sync is waiting its turn: another one would do the same.
  bool _syncWaiting = false;

  /// The registration the server answered in this launch, whatever it said.
  String? _answered;

  // What the store keeps, kept here too: these hold for the launch when the
  // phone's storage does not.
  /// The token the server confirmed.
  String? _registered;

  /// A token the server has yet to forget.
  String? _toForget;

  /// A sign-out since the last thread.
  bool _held = false;

  /// When a request last got no answer.
  DateTime? _triedAt;

  /// The server could not take a "forget this phone" in this launch.
  bool _forgetFailed = false;

  /// A token that cannot be registered was already said so in the log.
  String? _unusable;

  /// Goes up on sign-out: an answer about the last person is dropped.
  int _signOuts = 0;

  Future<void> _run(Future<void> Function() task) {
    final next = _queue.then((_) => task());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return _queue;
  }

  /// Brings the server in line with this phone: a phone to forget first,
  /// then the registration when it is due.
  Future<void> sync() {
    if (_syncWaiting) return _queue;
    _syncWaiting = true;
    return _run(() {
      _syncWaiting = false;
      return _sync();
    });
  }

  /// The person signed out (or another signed in): the server forgets the
  /// phone, and it is not registered again until the next person has a
  /// thread of their own. [token] is the one the app handed over in this
  /// launch, for a phone no earlier launch saw confirmed.
  Future<void> forget(String appId, {String? token, String? platform}) {
    _signOuts++;
    return _run(() async {
      final saved = await _read(chatPushKey(appId)) ??
          _registered ??
          (platform == null ? null : chatPushToken(token, platform));
      if (saved != null) {
        _toForget = saved;
        await _write(chatPushForgetKey(appId), saved);
      }
      await _remove(chatPushKey(appId));
      _registered = null;
      _held = true;
      await _write(chatPushHeldKey(appId), '1');
      // Whatever the server answered before was about the last person.
      _answered = null;
      _forgetFailed = false;
      await _sync();
    });
  }

  Future<void> _sync() async {
    final state = _state();
    if (state == null || state.appId.isEmpty) return;
    final appId = state.appId;

    // Opted out of tracking: the chat carries no device id from now on, so
    // the server forgets this phone. Opting in again registers it again.
    if (state.optedOut) {
      final saved = await _read(chatPushKey(appId)) ?? _registered;
      if (saved != null) {
        _toForget = saved;
        await _write(chatPushForgetKey(appId), saved);
        await _remove(chatPushKey(appId));
      }
      _registered = null;
      _answered = null;
    }

    // A phone to forget goes first, so it can never undo a registration made
    // after it.
    final old = await _read(chatPushForgetKey(appId)) ?? _toForget;
    if (old != null) {
      if (_forgetFailed || !_mayTry()) return;
      switch (await _send('DELETE', {'app': appId, 'token': old})) {
        case ChatPushAnswer.ok:
        case ChatPushAnswer.notTaken:
          if (_toForget == old) _toForget = null;
          if (await _read(chatPushForgetKey(appId)) == old) await _remove(chatPushForgetKey(appId));
        case ChatPushAnswer.failed:
          _forgetFailed = true;
          return;
        case ChatPushAnswer.noAnswer:
          _triedAt = _now();
          return;
      }
    }
    if (state.optedOut) return;

    // After a sign-out: not before the next person has a thread.
    if (_held || await _read(chatPushHeldKey(appId)) == '1') {
      if (!await _hasThread(appId)) return;
      _held = false;
      await _remove(chatPushHeldKey(appId));
    }

    final token = state.token;
    if (token == null || !state.chatOn) return;
    final body = chatPushBody(
      appId: appId,
      platform: state.platform,
      token: token,
      deviceId: state.deviceId,
      bundleId: state.bundleId,
      environment: state.environment,
      visitorId: state.visitorId,
      userId: state.userId,
      language: state.language,
    );
    if (body == null) {
      if (_unusable != token) {
        _unusable = token;
        _log('chat: push token not registered: on iPhone pass the APNs device token '
            '(not a Firebase token) and a bundle id; on Android the Firebase token');
      }
      return;
    }
    final sending = jsonEncode(body);
    if (sending == _answered || !_mayTry()) return;
    final signOuts = _signOuts;
    final answer = await _send('POST', body);
    // A sign-out while this was on its way: forget() has the server forget
    // the phone next, so nothing is kept here.
    if (signOuts != _signOuts) return;
    switch (answer) {
      case ChatPushAnswer.ok:
        _answered = sending;
        _triedAt = null;
        _registered = body['token'];
        await _write(chatPushKey(appId), body['token']!);
        _log('chat: push token registered');
      case ChatPushAnswer.notTaken:
        // No such app, or its chat is off: this phone is not registered.
        _answered = sending;
        _registered = null;
        await _remove(chatPushKey(appId));
        _log('chat: the server did not take the push token');
      case ChatPushAnswer.failed:
        _answered = sending;
        _log('chat: push token not registered (the server); the next launch tries again');
      case ChatPushAnswer.noAnswer:
        _triedAt = _now();
        _log('chat: push token not registered (network)');
    }
  }

  /// Whether enough time has passed since a request got no answer.
  bool _mayTry() {
    final at = _triedAt;
    if (at == null) return true;
    final waited = _now().difference(at);
    return waited.isNegative || waited >= chatPushRetryAfter;
  }

  Future<String?> _read(String key) async {
    try {
      return await _store.read(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (_) {
      // Storage refused: the server's own rule keeps the last person's reply off the phone.
    }
  }

  Future<void> _remove(String key) async {
    try {
      await _store.remove(key);
    } catch (_) {
      // Storage refused.
    }
  }
}
