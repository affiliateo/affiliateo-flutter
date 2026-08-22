import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
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
  })  : _flushIntervalMs = flushIntervalMs.clamp(1000, 60000),
        _maxQueueSize = maxQueueSize.clamp(10, 1000) {
    _init();
  }

  static const _storageKey = 'affiliateo_event_queue';
  static const _maxRetries = 3;
  static const _defaultMaxQueueSize = 100;
  static const _defaultFlushIntervalMs = 5000;
  static const _sizeFlushThreshold = 10;

  // Configurable, clamped at construction. min 1s flush so we don't hammer
  // the network; max 60s so the queue actually drains. Size [10, 1000].
  final int _flushIntervalMs;
  final int _maxQueueSize;

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
    if (_queue.length >= _sizeFlushThreshold) {
      unawaited(flush());
    }
  }

  /// Try to deliver every queued event. Each event gets one attempt
  /// per flush; failures bump retries and stay queued. Events that
  /// hit [_maxRetries] are dropped. Skipped entirely when offline.
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

      for (final event in snapshot) {
        bool ok = false;
        try {
          final response = await http.post(
            Uri.parse(event.endpoint),
            headers: {'Content-Type': 'application/json'},
            body: event.payloadJson,
          );
          ok = response.statusCode >= 200 && response.statusCode < 300;
        } catch (_) {
          ok = false;
        }

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

      await _persist();
    } finally {
      _isFlushing = false;
    }
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
