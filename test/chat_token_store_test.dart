import 'dart:async';

import 'package:affiliateo/src/chat_token_store.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePlain implements ChatPlainStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> remove(String key) async => data.remove(key);
}

class FakeSecrets implements ChatSecretStore {
  final Map<String, String> data = {};
  bool refuse = false;
  Completer<void>? hold;

  @override
  Future<String?> read(String name) async => data[name];

  @override
  Future<bool> write(String name, String value) async {
    await hold?.future;
    if (refuse) return false;
    data[name] = value;
    return true;
  }

  @override
  Future<void> remove(String name) async => data.remove(name);
}

const app = 'app 1';
final token = 'lct_${'b' * 43}';

void main() {
  late FakePlain plain;
  late FakeSecrets secrets;
  late ChatTokenStore store;

  setUp(() {
    plain = FakePlain();
    secrets = FakeSecrets();
    store = ChatTokenStore(secrets, plain);
  });

  test('a saved key comes back; it lives in the secure store only', () async {
    expect(await store.save(app, token), isTrue);
    expect(await store.token(app), token);
    expect(secrets.data[chatSecretName(app)], token);
    expect(plain.data.values, isNot(contains(token)));
    expect(chatSecretName(app), 'affiliateo_chat_token_app_1');
  });

  test('a key a deleted install left in the Keychain is removed, not used', () async {
    secrets.data[chatSecretName(app)] = token;
    expect(await store.token(app), isNull);
    expect(secrets.data, isEmpty);
  });

  test('a key not shaped like one is never handed out or kept', () async {
    expect(await store.save(app, 'lct_nope'), isFalse);
    plain.data[chatTokenSavedKey(app)] = '1';
    secrets.data[chatSecretName(app)] = 'junk';
    expect(await store.token(app), isNull);
  });

  test('a refused write is not marked saved', () async {
    secrets.refuse = true;
    expect(await store.save(app, token), isFalse);
    expect(plain.data[chatTokenSavedKey(app)], isNull);
  });

  test('clear removes the key and the note', () async {
    await store.save(app, token);
    await store.clear(app);
    expect(await store.token(app), isNull);
    expect(secrets.data, isEmpty);
    expect(plain.data, isEmpty);
  });

  test('a save asked for before a sign-out is dropped', () async {
    final before = store.save(app, token);
    final signOut = store.clear(app);
    final after = store.save(app, token);
    expect(await before, isFalse);
    await signOut;
    // Asked for after the sign-out: the next person's key, kept.
    expect(await after, isTrue);
    expect(await store.token(app), token);
  });

  test('a sign-out waits for a save already writing, then removes it', () async {
    secrets.hold = Completer<void>();
    final saving = store.save(app, token);
    await Future<void>.delayed(Duration.zero);
    final signOut = store.clear(app);
    secrets.hold!.complete();
    expect(await saving, isTrue);
    await signOut;
    expect(await store.token(app), isNull);
  });
}
