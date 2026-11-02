import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'send_retry.dart';

/// EventQueue: durable best-effort delivery for analytics events.
///
/// Mirrors the @affiliateo/web, @affiliateo/react-native, affiliateo-swift,
/// and affiliateo-kotlin queues so all five platforms behave consistently
/// for merchants integrating across multiple targets.
///
/// Architecture:
///   - In-memory `_queue` list of [_QueuedEvent] (id + endpoint + JSON payload + retries)
///   - Persisted to SharedPreferences under [_storageKey] as a JSON array on every mutation
///   - A periodic [Timer] fires every [_flushIntervalMs] to attempt delivery
///   - connectivity_plus stream pauses flushing while offline; fires an
///     immediate flush the moment connectivity returns (no waiting for the timer)
///   - Retries (4.16.2, see send_retry.dart): an answer that may change (no
///     answer, 404, 408, 429, 5xx) keeps the request's events, and the queue
///     waits 5 s, doubling up to 5 minutes, before its next try, at least as
///     long as a 429 or 503 asks (Retry-After). The rest of that flush waits
///     too. A refusal (another 4xx) drops them, with one debug line. Only the
///     size cap drops a waiting event; it used to be dropped after its third
///     failed try, on the fixed 5 s timer
///   - Since 4.16.1 one flush sends neighbouring /mobile/event entries of the
///     same app and device as ONE request (see [_planSends]); every other
///     endpoint still goes one entry per request, in queue order
///
/// Why shared_preferences instead of sqflite / hive:
///   shared_preferences is the platform-idiomatic key-value store for
///   small structured data. At 100 events × ~500 bytes each we're at
///   50 KB max, well inside its comfort zone. sqflite would add migration
///   headaches; hive a transitive Pub dep for no real benefit.
///
/// Caps (matched to web + RN + Swift + Kotlin for cross-platform consistency):
///   - _maxQueueSize = 100      hard cap, FIFO drop on overflow
///   - _flushIntervalMs = 5_000 periodic auto-flush cadence
///   - _sizeFlushThreshold = 10 trigger flush when queue grows past
///   - _requestTimeout = 20 s   a request with no answer by then is given up
///                              (and its events kept)
class EventQueue {
  EventQueue({
    int flushIntervalMs = _defaultFlushIntervalMs,
    int maxQueueSize = _defaultMaxQueueSize,
    void Function(String message)? log,
  }) : this._(
          flushIntervalMs: flushIntervalMs,
          maxQueueSize: maxQueueSize,
          client: null,
          automatic: true,
          now: DateTime.now,
          jitter: null,
          log: log,
          requestTimeout: _defaultRequestTimeout,
        );

  /// Tests only: sends through [client], and nothing happens on its own (no
  /// timer, no connectivity listener, no flush at 10 queued or on start), so
  /// a test decides exactly when [flush] runs. [now] and [jitter] (0 to 1)
  /// set the clock and the spread of the retry waits.
  @visibleForTesting
  EventQueue.forTest({
    required http.Client client,
    int maxQueueSize = _defaultMaxQueueSize,
    DateTime Function()? now,
    double Function()? jitter,
    void Function(String message)? log,
    Duration requestTimeout = _defaultRequestTimeout,
  }) : this._(
          flushIntervalMs: _defaultFlushIntervalMs,
          maxQueueSize: maxQueueSize,
          client: client,
          automatic: false,
          now: now ?? DateTime.now,
          jitter: jitter,
          log: log,
          requestTimeout: requestTimeout,
        );

  EventQueue._({
    required int flushIntervalMs,
    required int maxQueueSize,
    required http.Client? client,
    required bool automatic,
    required DateTime Function() now,
    required double Function()? jitter,
    required void Function(String message)? log,
    required Duration requestTimeout,
  })  : _flushIntervalMs = flushIntervalMs.clamp(1000, 60000),
        _maxQueueSize = maxQueueSize.clamp(10, 1000),
        _client = client,
        _automatic = automatic,
        _now = now,
        _retry = SendRetry(jitter: jitter),
        _log = log,
        _requestTimeout = requestTimeout {
    _ready = _init();
  }

  static const _storageKey = 'affiliateo_event_queue';
  static const _defaultMaxQueueSize = 100;
  static const _defaultFlushIntervalMs = 5000;
  static const _sizeFlushThreshold = 10;
  // How long a request may go without an answer (4.16.2). There was no limit:
  // a request that hung held the queue until the app closed.
  static const _defaultRequestTimeout = Duration(seconds: 20);

  /// The event endpoint whose entries one flush may merge into one request.
  static const _eventPath = '/api/v1/mobile/event';

  /// The server refuses more than 100 events in one request (400).
  @visibleForTesting
  static const maxEventsPerRequest = 100;

  /// The server refuses a body over 64 KB (413). Kept a little under it.
  @visibleForTesting
  static const maxRequestBytes = 60000;

  // Configurable, clamped at construction. min 1s flush so we don't hammer
  // the network; max 60s so the queue actually drains. Size [10, 1000].
  final int _flushIntervalMs;
  final int _maxQueueSize;

  // Null in the app: each flush opens its own client and closes it at the
  // end (4.16.2), which also ends a request given up on its time limit.
  final http.Client? _client;
  // False only in tests (see [EventQueue.forTest]).
  final bool _automatic;
  final DateTime Function() _now;
  // When the next try may go after a kept answer (4.16.2).
  final SendRetry _retry;
  final void Function(String message)? _log;
  final Duration _requestTimeout;
  late final Future<void> _ready;

  final List<_QueuedEvent> _queue = [];
  Timer? _flushTimer;
  bool _isFlushing = false;
  bool _shuttingDown = false;
  // Optimistic default. The Connectivity stream's first event flips
  // this to the real value within a few hundred ms of init.
  bool _isConnected = true;
  StreamSubscription? _connectivitySub;
  bool _hydrated = false;

  Future<void> _init() async {
    await _loadFromDisk();
    _hydrated = true;
    if (!_automatic) return;
    _startConnectivityListener();
    _startFlushTimer();
    // Catch-up flush in case the previous app session ended with events
    // still queued. Best-effort: noops when offline.
    if (_queue.isNotEmpty) {
      unawaited(flush());
    }
  }

  /// Add an event to the queue. Returns immediately; persistence is
  /// async but the in-memory push is synchronous.
  void enqueue(String endpoint, Map<String, dynamic> payload) {
    if (_shuttingDown) return;
    final payloadJson = jsonEncode(payload);
    final event = _QueuedEvent(
      id: _uuid(),
      endpoint: endpoint,
      payloadJson: payloadJson,
      retries: 0,
    );
    _queue.add(event);
    // FIFO drop when over cap. Network outage edge case: under sustained
    // failure the queue would grow until shared_preferences started
    // slowing down. 100 events is a sane upper bound that protects
    // without dropping anything during normal use.
    if (_queue.length > _maxQueueSize) {
      _queue.removeRange(0, _queue.length - _maxQueueSize);
    }
    unawaited(_persist());
    if (_automatic && _queue.length >= _sizeFlushThreshold) {
      unawaited(flush());
    }
  }

  /// Try to deliver every queued event, in queue order. Skipped entirely
  /// when offline, and until the wait after a kept answer is over (4.16.2,
  /// see send_retry.dart).
  ///
  /// Neighbouring /mobile/event entries of the same app and device go in
  /// one request (see [_planSends]), and its answer counts for all of them:
  /// sent or refused, they leave the queue; kept, each counts one more try
  /// and stays, and the flush ends there, so the rest waits behind them.
  /// Resending is safe because the server keeps one row per event_id.
  Future<void> flush() async {
    if (!_hydrated || _isFlushing || _queue.isEmpty || !_isConnected || !_retry.canSend(_now())) {
      return;
    }
    _isFlushing = true;
    // One client for the whole flush; closing it ends a request still
    // running after its time limit.
    final client = _client ?? http.Client();
    try {
      // Snapshot the queue so new enqueue()s during the flush land in
      // the live queue and get picked up on the NEXT flush (no infinite
      // loops, easier to reason about).
      final snapshot = List<_QueuedEvent>.from(_queue);

      for (final send in _planSends(snapshot)) {
        int? status;
        String? retryAfter;
        try {
          final uri = Uri.parse(send.endpoint);
          const headers = {'Content-Type': 'application/json'};
          final response = await client.post(uri, headers: headers, body: send.body()).timeout(_requestTimeout);
          status = response.statusCode;
          retryAfter = response.headers['retry-after'];
        } catch (_) {
          // No answer: offline, a time out, an address that cannot be read.
        }

        final outcome = _retry.answered(status, retryAfter, _now());
        final ids = {for (final e in send.entries) e.id};
        if (outcome == SendOutcome.kept) {
          // An entry gone meanwhile (clear(), the size cap) is skipped.
          for (final e in _queue) {
            if (ids.contains(e.id)) e.retries += 1;
          }
          // The server is busy or out of reach for the rest too.
          break;
        }
        _queue.removeWhere((e) => ids.contains(e.id));
        if (outcome == SendOutcome.refused) {
          _log?.call('dropped ${ids.length} queued event(s): the server refused them (HTTP $status, ${send.endpoint})');
        }
      }

      await _persist();
    } finally {
      if (_client == null) client.close();
      _isFlushing = false;
    }
  }

  /// Splits one flush's entries into requests, keeping queue order.
  ///
  /// A run of neighbouring entries goes in one request when every one of
  /// them is for /mobile/event on the same URL with the same campaign_id
  /// (app id) and device_id, and carries nothing but those two and its
  /// `events`. Their `events` lists are joined in order and each event goes
  /// as it was queued (its own event_id, timestamp and fields). A new
  /// request starts when the next entry would pass [maxEventsPerRequest]
  /// events or [maxRequestBytes] bytes of body. Anything else (purchases,
  /// ad ids, an entry that cannot be read) is a request of its own, sent
  /// exactly as queued, and it ends the run, so nothing changes places.
  List<_Send> _planSends(List<_QueuedEvent> snapshot) {
    final sends = <_Send>[];
    _EventSend? run;
    for (final entry in snapshot) {
      final parts = _EventParts.read(entry);
      if (parts == null) {
        run = null;
        sends.add(_Send(entry));
        continue;
      }
      final current = run;
      if (current != null &&
          current.sameTarget(parts) &&
          current.eventCount + parts.events.length <= maxEventsPerRequest &&
          current.bytesWith(parts) <= maxRequestBytes) {
        current.add(entry, parts);
        continue;
      }
      // A first entry always opens a request, even one over a cap on its
      // own: it then goes alone, as it always has.
      final opened = _EventSend(entry, parts);
      run = opened;
      sends.add(opened);
    }
    return sends;
  }

  /// Wipe all queued events. Called by reset() and optOut().
  Future<void> clear() async {
    _queue.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }

  /// Stop the timer + connectivity subscription. Idempotent. Best-effort
  /// last flush attempt. Anything still queued persists to disk.
  Future<void> shutdown() async {
    _shuttingDown = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    await flush();
  }

  /// Read-only count. Used by tests / debug helpers.
  int get size => _queue.length;

  /// Tests only: done once the saved queue is loaded, so [flush] can run.
  @visibleForTesting
  Future<void> get ready => _ready;

  // MARK: - Private

  Future<void> _loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map) continue;
        final id = item['id'];
        final endpoint = item['endpoint'];
        final payloadJson = item['payload'];
        final retries = item['retries'];
        if (id is String && endpoint is String && payloadJson is String && retries is int) {
          _queue.add(_QueuedEvent(
            id: id,
            endpoint: endpoint,
            payloadJson: payloadJson,
            retries: retries,
          ));
        }
      }
    } catch (_) {
      // Corrupt or wrong-shape entries — reset rather than crash on
      // load. Better to drop a few stuck events than block all future
      // tracking on a parse error.
      _queue.clear();
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final serialized = _queue.map((e) => {
        'id': e.id,
        'endpoint': e.endpoint,
        'payload': e.payloadJson,
        'retries': e.retries,
      }).toList();
      await prefs.setString(_storageKey, jsonEncode(serialized));
    } catch (_) {
      // Quota / I/O error — swallow.
    }
  }

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      // NOT const. _flushIntervalMs is an instance field assigned in the
      // constructor's initializer list from a clamped constructor argument,
      // so its value is only known at runtime — `const` here is the
      // invalid_constant error this file failed analysis on.
      Duration(milliseconds: _flushIntervalMs),
      (_) => unawaited(flush()),
    );
  }

  void _startConnectivityListener() {
    // connectivity_plus emits a [ConnectivityResult] (or List on 5.x+) every
    // time the connection state changes. Treat anything that isn't `none`
    // as "online": if a "connected but no internet" state slips through,
    // the requests get no answer and the queue keeps their events and
    // tries again later.
    final connectivity = Connectivity();
    // Get the initial state synchronously-ish so we don't start out
    // optimistically and send into nothing.
    connectivity.checkConnectivity().then((result) {
      _updateConnectivity(result);
    }).catchError((_) { /* swallow */ });
    _connectivitySub = connectivity.onConnectivityChanged.listen((result) {
      _updateConnectivity(result);
    });
  }

  void _updateConnectivity(Object result) {
    // connectivity_plus 5.x returns a List<ConnectivityResult>; earlier
    // versions return a single ConnectivityResult. Handle both.
    final wasOffline = !_isConnected;
    final connected = (result is List)
        ? result.any((r) => r != ConnectivityResult.none)
        : (result != ConnectivityResult.none);
    _isConnected = connected;
    if (wasOffline && _isConnected) {
      // Came back online: a wait for the network is over (one the server
      // asked for still holds), so fire a catch-up flush right now instead
      // of waiting up to _flushIntervalMs for the timer.
      _retry.networkBack();
      unawaited(flush());
    }
  }

  String _uuid() {
    // RFC 4122 v4 UUID. Same pattern as the rest of the SDK to avoid
    // a transitive dep just for UUID generation.
    final r = Random.secure();
    String hex(int n) => n.toRadixString(16).padLeft(2, '0');
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
}

class _QueuedEvent {
  _QueuedEvent({
    required this.id,
    required this.endpoint,
    required this.payloadJson,
    required this.retries,
  });

  final String id;
  final String endpoint;
  final String payloadJson;
  // Kept answers so far. A record only since 4.16.2: nothing is dropped
  // for it.
  int retries;
}

/// One request of a flush: a single entry, sent exactly as it was queued.
class _Send {
  _Send(_QueuedEvent entry)
      : endpoint = entry.endpoint,
        entries = [entry];

  final String endpoint;
  final List<_QueuedEvent> entries;

  String body() => entries.first.payloadJson;
}

/// One request of a flush carrying the `events` of one or more neighbouring
/// /mobile/event entries for the same app and device.
class _EventSend extends _Send {
  _EventSend(super.entry, _EventParts parts)
      : _campaignId = parts.campaignId,
        _deviceId = parts.deviceId,
        _events = List<Object?>.of(parts.events),
        _eventBytes = parts.eventBytes,
        _shellBytes = _utf8Length(jsonEncode({
          'campaign_id': parts.campaignId,
          'device_id': parts.deviceId,
          'events': const <Object?>[],
        }));

  final String _campaignId;
  final String _deviceId;
  final List<Object?> _events;
  // UTF-8 bytes of the events joined by commas, and of the body around
  // them. jsonEncode adds no spaces, so the two make the body's exact size.
  int _eventBytes;
  final int _shellBytes;

  int get eventCount => _events.length;

  bool sameTarget(_EventParts parts) =>
      parts.endpoint == endpoint && parts.campaignId == _campaignId && parts.deviceId == _deviceId;

  /// The body's size in bytes once [parts] joins (1 for the comma).
  int bytesWith(_EventParts parts) => _shellBytes + _eventBytes + 1 + parts.eventBytes;

  void add(_QueuedEvent entry, _EventParts parts) {
    entries.add(entry);
    _events.addAll(parts.events);
    _eventBytes += 1 + parts.eventBytes;
  }

  /// A lone entry goes byte for byte as queued; several go as one body in
  /// the shape the server reads: { campaign_id, device_id, events }.
  @override
  String body() {
    if (entries.length == 1) return super.body();
    return jsonEncode({
      'campaign_id': _campaignId,
      'device_id': _deviceId,
      'events': _events,
    });
  }
}

/// What a queued /mobile/event entry holds, or null from [read] when the
/// entry may not join others (another endpoint, unreadable, or any field
/// besides campaign_id, device_id and events, which would be lost).
class _EventParts {
  _EventParts._(this.endpoint, this.campaignId, this.deviceId, this.events, this.eventBytes);

  final String endpoint;
  final String campaignId;
  final String deviceId;
  final List<Object?> events;
  // UTF-8 bytes of the events joined by commas.
  final int eventBytes;

  static _EventParts? read(_QueuedEvent entry) {
    if (!entry.endpoint.endsWith(EventQueue._eventPath)) return null;
    try {
      final payload = jsonDecode(entry.payloadJson);
      if (payload is! Map || payload.length != 3) return null;
      final campaignId = payload['campaign_id'];
      final deviceId = payload['device_id'];
      final events = payload['events'];
      if (campaignId is! String || deviceId is! String || events is! List || events.isEmpty) {
        return null;
      }
      var bytes = events.length - 1;
      for (final event in events) {
        bytes += _utf8Length(jsonEncode(event));
      }
      return _EventParts._(entry.endpoint, campaignId, deviceId, events, bytes);
    } catch (_) {
      return null;
    }
  }
}

int _utf8Length(String s) => utf8.encode(s).length;
