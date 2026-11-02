import 'dart:io' show HttpDate;

import 'package:affiliateo/src/send_retry.dart';
import 'package:flutter_test/flutter_test.dart';

/// 4.16.2: what the event queue does with each answer and how long it waits
/// before its next try (send_retry.dart).
void main() {
  final t0 = DateTime.utc(2026, 11, 1, 12);

  test('each status has its outcome', () {
    expect(sendOutcome(null), SendOutcome.kept);
    for (final status in [200, 201, 202, 204, 299]) {
      expect(sendOutcome(status), SendOutcome.sent, reason: '$status');
    }
    for (final status in [400, 401, 403, 405, 409, 410, 413, 415, 422, 451, 499]) {
      expect(sendOutcome(status), SendOutcome.refused, reason: '$status');
    }
    // 404 is the server's "Call /identify first" for a device it does not
    // know yet, which a later try fixes.
    for (final status in [404, 408, 429, 500, 502, 503, 504, 599, 301, 304]) {
      expect(sendOutcome(status), SendOutcome.kept, reason: '$status');
    }
  });

  test('the wait doubles up to 5 minutes', () {
    expect([for (var i = 1; i <= 10; i++) retryWait(i, 500, null, t0, 0.0).inSeconds],
        [5, 10, 20, 40, 80, 160, 300, 300, 300, 300]);
    expect(retryWait(0, null, null, t0, 0.0), const Duration(seconds: 5));
    expect(retryWait(1000, null, null, t0, 0.0), const Duration(minutes: 5));
  });

  test('the jitter adds up to a quarter', () {
    expect(retryWait(1, 500, null, t0, 1.0), const Duration(milliseconds: 6250));
    expect(retryWait(1, 500, null, t0, 0.5), const Duration(milliseconds: 5625));
    expect(retryWait(7, 500, null, t0, 1.0), const Duration(milliseconds: 375000));
    expect(retryWait(1, 500, null, t0, 9.0), const Duration(milliseconds: 6250));
    expect(retryWait(1, 500, null, t0, -1.0), const Duration(seconds: 5));
  });

  test('Retry-After counts for 429 and 503 only', () {
    expect(retryWait(1, 429, '120', t0, 0.0), const Duration(seconds: 120));
    expect(retryWait(1, 503, '120', t0, 0.0), const Duration(seconds: 120));
    expect(retryWait(1, 500, '120', t0, 0.0), const Duration(seconds: 5));
    expect(retryWait(1, 408, '120', t0, 0.0), const Duration(seconds: 5));
    // Never shorter than the backoff, and at most an hour.
    expect(retryWait(3, 429, '2', t0, 0.0), const Duration(seconds: 20));
    expect(retryWait(1, 429, '86400', t0, 0.0), const Duration(hours: 1));
    // The jitter goes on top of what was asked.
    expect(retryWait(1, 429, '60', t0, 1.0), const Duration(seconds: 75));
    // Unreadable: the backoff alone.
    expect(retryWait(2, 503, 'soon', t0, 0.0), const Duration(seconds: 10));
  });

  test('Retry-After reads seconds and dates', () {
    expect(retryAfterDelay('30', t0), const Duration(seconds: 30));
    expect(retryAfterDelay(' 30 ', t0), const Duration(seconds: 30));
    expect(retryAfterDelay('0', t0), Duration.zero);
    expect(retryAfterDelay('99999', t0), const Duration(hours: 1));
    expect(retryAfterDelay('99999999999999999999999', t0), const Duration(hours: 1));
    const date = 'Wed, 21 Oct 2015 07:28:00 GMT';
    final at = DateTime.utc(2015, 10, 21, 7, 28);
    expect(retryAfterDelay(date, at.subtract(const Duration(seconds: 90))), const Duration(seconds: 90));
    expect(retryAfterDelay(date, at.add(const Duration(seconds: 90))), Duration.zero);
    expect(retryAfterDelay(date, at.subtract(const Duration(hours: 2))), const Duration(hours: 1));
    expect(retryAfterDelay(HttpDate.format(t0.add(const Duration(minutes: 2))), t0), const Duration(minutes: 2));
    for (final unreadable in [null, '', '  ', 'soon', '-5', '1.5', '30s', '+30', 'Wed, 21 Oct 2015', '$date and more']) {
      expect(retryAfterDelay(unreadable, t0), isNull, reason: '$unreadable');
    }
  });

  test('a kept answer waits, and the next other answer resets', () {
    final retry = SendRetry(jitter: () => 0.0);
    expect(retry.canSend(t0), isTrue);

    expect(retry.answered(503, null, t0), SendOutcome.kept);
    expect(retry.failures, 1);
    expect(retry.canSend(t0.add(const Duration(milliseconds: 4999))), isFalse);
    expect(retry.canSend(t0.add(const Duration(seconds: 5))), isTrue);

    final t1 = t0.add(const Duration(seconds: 5));
    expect(retry.answered(500, null, t1), SendOutcome.kept);
    expect(retry.failures, 2);
    expect(retry.canSend(t1.add(const Duration(milliseconds: 9999))), isFalse);
    expect(retry.canSend(t1.add(const Duration(seconds: 10))), isTrue);

    expect(retry.answered(200, null, t1), SendOutcome.sent);
    expect(retry.failures, 0);
    expect(retry.canSend(t1), isTrue);

    retry.answered(503, null, t1);
    expect(retry.answered(400, null, t1), SendOutcome.refused);
    expect(retry.failures, 0);
    expect(retry.canSend(t1), isTrue);
  });

  test('the network coming back ends only a wait for the network', () {
    final retry = SendRetry(jitter: () => 0.0);
    retry.answered(null, null, t0);
    retry.answered(null, null, t0);
    expect(retry.canSend(t0), isFalse);
    retry.networkBack();
    expect(retry.canSend(t0), isTrue);
    expect(retry.failures, 0);

    // The server answered "busy, come back in a minute": that holds.
    retry.answered(429, '60', t0);
    retry.networkBack();
    expect(retry.canSend(t0.add(const Duration(seconds: 59))), isFalse);
    expect(retry.canSend(t0.add(const Duration(seconds: 60))), isTrue);
  });
}
