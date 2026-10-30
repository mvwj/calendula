import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'private_network.dart';
import 'desktop_tor.dart';

// Read only the official GTFS-RT fields needed here, with strict wire bounds.
class _Proto {
  final Uint8List data;
  int pos = 0;
  _Proto(this.data);
  int varint() {
    var result = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      if (pos >= data.length) {
        throw const FormatException('Truncated protobuf');
      }
      final b = data[pos++];
      if (shift == 63 && b > 1) {
        throw const FormatException('Oversized varint');
      }
      result |= (b & 127) << shift;
      if (b < 128) {
        return result;
      }
    }
    throw const FormatException('Invalid varint');
  }

  Map<int, List<Object>> fields() {
    final values = <int, List<Object>>{};
    while (pos < data.length) {
      final tag = varint(), field = tag >> 3, wire = tag & 7;
      if (field <= 0) {
        throw const FormatException('Invalid protobuf tag');
      }
      Object? value;
      switch (wire) {
        case 0:
          value = varint();
        case 1:
          pos += 8;
        case 2:
          final size = varint();
          if (size < 0 || size > data.length - pos) {
            throw const FormatException('Invalid protobuf length');
          }
          value = Uint8List.sublistView(data, pos, pos + size);
          pos += size;
        case 5:
          pos += 4;
        default:
          throw const FormatException('Unsupported protobuf wire type');
      }
      if (pos > data.length) {
        throw const FormatException('Truncated fixed field');
      }
      if (value != null) {
        (values[field] ??= []).add(value);
      }
    }
    return values;
  }
}

typedef _Fields = Map<int, List<Object>>;
int? _int(_Fields f, int key) => f[key]?.last as int?;
String? _string(_Fields f, int key) =>
    f[key] == null ? null : utf8.decode(f[key]!.last as Uint8List);
_Fields? _message(_Fields f, int key) =>
    f[key] == null ? null : _Proto(f[key]!.last as Uint8List).fields();

class StopPrediction {
  final int? sequence, arrivalDelay, departureDelay, arrivalTime, departureTime;
  final String? stopId;
  final int relationship;
  const StopPrediction({
    this.sequence,
    this.stopId,
    this.arrivalDelay,
    this.departureDelay,
    this.arrivalTime,
    this.departureTime,
    this.relationship = 0,
  });
}

class TripPrediction {
  final String id;
  final String? serviceDate;
  final int relationship;
  final int? timestamp, delay;
  final List<StopPrediction> stops;
  const TripPrediction({
    required this.id,
    this.serviceDate,
    this.relationship = 0,
    this.timestamp,
    this.delay,
    this.stops = const [],
  });
  bool get cancelled => relationship == 3 || relationship == 7;
  StopPrediction? at(int sequence, String stopId) {
    for (final s in stops) {
      if (s.sequence == sequence ||
          (s.sequence == null && s.stopId == stopId)) {
        return s;
      }
    }
    return null;
  }
}

class LiveFeed {
  static final endpoint = Uri.parse(
    'https://api.golemio.cz/v2/vehiclepositions/gtfsrt/trip_updates.pb',
  );
  final DateTime generated;
  final Map<String, TripPrediction> trips;
  const LiveFeed(this.generated, this.trips);
  bool fresh(DateTime now) =>
      now.difference(generated).inSeconds >= -30 &&
      now.difference(generated).inSeconds <= 180;
  int get delayed => trips.values
      .where(
        (t) =>
            (t.delay ?? 0) > 0 ||
            t.stops.any(
              (s) => (s.arrivalDelay ?? 0) > 0 || (s.departureDelay ?? 0) > 0,
            ),
      )
      .length;
  factory LiveFeed.decode(Uint8List bytes) {
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Transit feed exceeds size limit');
    }
    final feed = _Proto(bytes).fields(),
        header = _message(_Proto(bytes).fields(), 1);
    if (header == null ||
        _int(header, 3) == null ||
        (_int(header, 2) ?? 0) != 0) {
      throw const FormatException(
        'Only timestamped full transit feeds are supported',
      );
    }
    final version = _string(header, 1);
    if (version != '2.0' && version != '1.0') {
      throw const FormatException('Unsupported transit feed version');
    }
    final trips = <String, TripPrediction>{};
    for (final bytes in feed[2] ?? []) {
      final entity = _Proto(bytes as Uint8List).fields();
      if (_int(entity, 2) == 1) {
        continue;
      }
      final update = _message(entity, 3);
      if (update == null) {
        continue;
      }
      final descriptor = _message(update, 1);
      if (descriptor == null) {
        continue;
      }
      final id = _string(descriptor, 1);
      if (id == null || id.isEmpty) {
        continue;
      }
      final stops = <StopPrediction>[];
      for (final bytes in update[2] ?? []) {
        final s = _Proto(bytes as Uint8List).fields(),
            a = _message(_Proto(bytes).fields(), 2),
            d = _message(_Proto(bytes).fields(), 3);
        stops.add(
          StopPrediction(
            sequence: _int(s, 1),
            stopId: _string(s, 4),
            relationship: _int(s, 5) ?? 0,
            arrivalDelay: a == null ? null : _int(a, 1)?.toSigned(32),
            departureDelay: d == null ? null : _int(d, 1)?.toSigned(32),
            arrivalTime: a == null ? null : _int(a, 2),
            departureTime: d == null ? null : _int(d, 2),
          ),
        );
      }
      final prediction = TripPrediction(
        id: id,
        serviceDate: _string(descriptor, 3),
        relationship: _int(descriptor, 4) ?? 0,
        timestamp: _int(update, 4),
        delay: _int(update, 5)?.toSigned(32),
        stops: stops,
      );
      trips['$id|${prediction.serviceDate ?? ''}'] = prediction;
    }
    return LiveFeed(
      DateTime.fromMillisecondsSinceEpoch(_int(header, 3)! * 1000, isUtc: true),
      trips,
    );
  }
  static Future<LiveFeed> download() async {
    if (Platform.isWindows) {
      return LiveFeed.decode(
        Uint8List.fromList(await DesktopTor.instance.live()),
      );
    }
    if (Platform.isAndroid) {
      final bytes = await privateTransitChannel.invokeMethod<Uint8List>('live');
      if (bytes == null) {
        throw const FormatException('Private live download failed.');
      }
      return LiveFeed.decode(bytes);
    }
    throw const FormatException(
      'Private transport is not connected on this platform yet. Cached timetables remain available.',
    );
  }
}

class MetroJourney {
  final String tripId, line, headsign, origin, destination;
  final DateTime departure, arrival;
  final bool updated;
  const MetroJourney({
    required this.tripId,
    required this.line,
    required this.headsign,
    required this.origin,
    required this.destination,
    required this.departure,
    required this.arrival,
    this.updated = false,
  });
}

class MetroIndex {
  final String start, end;
  final Map<String, String> stops;
  final List<dynamic> trips;
  MetroIndex(this.start, this.end, this.stops, this.trips);
  factory MetroIndex.fromJson(Map<String, dynamic> j) {
    final index = MetroIndex(
      j['start'],
      j['end'],
      Map<String, String>.from(j['stops']),
      j['trips'],
    );
    final first = DateTime.parse(index.start), last = DateTime.parse(index.end);
    if (index.stops.length < 2 ||
        index.trips.isEmpty ||
        index.trips.length > 100000 ||
        last.difference(first).inDays < 0 ||
        last.difference(first).inDays > 31) {
      throw const FormatException('Invalid metro index.');
    }
    for (final raw in index.trips) {
      final t = raw as List;
      if (t.length != 5 ||
          t[0] is! String ||
          t[1] is! String ||
          t[2] is! String ||
          t[3] is! int ||
          t[3] < 0 ||
          t[4] is! List) {
        throw const FormatException('Invalid metro trip.');
      }
      var seq = -1;
      for (final rawStop in t[4]) {
        final s = rawStop as List;
        if (s.length != 6 ||
            !index.stops.containsKey(s[0]) ||
            s.skip(1).any((v) => v is! int || v < 0) ||
            s[1] <= seq ||
            s[3] < s[2] ||
            s[4] > 3 ||
            s[5] > 3) {
          throw const FormatException('Invalid metro stop time.');
        }
        seq = s[1];
      }
    }
    return index;
  }
  List<String> get stations => stops.values.toSet().toList()..sort();
  static Future<MetroIndex> load() async {
    final bytes = await rootBundle.load('assets/metro.json.gz');
    final j = jsonDecode(
      utf8.decode(
        gzip.decode(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      ),
    ) as Map<String, dynamic>;
    return MetroIndex.fromJson(j);
  }

  MetroJourney? arriveBy(
    String origin,
    String destination,
    DateTime target, {
    LiveFeed? live,
    DateTime? now,
  }) {
    final day = dayKey(target);
    if (day.compareTo(start) < 0 || day.compareTo(end) > 0) {
      throw StateError(
        'Timetable valid $start — $end. A new timetable is required.',
      );
    }
    if (origin == destination) {
      throw StateError('Choose two different stations');
    }
    final startDay = DateTime.parse(start);
    final date = DateTime.utc(target.year, target.month, target.day);
    final bit = 1 << date.difference(startDay).inDays;
    final current = now ?? DateTime.now();
    final stamp = day.replaceAll('-', '');
    final useLive =
        live != null &&
        live.fresh(current) &&
        day == dayKey(tz.TZDateTime.from(current, prague));
    MetroJourney? best;
    DateTime at(int seconds) {
      // GTFS time is measured from local noon minus 12 hours, including DST days.
      final base = tz.TZDateTime(
        prague,
        target.year,
        target.month,
        target.day,
        12,
      ).subtract(const Duration(hours: 12));
      return base.add(Duration(seconds: seconds));
    }

    for (final raw in trips) {
      final t = raw as List;
      if (((t[3] as int) & bit) == 0) {
        continue;
      }
      final p = useLive
          ? (live.trips['${t[0]}|$stamp'] ?? live.trips['${t[0]}|'])
          : null;
      if (p?.cancelled == true) {
        continue;
      }
      if (p?.timestamp != null &&
          current
                  .difference(
                    DateTime.fromMillisecondsSinceEpoch(
                      p!.timestamp! * 1000,
                      isUtc: true,
                    ),
                  )
                  .inSeconds >
              180) {
        continue;
      }
      List? from;
      for (final rawStop in t[4] as List) {
        final s = rawStop as List;
        if (stops[s[0]] == destination && s[5] == 0 && from != null) {
          final dp = p?.at(from[1], from[0]), ap = p?.at(s[1], s[0]);
          if (dp?.relationship == 1 || ap?.relationship == 1) {
            continue;
          }
          DateTime departure = at(from[3]), arrival = at(s[2]);
          var updated = false;
          // Partial / NO_DATA predictions are not assumed to mean on time.
          if (dp != null &&
              ap != null &&
              dp.relationship == 0 &&
              ap.relationship == 0 &&
              (dp.departureTime != null || dp.departureDelay != null) &&
              (ap.arrivalTime != null || ap.arrivalDelay != null)) {
            departure = dp.departureTime != null
                ? DateTime.fromMillisecondsSinceEpoch(
                    dp.departureTime! * 1000,
                    isUtc: true,
                  )
                : departure.add(Duration(seconds: dp.departureDelay!));
            arrival = ap.arrivalTime != null
                ? DateTime.fromMillisecondsSinceEpoch(
                    ap.arrivalTime! * 1000,
                    isUtc: true,
                  )
                : arrival.add(Duration(seconds: ap.arrivalDelay!));
            updated = true;
          }
          if (!arrival.isAfter(target) &&
              arrival.isAfter(departure) &&
              (!useLive || departure.isAfter(current)) &&
              (best == null || departure.isAfter(best.departure))) {
            best = MetroJourney(
              tripId: t[0],
              line: t[1],
              headsign: t[2],
              origin: origin,
              destination: destination,
              departure: tz.TZDateTime.from(departure, prague),
              arrival: tz.TZDateTime.from(arrival, prague),
              updated: updated,
            );
          }
        }
        if (stops[s[0]] == origin && s[4] == 0) {
          from = s;
        }
      }
    }
    return best;
  }
}
