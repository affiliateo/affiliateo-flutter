import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
///   - Failed events bump a per-event retry counter; dropped after [_maxRetries]
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
///   - _maxRetries = 3
///   - _maxQueueSize = 100      hard cap, FIFO drop on overflow
///   - _flushIntervalMs = 5_000 periodic auto-flush cadence
///   - _sizeFlushThreshold = 10 trigger flush when queue grows past
class EventQueue {
  EventQueue({
    int flushIntervalMs = _defaultFlushIntervalMs,
    int maxQueueSize = _defaultMaxQueueSize,
  }) : this._(
          flushIntervalMs: flushIntervalMs,
          maxQueueSize: maxQueueSize,
          client: null,
          automatic: true,
        );

  /// Tests only: sends through [client], and nothing happens on its own (no
  /// timer, no connectivity listener, no flush at 10 queued or on start), so
  /// a test decides exactly when [flush] runs.
  @visibleForTesting
  EventQueue.forTest({
    required http.Client client,
    int maxQueueSize = _defaultMaxQueueSize,
  }) : this._(
          flushIntervalMs: _defaultFlushIntervalMs,
          maxQueueSize: maxQueueSize,
          client: client,
          automatic: false,
        );

  EventQueue._({
    required int flushIntervalMs,
    required int maxQueueSize,
    required http.Client? client,
    required bool automatic,
  })  : _flushIntervalMs = flushIntervalMs.clamp(1000, 60000),
        _maxQueueSize = maxQueueSize.clamp(10, 1000),
        _client = client,
        _automatic = automatic {
    _ready = _init();
  }

  static const _storageKey = 'affiliateo_event_queue';
  static const _maxRetries = 3;
  static const _defaultMaxQueueSize = 100;
  static const _defaultFlushIntervalMs = 5000;
  static const _sizeFlushThreshold = 10;

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

  // Null in the app: each send is a plain http.post, as before 4.16.1.
  final http.Client? _client;
  // False only in tests (see [EventQueue.forTest]).
  final bool _automatic;
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

  /// Try to deliver every queued event. Each entry gets one attempt per
  /// flush; failures bump retries and stay queued. Entries that hit
  /// [_maxRetries] are dropped. Skipped entirely when offline.
  ///
  /// Neighbouring /mobile/event entries of the same app and device go in
  /// one request (see [_planSends]). Such a request succeeds or fails for
  /// all of its entries together, and each of them is then treated exactly
  /// as a lone entry would be: removed on a 2xx, otherwise one more retry
  /// and dropped at [_maxRetries]. Resending is safe because the server
  /// keeps one row per event_id.
  Future<void> flush() async {
    if (!_hydrated || _isFlushing || _queue.isEmpty || !_isConnected) {
      return;
    }
    _isFlushing = true;
    try {
      // Snapshot the queue so new enqueue()s during the flush land in
      // the live queue and get picked up on the NEXT flush (no infinite
      // loops, easier to reason about).
      final snapshot = List<_QueuedEvent>.from(_queue);

      for (final send in _planSends(snapshot)) {
        bool ok = false;
        try {
          final uri = Uri.parse(send.endpoint);
          const headers = {'Content-Type': 'application/json'};
          final body = send.body();
          final client = _client;
          final response = client != null
              ? await client.post(uri, headers: headers, body: body)
              : await http.post(uri, headers: headers, body: body);
          ok = response.statusCode >= 200 && response.statusCode < 300;
        } catch (_) {
          ok = false;
        }

        for (final event in send.entries) {
          if (ok) {
            _queue.removeWhere((e) => e.id == event.id);
          } else {
            final idx = _queue.indexWhere((e) => e.id == event.id);
            if (idx >= 0) {
              _queue[idx].retries += 1;
              if (_queue[idx].retries >= _maxRetries) {
                _queue.removeAt(idx);
              }
            }
          }
        }
      }

      await _persist();
    } finally {
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
    // as "online" — the queue will retry failed flushes via its own
    // retry counter if a "connected but no internet" state slips
    // through.
    final connectivity = Connectivity();
    // Get the initial state synchronously-ish so we don't start out
    // optimistically and waste retries.
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
      // Came back online — fire a catch-up flush right now instead of
      // waiting up to _flushIntervalMs for the timer.
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
