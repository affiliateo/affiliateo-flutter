import 'dart:convert';

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

/// Answers every request with [status] (or fails it, with [offline]) and
/// keeps what it was sent.
class FakeServer {
  final List<http.Request> requests = [];
  int status = 200;
  bool offline = false;

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    if (offline) throw http.ClientException('offline', request.url);
    return http.Response('{"ok":true}', status);
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

Future<EventQueue> openQueue(FakeServer server, {int maxQueueSize = 100}) async {
  final queue = EventQueue.forTest(client: server.client, maxQueueSize: maxQueueSize);
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
    final queue = await openQueue(server);
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

    server.offline = true;
    await queue.flush();
    expect(server.requests, hasLength(2));
    expect(queue.size, 5);

    server
      ..offline = false
      ..status = 200;
    await queue.flush();
    expect(server.requests, hasLength(3));
    expect(server.events(2), server.events(0));
    expect(queue.size, 0);
  });

  test('a refused request counts one try for every entry in it, as for a lone entry', () async {
    final queue = await openQueue(server);
    for (var i = 0; i < 3; i++) {
      track(queue, screenView());
    }

    server.status = 400;
    await queue.flush();
    expect(queue.size, 3);
    server.status = 404;
    await queue.flush();
    expect(queue.size, 3);
    await queue.flush();
    // Third try: dropped, as one entry always was.
    expect(queue.size, 0);
    expect([for (var i = 0; i < 3; i++) server.events(i).length], [3, 3, 3]);
  });

  test('each merged entry keeps its own retry count', () async {
    final old = screenView();
    SharedPreferences.setMockInitialValues({
      storageKey: jsonEncode([
        {'id': 'saved-1', 'endpoint': eventUrl, 'payload': jsonEncode(payload(old)), 'retries': 2},
      ]),
    });
    final queue = await openQueue(server);
    expect(queue.size, 1);
    final fresh = screenView();
    track(queue, fresh);

    server.status = 503;
    await queue.flush();
    expect(server.eventIds(0), [idOf(old), idOf(fresh)]);
    // The old entry had its last try; the fresh one has had one.
    expect(queue.size, 1);
    expect(((await savedQueue()).single as Map)['retries'], 1);

    server.status = 200;
    await queue.flush();
    expect(server.eventIds(1), [idOf(fresh)]);
    expect(queue.size, 0);
  });
}
