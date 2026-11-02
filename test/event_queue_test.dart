import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:affiliateo/src/queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const api = 'https://affiliateo.test';
const eventUrl = '$api/api/v1/mobile/event';
const purchaseUrl = '$api/api/v1/mobile/purchase';
const adIdsUrl = '$api/api/v1/mobile/ad-ids';
const storageKey = 'affiliateo_event_queue';

/// Answers every request with [status] (or [statusByUrl] for its URL), with
/// [retryAfter] as its Retry-After when set; fails it with [offline], or
/// never answers it with [hang]. Keeps what it was sent.
class FakeServer {
  final List<http.Request> requests = [];
  int status = 200;
  final Map<String, int> statusByUrl = {};
  String? retryAfter;
  bool offline = false;
  bool hang = false;

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    if (offline) throw http.ClientException('offline', request.url);
    if (hang) return Completer<http.Response>().future;
    final after = retryAfter;
    return http.Response(
      '{"ok":true}',
      statusByUrl[request.url.toString()] ?? status,
      headers: {if (after != null) 'retry-after': after},
    );
  });

  List<String> get urls => requests.map((r) => r.url.toString()).toList();
  Map<String, dynamic> body(int i) => jsonDecode(requests[i].body) as Map<String, dynamic>;
  List<dynamic> events(int i) => body(i)['events'] as List<dynamic>;
  List<String> eventIds(int i) => events(i).map((e) => (e as Map)['event_id'] as String).toList();
}

int _count = 0;

/// A queued event the way Affiliateo.page() builds one.
Map<String, dynamic> screenView({Map<String, dynamic>? metadata}) {
  _count++;
  return {
    'type': 'screen_view',
    'timestamp': '2026-10-31T12:00:00.${_count.toString().padLeft(3, '0')}Z',
    'screen': 'Screen $_count',
    if (metadata != null) 'metadata': metadata,
    'event_id': '00000000-0000-4000-8000-${_count.toString().padLeft(12, '0')}',
  };
}

Map<String, dynamic> payload(Map<String, dynamic> event, {String app = 'app-1', String device = 'device-1'}) => {
      'campaign_id': app,
      'device_id': device,
      'events': [event],
    };

void track(EventQueue queue, Map<String, dynamic> event, {String app = 'app-1', String device = 'device-1'}) =>
    queue.enqueue(eventUrl, payload(event, app: app, device: device));

String idOf(Map<String, dynamic> event) => event['event_id'] as String;

/// The queue's clock, moved by hand.
class Clock {
  DateTime now = DateTime.utc(2026, 11, 1, 12);
  void advance(Duration by) => now = now.add(by);
}

Future<EventQueue> openQueue(
  FakeServer server, {
  int maxQueueSize = 100,
  Clock? clock,
  List<String>? logged,
  Duration requestTimeout = const Duration(seconds: 20),
}) async {
  final time = clock ?? Clock();
  final queue = EventQueue.forTest(
    client: server.client,
    maxQueueSize: maxQueueSize,
    // No jitter, so a kept answer's wait is exactly 5 s, 10 s, 20 s...
    now: () => time.now,
    jitter: () => 0.0,
    log: logged?.add,
    requestTimeout: requestTimeout,
  );
  await queue.ready;
  return queue;
}

Future<List<dynamic>> savedQueue() async {
  final prefs = await SharedPreferences.getInstance();
  return jsonDecode(prefs.getString(storageKey) ?? '[]') as List<dynamic>;
}

void main() {
  late FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = FakeServer();
  });

  test('events of one app and device go in one request, each as it was queued', () async {
    final queue = await openQueue(server);
    final sent = [screenView(), screenView(metadata: {'plan': 'pro', 'n': 2, 'x': 1.5}), screenView()];
    for (final e in sent) {
      track(queue, e);
    }

    await queue.flush();

    expect(server.urls, [eventUrl]);
    expect(server.requests.single.headers['content-type'], startsWith('application/json'));
    expect(server.body(0).keys, ['campaign_id', 'device_id', 'events']);
    expect(server.body(0)['campaign_id'], 'app-1');
    expect(server.body(0)['device_id'], 'device-1');
    expect(server.events(0), sent);
    expect(queue.size, 0);
    expect(await savedQueue(), isEmpty);
  });

  test('a lone event goes byte for byte as before', () async {
    final queue = await openQueue(server);
    final only = payload(screenView());
    queue.enqueue(eventUrl, only);

    await queue.flush();

    expect(server.requests.single.body, jsonEncode(only));
  });

  test('another device or app id starts its own request', () async {
    final queue = await openQueue(server);
    final a = screenView(), b = screenView(), c = screenView(), d = screenView(), e = screenView();
    track(queue, a, app: 'app-1', device: 'device-1');
    track(queue, b, app: 'app-1', device: 'device-2');
    track(queue, c, app: 'app-2', device: 'device-2');
    track(queue, d, app: 'app-2', device: 'device-2');
    track(queue, e, app: 'app-1', device: 'device-1');

    await queue.flush();

    expect(server.requests, hasLength(4));
    expect([for (var i = 0; i < 4; i++) '${server.body(i)['campaign_id']}/${server.body(i)['device_id']}'],
        ['app-1/device-1', 'app-1/device-2', 'app-2/device-2', 'app-1/device-1']);
    expect(server.eventIds(0), [idOf(a)]);
    expect(server.eventIds(1), [idOf(b)]);
    expect(server.eventIds(2), [idOf(c), idOf(d)]);
    expect(server.eventIds(3), [idOf(e)]);
    expect(queue.size, 0);
  });

  test('no more than 100 events in one request', () async {
    final queue = await openQueue(server, maxQueueSize: 1000);
    final sent = [for (var i = 0; i < 250; i++) screenView()];
    for (final e in sent) {
      track(queue, e);
    }

    await queue.flush();

    expect([for (var i = 0; i < server.requests.length; i++) server.events(i).length], [100, 100, 50]);
    expect([for (var i = 0; i < 3; i++) ...server.events(i)], sent);
    expect(queue.size, 0);
  });

  test('a body stays under 60,000 bytes, counted in UTF-8', () async {
    final queue = await openQueue(server);
    // About 4.5 KB of UTF-8 per event ('é' is 2 bytes), so 40 of them are
    // about 180 KB: well past one body, well under 100 events.
    final sent = [
      for (var i = 0; i < 40; i++) screenView(metadata: {'note': 'é' * 1500, 'more': 'x' * 1500}),
    ];
    for (final e in sent) {
      track(queue, e);
    }

    await queue.flush();

    expect(server.requests.length, greaterThan(2));
    final sizes = [for (final r in server.requests) r.bodyBytes.length];
    for (final size in sizes) {
      expect(size, lessThanOrEqualTo(EventQueue.maxRequestBytes));
    }
    // Each request was filled as far as it could go: the next request's
    // first event would have passed the cap.
    for (var i = 0; i < sizes.length - 1; i++) {
      final next = utf8.encode(jsonEncode(server.events(i + 1).first)).length;
      expect(sizes[i] + 1 + next, greaterThan(EventQueue.maxRequestBytes));
    }
    expect([for (var i = 0; i < server.requests.length; i++) ...server.events(i)], sent);
    expect(queue.size, 0);
  });

  test('purchases and ad ids are never merged and keep their place', () async {
    final queue = await openQueue(server);
    final e1 = screenView(), e2 = screenView(), e3 = screenView(), e4 = screenView();
    final purchase = {'campaign_id': 'app-1', 'device_id': 'device-1', 'product_id': 'pro', 'price': 9.99};
    final adIds = {'campaign_id': 'app-1', 'device_id': 'device-1', 'gaid': 'abc'};
    track(queue, e1);
    queue.enqueue(purchaseUrl, purchase);
    track(queue, e2);
    track(queue, e3);
    queue.enqueue(adIdsUrl, adIds);
    track(queue, e4);

    await queue.flush();

    expect(server.urls, [eventUrl, purchaseUrl, eventUrl, adIdsUrl, eventUrl]);
    expect(server.eventIds(0), [idOf(e1)]);
    expect(server.requests[1].body, jsonEncode(purchase));
    expect(server.eventIds(2), [idOf(e2), idOf(e3)]);
    expect(server.requests[3].body, jsonEncode(adIds));
    expect(server.eventIds(4), [idOf(e4)]);
    expect(queue.size, 0);
  });

  test('an event entry with any other field goes alone, as queued', () async {
    final queue = await openQueue(server);
    final odd = {...payload(screenView()), 'extra': true};
    track(queue, screenView());
    queue.enqueue(eventUrl, odd);
    track(queue, screenView());

    await queue.flush();

    expect(server.requests, hasLength(3));
    expect(server.requests[1].body, jsonEncode(odd));
  });

  test('a failed request keeps every merged entry, and the retry sends the same events', () async {
    final clock = Clock();
    final queue = await openQueue(server, clock: clock);
    for (var i = 0; i < 5; i++) {
      track(queue, screenView());
    }

    server.status = 500;
    await queue.flush();
    expect(server.requests, hasLength(1));
    expect(queue.size, 5);
    final saved = await savedQueue();
    expect(saved, hasLength(5));
    expect(saved.map((e) => (e as Map)['retries']), everyElement(1));

    // 4.16.2: no next try before the 5 s wait is over, flush() or not.
    await queue.flush();
    expect(server.requests, hasLength(1));

    clock.advance(const Duration(seconds: 5));
    server.offline = true;
    await queue.flush();
    expect(server.requests, hasLength(2));
    expect(queue.size, 5);

    clock.advance(const Duration(seconds: 10));
    server
      ..offline = false
      ..status = 200;
    await queue.flush();
    expect(server.requests, hasLength(3));
    expect(server.events(2), server.events(0));
    expect(queue.size, 0);
  });

  test('a refused request drops every entry in it, with one debug line, and the flush carries on', () async {
    final logged = <String>[];
    final queue = await openQueue(server, logged: logged);
    for (var i = 0; i < 3; i++) {
      track(queue, screenView());
    }
    queue.enqueue(purchaseUrl, {'campaign_id': 'app-1', 'device_id': 'device-1', 'product_id': 'pro', 'price': 9.99});

    server.statusByUrl[eventUrl] = 400;
    await queue.flush();

    // 4.16.2: the same bytes would be refused again, so they are not kept.
    expect(server.urls, [eventUrl, purchaseUrl]);
    expect(server.events(0), hasLength(3));
    expect(queue.size, 0);
    expect(logged, hasLength(1));
    expect(logged.single, contains('HTTP 400'));
    expect(logged.single, contains(eventUrl));
  });

  test('404 and 408 keep the events (404: the device may not be known yet)', () async {
    final clock = Clock();
    final logged = <String>[];
    final queue = await openQueue(server, clock: clock, logged: logged);
    track(queue, screenView());

    for (final status in [404, 408, 404]) {
      server.status = status;
      await queue.flush();
      expect(queue.size, 1, reason: '$status');
      clock.advance(const Duration(minutes: 10));
    }
    expect(server.requests, hasLength(3));
    expect(logged, isEmpty);
  });

  test('a 429 waits as long as its Retry-After asks', () async {
    final clock = Clock();
    final queue = await openQueue(server, clock: clock);
    track(queue, screenView());

    server
      ..status = 429
      ..retryAfter = '30';
    await queue.flush();
    clock.advance(const Duration(seconds: 29));
    await queue.flush();
    expect(server.requests, hasLength(1));

    clock.advance(const Duration(seconds: 1));
    server
      ..status = 200
      ..retryAfter = null;
    await queue.flush();
    expect(server.requests, hasLength(2));
    expect(queue.size, 0);
  });

  test('a 503 waits until its Retry-After date', () async {
    final clock = Clock();
    final queue = await openQueue(server, clock: clock);
    track(queue, screenView());

    server
      ..status = 503
      ..retryAfter = HttpDate.format(clock.now.add(const Duration(seconds: 90)));
    await queue.flush();
    clock.advance(const Duration(seconds: 89));
    await queue.flush();
    expect(server.requests, hasLength(1));

    clock.advance(const Duration(seconds: 1));
    await queue.flush();
    expect(server.requests, hasLength(2));
  });

  test('the wait doubles up to 5 minutes, and a waiting event is never dropped for it', () async {
    final clock = Clock();
    final queue = await openQueue(server, clock: clock);
    track(queue, screenView());
    server.status = 500;

    var tries = 0;
    for (final seconds in [5, 10, 20, 40, 80, 160, 300, 300, 300]) {
      await queue.flush();
      tries++;
      expect(server.requests, hasLength(tries));
      // A second short of the wait: nothing goes.
      clock.advance(Duration(seconds: seconds - 1));
      await queue.flush();
      expect(server.requests, hasLength(tries), reason: 'wait $seconds s');
      clock.advance(const Duration(seconds: 1));
    }
    expect(queue.size, 1);
    expect(((await savedQueue()).single as Map)['retries'], 9);
  });

  test('a kept answer ends the flush: what comes after it waits behind it, in order', () async {
    final clock = Clock();
    final queue = await openQueue(server, clock: clock);
    final e1 = screenView(), e2 = screenView();
    track(queue, e1);
    queue.enqueue(purchaseUrl, {'campaign_id': 'app-1', 'device_id': 'device-1', 'product_id': 'pro', 'price': 9.99});
    track(queue, e2);

    server.statusByUrl[purchaseUrl] = 503;
    await queue.flush();
    expect(server.urls, [eventUrl, purchaseUrl]);
    expect(queue.size, 2);

    server.statusByUrl.clear();
    clock.advance(const Duration(seconds: 5));
    await queue.flush();
    expect(server.urls, [eventUrl, purchaseUrl, purchaseUrl, eventUrl]);
    expect(server.eventIds(3), [idOf(e2)]);
    expect(queue.size, 0);
  });

  test('a request with no answer by its time limit is given up, and its events kept', () async {
    final clock = Clock();
    final queue = await openQueue(server, clock: clock, requestTimeout: const Duration(milliseconds: 50));
    track(queue, screenView());

    server.hang = true;
    await queue.flush();
    expect(server.requests, hasLength(1));
    expect(queue.size, 1);

    server.hang = false;
    clock.advance(const Duration(seconds: 5));
    await queue.flush();
    expect(server.requests, hasLength(2));
    expect(queue.size, 0);
  });

  test('only the size cap drops a waiting event, the oldest first', () async {
    final clock = Clock();
    final queue = await openQueue(server, clock: clock, maxQueueSize: 10);
    server.status = 503;
    final sent = [for (var i = 0; i < 12; i++) screenView()];
    for (final e in sent) {
      track(queue, e);
      await queue.flush();
      clock.advance(const Duration(minutes: 10));
    }
    expect(queue.size, 10);

    server.status = 200;
    await queue.flush();
    expect(server.eventIds(server.requests.length - 1), [for (final e in sent.skip(2)) idOf(e)]);
    expect(queue.size, 0);
  });

  test('each merged entry keeps its own retry count', () async {
    final old = screenView();
    SharedPreferences.setMockInitialValues({
      storageKey: jsonEncode([
        {'id': 'saved-1', 'endpoint': eventUrl, 'payload': jsonEncode(payload(old)), 'retries': 2},
      ]),
    });
    final clock = Clock();
    final queue = await openQueue(server, clock: clock);
    expect(queue.size, 1);
    final fresh = screenView();
    track(queue, fresh);

    server.status = 503;
    await queue.flush();
    expect(server.eventIds(0), [idOf(old), idOf(fresh)]);
    // A third try no longer drops the old entry (4.16.2): both wait, each
    // with its own count.
    expect(queue.size, 2);
    expect([for (final e in await savedQueue()) (e as Map)['retries']], [3, 1]);

    server.status = 200;
    clock.advance(const Duration(seconds: 5));
    await queue.flush();
    expect(server.eventIds(1), [idOf(old), idOf(fresh)]);
    expect(queue.size, 0);
  });
}
