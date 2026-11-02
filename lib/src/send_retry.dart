import 'dart:io' show HttpDate;
import 'dart:math';

/// How the event queue tries again (4.16.2), kept apart from queue.dart so it
/// can be unit tested on its own.
///
/// A 2xx is sent. A refusal (a 4xx other than 404, 408 and 429) is dropped,
/// with one line in the debug log: the same bytes would be refused again.
/// Everything else stays queued and waits: no answer (offline, a time out),
/// 404, 408, 429 and 5xx. The wait is 5 s, doubling up to 5 minutes, plus up
/// to a quarter more so phones do not all come back at once, and never
/// shorter than the Retry-After a 429 or 503 asks for (up to an hour). Only
/// the queue's size cap drops a waiting event.
///
/// 404 waits on purpose: the server answers it for a device whose first
/// identify has not landed yet ("Call /identify first"), which a later try
/// fixes.
enum SendOutcome {
  /// A 2xx: the entries leave the queue.
  sent,

  /// Refused: the entries leave the queue, and the debug log says so.
  refused,

  /// The entries stay, and the queue waits before its next try.
  kept,
}

const firstRetryWait = Duration(seconds: 5);
const maxRetryWait = Duration(minutes: 5);
const maxRetryAfter = Duration(hours: 1);

SendOutcome sendOutcome(int? status) {
  if (status == null) return SendOutcome.kept;
  if (status >= 200 && status < 300) return SendOutcome.sent;
  if (status >= 400 && status < 500 && status != 404 && status != 408 && status != 429) {
    return SendOutcome.refused;
  }
  return SendOutcome.kept;
}

/// The wait after kept answer number [failures] (1 and up): 5 s doubling up
/// to 5 minutes, at least what a 429 or 503 asked for, plus up to a quarter
/// more ([jitter] 0 to 1).
Duration retryWait(int failures, int? status, String? retryAfter, DateTime now, double jitter) {
  var base = min(maxRetryWait.inMilliseconds, firstRetryWait.inMilliseconds << (failures.clamp(1, 7) - 1));
  if (status == 429 || status == 503) {
    final asked = retryAfterDelay(retryAfter, now);
    if (asked != null) base = max(base, asked.inMilliseconds);
  }
  return Duration(milliseconds: base + (base * 0.25 * jitter.clamp(0.0, 1.0)).round());
}

final _digits = RegExp(r'^\d+$');
// Only the date form servers send ("Wed, 21 Oct 2026 07:28:00 GMT").
final _httpDate = RegExp(r'^[A-Za-z]{3}, \d{1,2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$');

/// A Retry-After header as a wait: whole seconds ("120") or an HTTP date
/// (already past is no wait), at most an hour. Null when it is missing or
/// does not read as either.
Duration? retryAfterDelay(String? header, DateTime now) {
  final text = (header ?? '').trim();
  if (text.isEmpty) return null;
  if (_digits.hasMatch(text)) {
    final seconds = int.tryParse(text);
    if (seconds == null || seconds > maxRetryAfter.inSeconds) return maxRetryAfter;
    return Duration(seconds: seconds);
  }
  if (!_httpDate.hasMatch(text)) return null;
  try {
    final at = HttpDate.parse(text);
    return Duration(milliseconds: at.difference(now).inMilliseconds.clamp(0, maxRetryAfter.inMilliseconds));
  } catch (_) {
    return null;
  }
}

/// The queue's retry state: kept answers in a row and when the next try may go.
class SendRetry {
  SendRetry({double Function()? jitter}) : _jitter = jitter ?? Random().nextDouble;

  final double Function() _jitter;

  /// Kept answers in a row.
  int get failures => _failures;
  int _failures = 0;

  /// No flush sends before this; null when nothing waits.
  DateTime? get nextTry => _nextTry;
  DateTime? _nextTry;

  // The wait is for the network (no answer came), not one the server asked for.
  bool _waitIsNetwork = false;

  bool canSend(DateTime now) {
    final next = _nextTry;
    return next == null || !now.isBefore(next);
  }

  /// Takes in one request's answer ([status] null when none came) and says
  /// what becomes of the entries it carried.
  SendOutcome answered(int? status, String? retryAfter, DateTime now) {
    final outcome = sendOutcome(status);
    if (outcome == SendOutcome.kept) {
      _failures += 1;
      _nextTry = now.add(retryWait(_failures, status, retryAfter, now, _jitter()));
      _waitIsNetwork = status == null;
    } else {
      _failures = 0;
      _nextTry = null;
      _waitIsNetwork = false;
    }
    return outcome;
  }

  /// The network came back: a wait for it is over. A wait the server asked
  /// for (it answered, busy) still holds.
  void networkBack() {
    if (!_waitIsNetwork) return;
    _failures = 0;
    _nextTry = null;
    _waitIsNetwork = false;
  }
}
