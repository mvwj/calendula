import 'dart:io';
import 'dart:math';

class TransitRequestError implements Exception {
  final int status;
  final Duration? retryAfter;
  const TransitRequestError(this.status, {this.retryAfter});
  String get message => switch (status) {
    401 ||
    403 => 'PID access is currently denied. Scheduled data stays available.',
    429 =>
      'PID requested fewer requests. Live refresh is paused before retrying.',
    _ => 'PID returned HTTP $status. Scheduled data stays available.',
  };
  @override
  String toString() => message;
}

Duration? parseRetryAfter(String? header, DateTime now) {
  if (header == null) {
    return null;
  }
  final seconds = int.tryParse(header.trim());
  if (seconds != null && seconds >= 0 && seconds <= 604800) {
    return Duration(seconds: seconds);
  }
  try {
    final target = HttpDate.parse(header);
    return target.isAfter(now) ? target.difference(now) : Duration.zero;
  } catch (_) {
    return null;
  }
}

class RefreshPolicy {
  final Duration minimum;
  DateTime? attempted, retryAt;
  int failures = 0;
  RefreshPolicy({this.minimum = const Duration(seconds: 30)});
  Duration waitAt(DateTime now) {
    final earliest = attempted?.add(minimum);
    final blocked = retryAt;
    final until =
        blocked != null && (earliest == null || blocked.isAfter(earliest))
        ? blocked
        : earliest;
    return until != null && until.isAfter(now)
        ? until.difference(now)
        : Duration.zero;
  }

  bool canStart(DateTime now) => waitAt(now) == Duration.zero;
  void start(DateTime now) {
    attempted = now;
  }

  void success() {
    failures = 0;
    retryAt = null;
  }

  void fail(DateTime now, Object error) {
    failures = min(failures + 1, 10);
    final denied =
        error is TransitRequestError &&
        (error.status == 401 || error.status == 403);
    final exponential = Duration(
      seconds: min(30 * (1 << min(failures - 1, 5)), 900),
    );
    final explicit = error is TransitRequestError ? error.retryAfter : null;
    final delay = denied
        ? const Duration(hours: 24)
        : explicit != null && explicit > exponential
        ? explicit
        : exponential;
    retryAt = now.add(delay);
  }
}
