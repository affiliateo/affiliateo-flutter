import 'chat_rules.dart';

// The visitor's key to their Live Chat thread, on this phone (4.15.4).
// Whoever holds the key can read and write the thread, so it lives in the
// phone's secure store (the iPhone's Keychain, Android's Keystore through
// flutter_secure_storage), on this phone only and never in a backup another
// phone can restore, as the Swift, Kotlin and React Native SDKs keep it.
//
// Deleting the app still starts a new thread: the iPhone's Keychain outlives
// the app, so a key there counts only while this install's own note in
// SharedPreferences (which deleting the app clears) says it saved one; a key
// a deleted install left behind is removed instead of used.
//
// Plain Dart: the tests run it with fakes.

/// SharedPreferences, or anything with its three calls.
abstract class ChatPlainStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// The phone's secure store.
abstract class ChatSecretStore {
  Future<String?> read(String name);

  /// False when it could not be kept.
  Future<bool> write(String name, String value);
  Future<void> remove(String name);
}

/// "This install saved a key in the secure store" (the key itself is never
/// in SharedPreferences).
String chatTokenSavedKey(String appId) => 'affiliateo_chat_token_saved_$appId';

/// The secure store's name for this app's key: letters, digits, dots, dashes
/// and underscores only.
String chatSecretName(String appId) =>
    'affiliateo_chat_token_${appId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';

class ChatTokenStore {
  ChatTokenStore(this._secrets, this._plain);

  final ChatSecretStore _secrets;
  final ChatPlainStore _plain;

  /// One call at a time, in the order they came, so a sign-out never runs
  /// ahead of a save.
  Future<void> _queue = Future<void>.value();

  /// Goes up on every [clear]: a save asked for before it is dropped.
  int _clears = 0;

  Future<T> _run<T>(Future<T> Function() task) {
    final next = _queue.then((_) => task());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// The key for this app's thread, or null.
  Future<String?> token(String appId) {
    return _run(() async {
      final name = chatSecretName(appId);
      final saved = await _safe(() => _plain.read(chatTokenSavedKey(appId))) == '1';
      final found = await _safe(() => _secrets.read(name));
      if (!saved) {
        // Left by an install of the app that was deleted since.
        if (found != null) await _safe(() => _secrets.remove(name));
        return null;
      }
      return isChatToken(found) ? found : null;
    });
  }

  /// Keeps the key the chat page handed over. False when it was not kept (or
  /// a sign-out came after it was asked for).
  Future<bool> save(String appId, String token) {
    final clearsBefore = _clears;
    return _run(() async {
      if (clearsBefore != _clears || !isChatToken(token)) return false;
      final kept = await _safe(() => _secrets.write(chatSecretName(appId), token)) ?? false;
      if (!kept) return false;
      await _safe(() => _plain.write(chatTokenSavedKey(appId), '1'));
      return true;
    });
  }

  /// The person signed out (or another signed in): their key goes.
  Future<void> clear(String appId) {
    _clears++;
    return _run(() async {
      await Future.wait<void>([
        _safe(() => _secrets.remove(chatSecretName(appId))),
        _safe(() => _plain.remove(chatTokenSavedKey(appId))),
      ]);
    });
  }

  static Future<T?> _safe<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return null;
    }
  }
}
