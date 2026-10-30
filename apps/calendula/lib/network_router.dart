import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'transit.dart';

class JourneyLeg {
  final String from, to, line, headsign, tripId;
  final int mode;
  final DateTime departure, arrival;
  final bool predicted, estimated, requestStop;
  const JourneyLeg(
    this.from,
    this.to,
    this.line,
    this.headsign,
    this.tripId,
    this.mode,
    this.departure,
    this.arrival, {
    this.predicted = false,
    this.estimated = false,
    this.requestStop = false,
  });
  Map<String, dynamic> toJson() => {
    'from': from,
    'to': to,
    'line': line,
    'headsign': headsign,
    'trip': tripId,
    'mode': mode,
    'departure': departure.millisecondsSinceEpoch,
    'arrival': arrival.millisecondsSinceEpoch,
    'predicted': predicted,
    'estimated': estimated,
    'requestStop': requestStop,
  };
  factory JourneyLeg.fromJson(Map<String, dynamic> j) => JourneyLeg(
    j['from'],
    j['to'],
    j['line'],
    j['headsign'],
    j['trip'],
    j['mode'],
    DateTime.fromMillisecondsSinceEpoch(j['departure'], isUtc: true),
    DateTime.fromMillisecondsSinceEpoch(j['arrival'], isUtc: true),
    predicted: j['predicted'],
    estimated: j['estimated'],
    requestStop: j['requestStop'] == true,
  );
}

class NetworkJourney {
  final List<JourneyLeg> legs;
  NetworkJourney(this.legs);
  DateTime get departure => legs.first.departure;
  DateTime get arrival => legs.last.arrival;
  int get changes => max(0, legs.where((l) => l.mode >= 0).length - 1);
  bool get estimatedWalking => legs.any((l) => l.estimated);
}

class _Edge {
  final String from, to;
  final int seconds;
  final bool estimated;
  _Edge(this.from, this.to, this.seconds, this.estimated);
}

class _Label {
  final int time;
  final List<JourneyLeg> legs;
  final int seed;
  const _Label(this.time, this.legs, this.seed);
}

/// Walking costs belong to the graph seeds, so all access stops can share one
/// search without preferring a nearby stop with a slower transit connection.
class NetworkEndpoint {
  final String stop, label;
  final int walkMinutes;
  const NetworkEndpoint(this.stop, this.label, this.walkMinutes);
}

class NetworkEndpointRoute {
  final NetworkJourney journey;
  final int origin, destination;
  const NetworkEndpointRoute(this.journey, this.origin, this.destination);
}

NetworkJourney endpointWalks(
  NetworkJourney route,
  NetworkEndpoint from,
  NetworkEndpoint to,
) => NetworkJourney([
  if (from.walkMinutes > 0)
    JourneyLeg(
      from.label,
      from.stop,
      '',
      '',
      '',
      -1,
      route.departure.subtract(Duration(minutes: from.walkMinutes)),
      route.departure,
      estimated: true,
    ),
  ...route.legs,
  if (to.walkMinutes > 0)
    JourneyLeg(
      to.stop,
      to.label,
      '',
      '',
      '',
      -1,
      route.arrival,
      route.arrival.add(Duration(minutes: to.walkMinutes)),
      estimated: true,
    ),
]);

class NetworkIndex {
  final String start, end;
  final Map<String, List<dynamic>> stops;
  final List<dynamic> trips;
  final Map<String, List<_Edge>> _outgoing = {}, _incoming = {};
  final Map<String, int> change = {};
  final Map<String, Set<String>> _names = {};
  String? _preparedKey;
  List<(List, List<List<dynamic>>)>? _preparedCache;
  late final List<String> stations;
  NetworkIndex(Map<String, dynamic> j)
    : start = j['start'],
      end = j['end'],
      stops = {
        for (final e in (j['stops'] as Map).entries)
          e.key as String: List<dynamic>.from(e.value),
      },
      trips = j['trips'] {
    if (DateTime.parse(end).difference(DateTime.parse(start)).inDays > 31 ||
        start.compareTo(end) > 0 ||
        trips.length > 500000 ||
        stops.length > 50000) {
      throw const FormatException('Invalid network bounds.');
    }
    final served = <String>{};
    for (final stop in stops.values) {
      if (stop.length < 6 ||
          stop[0] is! String ||
          stop[2] is! num ||
          stop[3] is! num ||
          !stop[2].isFinite ||
          !stop[3].isFinite ||
          stop[2] < -90 ||
          stop[2] > 90 ||
          stop[3] < -180 ||
          stop[3] > 180) {
        throw const FormatException('Invalid network stop.');
      }
    }
    for (final raw in trips) {
      final t = raw as List;
      if (t.length != 7 || t[3] is! int || t[3] < 0 || t[5] is! int) {
        throw const FormatException('Invalid network trip.');
      }
      var seq = -1, previous = -1;
      for (final raw in t[4]) {
        final s = raw as List;
        if (s.length != 6 ||
            !stops.containsKey(s[0]) ||
            s[1] <= seq ||
            s[2] < previous ||
            s[3] < s[2] ||
            s[3] > 259200 ||
            s[4] < 0 ||
            s[4] > 3 ||
            s[5] < 0 ||
            s[5] > 3) {
          throw const FormatException('Invalid network stop time.');
        }
        seq = s[1];
        previous = s[3];
        served.add(s[0]);
      }
    }
    stations = {for (final id in served) stops[id]![0] as String}.toList()
      ..sort();
    final blocked = <String>{};
    for (final r in j['transfers'] ?? []) {
      if (r[4] != '' || r[5] != '') {
        continue; // Timed trip-specific guarantees are not inferred.
      }
      if (r[2] == 3) blocked.add('${r[0]}|${r[1]}');
      if (r[0] == r[1] && r[2] == 2) {
        change[r[0]] = max(change[r[0]] ?? 60, r[3] as int);
      }
    }
    void edge(String a, String b, int seconds, bool estimated) {
      if (a == b ||
          !stops.containsKey(a) ||
          !stops.containsKey(b) ||
          blocked.contains('$a|$b') ||
          seconds <= 0 ||
          seconds > 3600) {
        return;
      }
      final list = _outgoing[a] ??= [];
      if (list.any((e) => e.to == b)) return;
      final e = _Edge(a, b, seconds, estimated);
      list.add(e);
      (_incoming[b] ??= []).add(e);
    }

    for (final p in j['pathways'] ?? []) {
      edge(p[0], p[1], p[3], p[4]);
      if (p[2] == true) edge(p[1], p[0], p[3], p[4]);
    }
    for (final r in j['transfers'] ?? []) {
      if (r[4] == '' && r[5] == '' && (r[2] == 0 || r[2] == 2)) {
        edge(r[0], r[1], max(60, r[3] as int), false);
      }
    }
    // Limited fallback within one PID stop group. Distance-based walks are
    // labelled estimated; no straight-line links across arbitrary city stops.
    final groups = <String, List<String>>{};
    for (final e in stops.entries) {
      final group = e.value[4] as String;
      if (served.contains(e.key) && group.isNotEmpty) {
        (groups[group] ??= []).add(e.key);
      }
    }
    for (final ids in groups.values) {
      if (ids.length > 40) continue;
      for (final a in ids) {
        for (final b in ids) {
          if (a == b) continue;
          final distance = _distance(stops[a]!, stops[b]!);
          if (distance <= 450) {
            edge(a, b, max(120, (distance * 1.4 / 1.1).ceil()), true);
          }
        }
      }
    }
  }

  static double _distance(List a, List b) {
    final lat = ((a[2] as num) + (b[2] as num)) * pi / 360;
    final dy = ((a[2] as num) - (b[2] as num)) * pi / 180;
    final dx = ((a[3] as num) - (b[3] as num)) * pi / 180;
    return 6371000 * sqrt(dy * dy + dx * dx * cos(lat) * cos(lat));
  }

  Set<String> _named(String name) {
    final cached = _names[name];
    if (cached != null) return cached;
    final matches = {
      for (final e in stops.entries)
        if (e.value[0] == name) e.key,
    };
    final city = {
      for (final id in matches)
        if (stops[id]!.length > 6 &&
            (stops[id]![6] as String).split(',').contains('P'))
          id,
    };
    // PID includes regional namesakes. Prague zone P takes precedence when
    // the user selects an unqualified name in this Prague planner.
    return _names[name] = city.isEmpty ? matches : city;
  }

  NetworkJourney? route(
    String from,
    String to,
    DateTime target, {
    bool arriveBy = true,
    LiveFeed? live,
    DateTime? now,
    int maxRides = 6,
    bool cachePrepared = false,
  }) => routeChoices(
    arriveBy ? to : from,
    [arriveBy ? from : to],
    target,
    arriveBy: arriveBy,
    live: live,
    now: now,
    maxRides: maxRides,
    cachePrepared: cachePrepared,
  )[arriveBy ? from : to];

  /// Reverse labels for one destination serve every origin; forward labels
  /// for one origin serve every destination, with the same live snapshot.
  Map<String, NetworkJourney?> routeChoices(
    String fixed,
    List<String> choices,
    DateTime target, {
    bool arriveBy = true,
    LiveFeed? live,
    DateTime? now,
    int maxRides = 6,
    bool cachePrepared = false,
  }) {
    if (choices.isEmpty || choices.length > 12) {
      throw StateError('Endpoint choices exceed their bound.');
    }
    final from = arriveBy ? choices.first : fixed,
        to = arriveBy ? fixed : choices.first;
    final current = now ?? DateTime.now(),
        date = tz.TZDateTime.from(target, prague);
    final key = dayKey(date);
    if (key.compareTo(start) < 0 || key.compareTo(end) > 0) {
      throw StateError(
        'Timetable valid $start — $end. Update it before planning this date.',
      );
    }
    if (from == to || maxRides < 1 || maxRides > 6) {
      throw StateError('Choose different stops.');
    }
    final seeds = <String, _Label>{
      for (final id in _named(fixed))
        id: _Label(target.millisecondsSinceEpoch ~/ 1000, [], 0),
    };
    if (seeds.isEmpty || _named(choices.first).isEmpty) {
      throw StateError('Choose a stop in the PID timetable.');
    }
    final labels = _search(
      seeds,
      target,
      arriveBy: arriveBy,
      live: live,
      current: current,
      maxRides: maxRides,
      cachePrepared: cachePrepared,
    );
    return {
      for (final name in choices)
        name: _journey(_bestLabel(labels, name, arriveBy)),
    };
  }

  NetworkJourney? _journey(_Label? label) =>
      label == null ? null : NetworkJourney(label.legs);

  _Label? _bestLabel(Map<String, _Label> labels, String name, bool arriveBy) {
    _Label? best;
    for (final id in _named(name)) {
      final candidate = labels[id];
      if (candidate != null &&
          candidate.legs.isNotEmpty &&
          (best == null ||
              (arriveBy
                  ? candidate.time > best.time
                  : candidate.time < best.time))) {
        best = candidate;
      }
    }
    return best;
  }

  NetworkEndpointRoute? routeEndpoints(
    List<NetworkEndpoint> origins,
    List<NetworkEndpoint> destinations,
    DateTime target, {
    bool arriveBy = true,
    LiveFeed? live,
    DateTime? now,
    int maxRides = 6,
    bool cachePrepared = false,
  }) {
    final key = dayKey(tz.TZDateTime.from(target, prague));
    if (key.compareTo(start) < 0 || key.compareTo(end) > 0) {
      throw StateError(
        'Timetable valid $start — $end. Update it before planning this date.',
      );
    }
    if (origins.isEmpty ||
        destinations.isEmpty ||
        origins.length > 12 ||
        destinations.length > 12 ||
        maxRides < 1 ||
        maxRides > 6 ||
        [...origins, ...destinations].any(
          (p) =>
              p.walkMinutes < 0 ||
              p.walkMinutes > 180 ||
              p.label.length > 300 ||
              _named(p.stop).isEmpty,
        )) {
      throw StateError('Invalid journey endpoints.');
    }
    if (origins.any((o) => destinations.any((d) => d.stop == o.stop))) {
      throw StateError('Overlapping endpoints require separate searches.');
    }
    final current = now ?? DateTime.now();
    final fixed = arriveBy ? destinations : origins;
    final choices = arriveBy ? origins : destinations;
    final seeds = <String, _Label>{};
    for (var i = 0; i < fixed.length; i++) {
      final time =
          target.millisecondsSinceEpoch ~/ 1000 +
          (arriveBy ? -1 : 1) * fixed[i].walkMinutes * 60;
      for (final id in _named(fixed[i].stop)) {
        final previous = seeds[id];
        if (previous == null ||
            (arriveBy ? time > previous.time : time < previous.time)) {
          seeds[id] = _Label(time, [], i);
        }
      }
    }
    final labels = _search(
      seeds,
      target,
      arriveBy: arriveBy,
      live: live,
      current: current,
      maxRides: maxRides,
      cachePrepared: cachePrepared,
    );
    NetworkEndpointRoute? best;
    for (var i = 0; i < choices.length; i++) {
      final label = _bestLabel(labels, choices[i].stop, arriveBy);
      if (label == null) continue;
      final origin = arriveBy ? i : label.seed,
          destination = arriveBy ? label.seed : i;
      final full = endpointWalks(
        NetworkJourney(label.legs),
        origins[origin],
        destinations[destination],
      );
      if (arriveBy && full.departure.isBefore(current)) continue;
      if (best == null ||
          (arriveBy
              ? full.departure.isAfter(best.journey.departure)
              : full.arrival.isBefore(best.journey.arrival))) {
        best = NetworkEndpointRoute(full, origin, destination);
      }
    }
    return best;
  }

  Map<String, _Label> _search(
    Map<String, _Label> labels,
    DateTime target, {
    required bool arriveBy,
    required LiveFeed? live,
    required DateTime current,
    required int maxRides,
    required bool cachePrepared,
  }) {
    final minimumSeed = labels.values.map((l) => l.time).reduce(min),
        maximumSeed = labels.values.map((l) => l.time).reduce(max);
    bool better(int value, int previous) =>
        arriveBy ? value > previous : value < previous;
    void walks(Map<String, _Label> labels) {
      final queue = labels.keys.toList();
      var changes = 0;
      for (var cursor = 0; cursor < queue.length; cursor++) {
        if (++changes > 100000) {
          throw StateError('Transfer search exceeds its bound.');
        }
        final id = queue[cursor], tail = labels[id]!;
        for (final edge
            in (arriveBy ? _incoming[id] : _outgoing[id]) ?? <_Edge>[]) {
          final next = arriveBy ? edge.from : edge.to;
          final value = tail.time + (arriveBy ? -edge.seconds : edge.seconds);
          if (!labels.containsKey(next) || better(value, labels[next]!.time)) {
            final leg = JourneyLeg(
              stops[edge.from]![0],
              stops[edge.to]![0],
              '',
              '',
              '',
              -1,
              DateTime.fromMillisecondsSinceEpoch(
                (arriveBy ? value : tail.time) * 1000,
                isUtc: true,
              ),
              DateTime.fromMillisecondsSinceEpoch(
                (arriveBy ? tail.time : value) * 1000,
                isUtc: true,
              ),
              estimated: edge.estimated,
            );
            labels[next] = _Label(
              value,
              arriveBy ? [leg, ...tail.legs] : [...tail.legs, leg],
              tail.seed,
            );
            queue.add(next);
          }
        }
      }
    }

    walks(labels);
    // Only the private worker opts in. Its timetable is immutable; live inputs
    // are always rebuilt so predictions and expiry cannot be reused incorrectly.
    final preparedKey =
        '$minimumSeed:$maximumSeed:$arriveBy:${current.millisecondsSinceEpoch}';
    final reuse = cachePrepared && live == null && _preparedKey == preparedKey;
    final prepared = reuse ? _preparedCache! : <(List, List<List<dynamic>>)>[];
    if (!reuse) {
      final first = DateTime.parse(start);
      // Previous service days cover legitimate GTFS times beyond 24:00.
      final earliest = tz.TZDateTime.from(
            DateTime.fromMillisecondsSinceEpoch(
              minimumSeed * 1000,
              isUtc: true,
            ),
            prague,
          ),
          latest = tz.TZDateTime.from(
            DateTime.fromMillisecondsSinceEpoch(
              maximumSeed * 1000,
              isUtc: true,
            ),
            prague,
          );
      final firstDay = DateTime.utc(
            earliest.year,
            earliest.month,
            earliest.day - 2,
          ),
          lastDay = DateTime.utc(
            latest.year,
            latest.month,
            latest.day + (arriveBy ? 0 : 1),
          );
      for (
        var d = firstDay;
        !d.isAfter(lastDay);
        d = d.add(const Duration(days: 1))
      ) {
        final day = dayKey(d), index = d.difference(first).inDays;
        if (index < 0 || index > 31 || day.compareTo(end) > 0) continue;
        final base =
            tz.TZDateTime(prague, d.year, d.month, d.day, 12)
                .toUtc()
                .subtract(const Duration(hours: 12))
                .millisecondsSinceEpoch ~/
            1000;
        for (final raw in trips) {
          final t = raw as List;
          if ((t[3] & (1 << index)) == 0) continue;
          final rawTimes = t[4] as List;
          if (rawTimes.isEmpty) continue;
          final low = base + (rawTimes.first[2] as int),
              high = base + (rawTimes.last[3] as int);
          if (arriveBy
              ? high < minimumSeed - 8 * 3600 || low > maximumSeed + 3600
              : high < minimumSeed - 3600 || low > maximumSeed + 8 * 3600) {
            continue;
          }
          TripPrediction? prediction;
          if (live?.fresh(current) == true) {
            prediction = live!.trips['${t[0]}|${day.replaceAll('-', '')}'];
            if (prediction == null && day == dayKey(localNow())) {
              prediction = live.trips['${t[0]}|'];
            }
            final stamp = prediction?.timestamp;
            if (stamp != null &&
                (current.millisecondsSinceEpoch ~/ 1000 - stamp).abs() > 180) {
              prediction = null;
            }
          }
          if (prediction?.cancelled == true) continue;
          var delay = prediction?.delay;
          final times = <List<dynamic>>[];
          var valid = true, last = -1;
          for (final raw in rawTimes) {
            final s = raw as List, p = prediction?.at(s[1], s[0]);
            if (p?.relationship == 2) delay = null;
            final scheduledArrival = base + (s[2] as int),
                scheduledDeparture = base + (s[3] as int);
            if (p?.arrivalTime != null) {
              delay = p!.arrivalTime! - scheduledArrival;
            } else if (p?.arrivalDelay != null) {
              delay = p!.arrivalDelay;
            }
            final a = scheduledArrival + (delay ?? 0),
                arrivalKnown = delay != null;
            if (p?.departureTime != null) {
              delay = p!.departureTime! - scheduledDeparture;
            } else if (p?.departureDelay != null) {
              delay = p!.departureDelay;
            }
            final dep = scheduledDeparture + (delay ?? 0);
            if (a < last || dep < a) valid = false;
            last = dep;
            times.add([
              s[0],
              a,
              dep,
              (s[4] == 0 || s[4] == 3) && p?.relationship != 1,
              (s[5] == 0 || s[5] == 3) && p?.relationship != 1,
              arrivalKnown,
              delay != null,
              s[4] == 3 || s[5] == 3,
            ]);
          }
          if (valid) prepared.add((t, times));
        }
      }
      if (cachePrepared && live == null) {
        _preparedKey = preparedKey;
        _preparedCache = prepared;
      }
    }
    for (var round = 0; round < maxRides; round++) {
      final old = Map<String, _Label>.from(labels);
      var improved = false;
      for (final (trip, times) in prepared) {
        int? point;
        _Label? tail;
        for (
          var i = arriveBy ? times.length - 1 : 0;
          arriveBy ? i >= 0 : i < times.length;
          i += arriveBy ? -1 : 1
        ) {
          final s = times[i], id = s[0] as String;
          if (point != null &&
              tail != null &&
              (arriveBy ? s[3] : s[4]) == true) {
            final value = s[arriveBy ? 2 : 1] as int;
            if ((!arriveBy ||
                    value >= current.millisecondsSinceEpoch ~/ 1000) &&
                (!labels.containsKey(id) || better(value, labels[id]!.time))) {
              final a = arriveBy ? i : point, b = arriveBy ? point : i;
              final leg = JourneyLeg(
                stops[times[a][0]]![0],
                stops[times[b][0]]![0],
                trip[1],
                trip[2],
                trip[0],
                trip[5],
                DateTime.fromMillisecondsSinceEpoch(
                  times[a][2] * 1000,
                  isUtc: true,
                ),
                DateTime.fromMillisecondsSinceEpoch(
                  times[b][1] * 1000,
                  isUtc: true,
                ),
                predicted: times[a][6] && times[b][5],
                requestStop: times[a][7] || times[b][7],
              );
              labels[id] = _Label(
                value,
                arriveBy ? [leg, ...tail.legs] : [...tail.legs, leg],
                tail.seed,
              );
              improved = true;
            }
          }
          final previous = old[id];
          if (previous != null && (arriveBy ? s[4] : s[3]) == true) {
            final boundary =
                previous.legs.isNotEmpty &&
                    (arriveBy ? previous.legs.first : previous.legs.last)
                            .mode >=
                        0
                ? (change[id] ?? 60)
                : 0;
            final possible = arriveBy
                ? (s[1] as int) <= previous.time - boundary
                : (s[2] as int) >= previous.time + boundary;
            if (possible && point == null) {
              point = i;
              tail = previous;
            }
          }
        }
      }
      if (!improved) break;
      walks(labels);
    }
    return labels;
  }
}

// The full graph stays in one worker isolate; each query transfers only its
// endpoints and the common live feed, rather than copying the graph to the UI.
class NetworkEngine {
  List<List<dynamic>> coordinates = [];
  Map<String, List<int>> stationModes = {};
  List<(String, double)> nearby(
    double latitude,
    double longitude, {
    int limit = 10,
  }) {
    final best = <String, double>{};
    for (final s in coordinates) {
      final lat = (s[1] as num).toDouble(), lng = (s[2] as num).toDouble();
      final a =
          pow(sin((latitude - lat) * pi / 360), 2) +
          cos(latitude * pi / 180) *
              cos(lat * pi / 180) *
              pow(sin((longitude - lng) * pi / 360), 2);
      final distance = 6371000 * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)));
      final name = s[0] as String;
      if (distance < (best[name] ?? double.infinity)) best[name] = distance;
    }
    final ordered = best.entries.where((e) => e.value < 5000).toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return ordered
        .take(limit.clamp(1, 40))
        .map((e) => (e.key, e.value))
        .toList();
  }

  Isolate? _isolate;
  SendPort? _port;
  ReceivePort? _receive;
  final _pending = <int, Completer<dynamic>>{};
  int _id = 0;
  List<String> stations = [];
  String? start, end;
  Future<void>? _loading;
  Completer<void>? _ready;
  bool _disposed = false;
  Future<void> load(String? cachePath) {
    if (_disposed) return Future.error(StateError('Planner closed.'));
    return _loading ??= _load(cachePath);
  }

  Future<void> _load(String? cachePath) async {
    final Uint8List bytes;
    if (cachePath != null && await File(cachePath).exists()) {
      final file = File(cachePath);
      if (await file.length() > 80 * 1024 * 1024) {
        throw const FormatException('Network cache exceeds its bound.');
      }
      bytes = await file.readAsBytes();
    } else {
      final asset = await rootBundle.load('assets/network.json.gz');
      bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
    }
    if (_disposed) throw StateError('Planner closed.');
    _receive = ReceivePort();
    final ready = Completer<void>();
    _ready = ready;
    // Dispose can occur while Isolate.spawn is still awaiting its result.
    // Keep the startup error handled until _load reaches its await below.
    ready.future.ignore();
    _receive!.listen((dynamic message) {
      if (message is SendPort) {
        _port = message;
        return;
      }
      final m = message as Map;
      if (m['ready'] == true) {
        stations = List<String>.from(m['stations']);
        stationModes = {
          for (final e in (m['modes'] as Map).entries)
            e.key as String: List<int>.from(e.value),
        };
        coordinates = [
          for (final s in m['coordinates'] as List) List<dynamic>.from(s),
        ];
        start = m['start'];
        end = m['end'];
        if (!ready.isCompleted) ready.complete();
      } else if (m['startupError'] != null) {
        if (!ready.isCompleted) {
          ready.completeError(StateError(m['startupError']));
        }
      } else {
        final c = _pending.remove(m['id']);
        if (m['error'] != null) {
          c?.completeError(StateError(m['error']));
        } else {
          c?.complete(m['legs']);
        }
      }
    });
    _isolate = await Isolate.spawn(_routingWorker, [_receive!.sendPort, bytes]);
    if (_disposed) {
      _isolate?.kill(priority: Isolate.immediate);
      throw StateError('Planner closed.');
    }
    await ready.future;
  }

  Future<NetworkJourney?> route(
    String from,
    String to,
    DateTime target, {
    bool arriveBy = true,
    LiveFeed? live,
    DateTime? now,
  }) async {
    if (_port == null || stations.isEmpty) {
      throw StateError('Network timetable is still loading.');
    }
    final id = _id++, c = Completer<dynamic>();
    _pending[id] = c;
    _port!.send({
      'id': id,
      'from': from,
      'to': to,
      'target': target.millisecondsSinceEpoch,
      'arriveBy': arriveBy,
      'live': live,
      'now': now?.millisecondsSinceEpoch,
    });
    final legs = await c.future;
    return legs == null
        ? null
        : NetworkJourney([
            for (final l in legs)
              JourneyLeg.fromJson(Map<String, dynamic>.from(l)),
          ]);
  }

  Future<Map<String, NetworkJourney?>> routeChoices(
    String fixed,
    List<String> choices,
    DateTime target, {
    bool arriveBy = true,
    LiveFeed? live,
    DateTime? now,
  }) async {
    if (_port == null || stations.isEmpty) {
      throw StateError('Network timetable is still loading.');
    }
    if (choices.isEmpty || choices.length > 12) {
      throw StateError('Endpoint choices exceed their bound.');
    }
    final id = _id++, c = Completer<dynamic>();
    _pending[id] = c;
    _port!.send({
      'id': id,
      'fixed': fixed,
      'choices': choices,
      'target': target.millisecondsSinceEpoch,
      'arriveBy': arriveBy,
      'live': live,
      'now': now?.millisecondsSinceEpoch,
    });
    final results = await c.future as Map;
    return {
      for (final e in results.entries)
        e.key as String: e.value == null
            ? null
            : NetworkJourney([
                for (final l in e.value as List)
                  JourneyLeg.fromJson(Map<String, dynamic>.from(l)),
              ]),
    };
  }

  Future<NetworkEndpointRoute?> routeEndpoints(
    List<NetworkEndpoint> origins,
    List<NetworkEndpoint> destinations,
    DateTime target, {
    bool arriveBy = true,
    LiveFeed? live,
    DateTime? now,
  }) async {
    if (_port == null || stations.isEmpty) {
      throw StateError('Network timetable is still loading.');
    }
    if (origins.isEmpty ||
        destinations.isEmpty ||
        origins.length > 12 ||
        destinations.length > 12) {
      throw StateError('Endpoint choices exceed their bound.');
    }
    final id = _id++, c = Completer<dynamic>();
    _pending[id] = c;
    _port!.send({
      'id': id,
      'origins': [
        for (final p in origins) [p.stop, p.label, p.walkMinutes],
      ],
      'destinations': [
        for (final p in destinations) [p.stop, p.label, p.walkMinutes],
      ],
      'target': target.millisecondsSinceEpoch,
      'arriveBy': arriveBy,
      'live': live,
      'now': now?.millisecondsSinceEpoch,
    });
    final result = await c.future as Map?;
    return result == null
        ? null
        : NetworkEndpointRoute(
            NetworkJourney([
              for (final l in result['legs'])
                JourneyLeg.fromJson(Map<String, dynamic>.from(l)),
            ]),
            result['origin'] as int,
            result['destination'] as int,
          );
  }

  void dispose() {
    _disposed = true;
    if (_ready != null && !_ready!.isCompleted) {
      _ready!.completeError(StateError('Planner closed.'));
    }
    _isolate?.kill(priority: Isolate.immediate);
    _receive?.close();
    for (final c in _pending.values) {
      c.completeError(StateError('Planner closed.'));
    }
    _pending.clear();
  }
}

void _routingWorker(List<dynamic> initial) {
  final out = initial[0] as SendPort;
  final port = ReceivePort();
  out.send(port.sendPort);
  try {
    tzdata.initializeTimeZones();
    final index = NetworkIndex(
      jsonDecode(utf8.decode(gzip.decode(initial[1] as Uint8List))),
    );
    final stationNames = index.stations.toSet();
    final modes = <String, Set<int>>{};
    for (final trip in index.trips) {
      for (final time in trip[4] as List) {
        final name = index.stops[time[0]]![0] as String;
        (modes[name] ??= {}).add(trip[5] as int);
      }
    }
    out.send({
      'ready': true,
      'stations': index.stations,
      'modes': {for (final e in modes.entries) e.key: e.value.toList()},
      'coordinates': [
        for (final s in index.stops.values)
          if (stationNames.contains(s[0]) &&
              s[2] is num &&
              s[3] is num &&
              (s[2] as num) != 0)
            [s[0], s[2], s[3]],
      ],
      'start': index.start,
      'end': index.end,
    });
    port.listen((dynamic request) {
      final r = request as Map;
      try {
        if (r['origins'] != null) {
          final result = index.routeEndpoints(
            [for (final p in r['origins']) NetworkEndpoint(p[0], p[1], p[2])],
            [
              for (final p in r['destinations'])
                NetworkEndpoint(p[0], p[1], p[2]),
            ],
            DateTime.fromMillisecondsSinceEpoch(r['target'], isUtc: true),
            arriveBy: r['arriveBy'],
            live: r['live'],
            cachePrepared: true,
            now: r['now'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(r['now'], isUtc: true),
          );
          out.send({
            'id': r['id'],
            'legs': result == null
                ? null
                : {
                    'legs': result.journey.legs.map((l) => l.toJson()).toList(),
                    'origin': result.origin,
                    'destination': result.destination,
                  },
          });
          return;
        }
        if (r['choices'] != null) {
          final results = index.routeChoices(
            r['fixed'],
            List<String>.from(r['choices']),
            DateTime.fromMillisecondsSinceEpoch(r['target'], isUtc: true),
            arriveBy: r['arriveBy'],
            live: r['live'],
            cachePrepared: true,
            now: r['now'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(r['now'], isUtc: true),
          );
          out.send({
            'id': r['id'],
            'legs': {
              for (final e in results.entries)
                e.key: e.value?.legs.map((l) => l.toJson()).toList(),
            },
          });
          return;
        }
        final journey = index.route(
          r['from'],
          r['to'],
          DateTime.fromMillisecondsSinceEpoch(r['target'], isUtc: true),
          arriveBy: r['arriveBy'],
          live: r['live'],
          cachePrepared: true,
          now: r['now'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(r['now'], isUtc: true),
        );
        out.send({
          'id': r['id'],
          'legs': journey?.legs.map((l) => l.toJson()).toList(),
        });
      } catch (e) {
        out.send({'id': r['id'], 'error': e.toString()});
      }
    });
  } catch (e) {
    out.send({'startupError': e.toString()});
    port.close();
  }
}
