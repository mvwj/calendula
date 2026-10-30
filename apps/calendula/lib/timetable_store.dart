import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'calendar.dart';
import 'network_router.dart';
import 'refresh_policy.dart';
import 'transit.dart';
import 'private_network.dart';

const networkChannel = MethodChannel('app.calendula/network');

class TimetableStore {
  static final endpoint = Uri.parse('https://data.pid.cz/PID_GTFS.zip');
  final Future<Directory> Function() directory;
  final http.Client Function() client;
  final bool injectedClient;
  TimetableStore({
    Future<Directory> Function()? directory,
    http.Client Function()? client,
  }) : injectedClient = client != null,
       directory = directory ?? getApplicationSupportDirectory,
       client = client ?? http.Client.new;
  Future<Map<String, dynamic>> metadata() async {
    final f = File('${(await directory()).path}/public-timetable.meta.json');
    try {
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return {};
    }
  }

  Future<MetroIndex> load() async {
    try {
      final f = File('${(await directory()).path}/public-metro.json');
      if (await f.exists() && await f.length() < 25 * 1024 * 1024) {
        return MetroIndex.fromJson(jsonDecode(await f.readAsString()));
      }
    } catch (_) {
      /* Public cache can fall back to the bundled valid index. */
    }
    return MetroIndex.load();
  }

  Future<bool> due(DateTime now, MetroIndex current) async {
    final meta = await metadata();
    final retry = DateTime.tryParse(meta['retryAt'] ?? '');
    if (retry != null && now.isBefore(retry)) {
      return false;
    }
    final checked = DateTime.tryParse(meta['checked'] ?? '');
    if (!await File('${(await directory()).path}/public-network.json.gz')
        .exists()) {
      return true;
    }
    // The bundled index was built on its first date; no repeat 48 MB download
    // on the same day. Later dates check at most once per local calendar day.
    return dayKey(now) != (checked == null ? current.start : dayKey(checked));
  }

  Future<bool> unmetered() async {
    if (!Platform.isAndroid) {
      return true;
    }
    try {
      return await networkChannel.invokeMethod<bool>('metered') == false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<MetroIndex> update(DateTime now, MetroIndex previous) async {
    final root = await directory(), meta = await metadata();
    final attempted = DateTime.tryParse(meta['attempt'] ?? ''),
        retry = DateTime.tryParse(meta['retryAt'] ?? '');
    if (retry?.isAfter(now) == true ||
        (attempted != null && now.difference(attempted).inMinutes < 60)) {
      throw const FormatException(
        'Timetable refresh is paused. The previous timetable remains available.',
      );
    }
    meta['attempt'] = now.toIso8601String();
    await _meta(root, meta);
    final network = client();
    final job = DateTime.now().microsecondsSinceEpoch;
    final zip = File('${root.path}/public-pid.download.$job');
    final work = await Directory('${root.path}/public-pid-work-$job').create();
    IOSink? sink;
    int? indexLease;
    var received = false;
    try {
      final request = http.Request('GET', endpoint)..followRedirects = false;
      if (meta['etag'] is String) {
        request.headers['If-None-Match'] = meta['etag'];
      }
      if (meta['modified'] is String) {
        request.headers['If-Modified-Since'] = meta['modified'];
      }
      final http.StreamedResponse response;
      if ((Platform.isAndroid || Platform.isWindows) && !injectedClient) {
        response = await PrivateNetwork.timetableResponse(
          headers: request.headers,
        );
      } else if (injectedClient) {
        response = await network
            .send(request)
            .timeout(const Duration(seconds: 30));
      } else {
        throw const FormatException(
          'Private transport is not connected on this platform yet.',
        );
      }
      if (response.statusCode == 304) {
        if (dayKey(now).compareTo(previous.end) > 0) {
          throw const FormatException(
            'The provider has not published a current timetable.',
          );
        }
        await _meta(root, {...meta, 'checked': dayKey(now), 'retryAt': null});
        return previous;
      }
      if (response.statusCode != 200) {
        throw TransitRequestError(
          response.statusCode,
          retryAfter: parseRetryAfter(response.headers['retry-after'], now),
        );
      }
      received = true;
      const maximum = 150 * 1024 * 1024;
      if ((response.contentLength ?? 0) > maximum) {
        throw const FormatException('PID download exceeds the size limit.');
      }
      sink = zip.openWrite();
      var count = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        count += chunk.length;
        if (count > maximum) {
          throw const FormatException('PID download exceeds the size limit.');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (Platform.isAndroid) {
        indexLease = await const MethodChannel('app.calendula/public-index')
            .invokeMethod<int>('acquire')
            .timeout(const Duration(seconds: 20));
      }
      final data = await compute(buildMetroIndexTask, [
        zip.path,
        work.path,
        '${root.path}/public-network.json.gz',
        dayKey(now),
      ]);
      final next = MetroIndex.fromJson(data);
      if (dayKey(now).compareTo(next.start) < 0 ||
          dayKey(now).compareTo(next.end) > 0) {
        throw const FormatException(
          'The downloaded timetable does not cover today.',
        );
      }
      final cache = File('${root.path}/public-metro.json'),
          pending = File('${root.path}/public-metro.pending');
      await pending.writeAsString(jsonEncode(data), flush: true);
      final old = File('${root.path}/public-metro.previous');
      if (await old.exists()) {
        await old.delete();
      }
      if (await cache.exists()) {
        await cache.rename(old.path);
      }
      await pending.rename(cache.path);
      await _meta(root, {
        'attempt': now.toIso8601String(),
        'checked': dayKey(now),
        'etag': response.headers['etag'],
        'modified': response.headers['last-modified'],
        'retryAt': null,
      });
      return next;
    } catch (error) {
      if (received &&
          error is FormatException &&
          Platform.isAndroid &&
          !injectedClient) {
        try {
          await privateTransitChannel.invokeMethod<void>('invalidateTimetable');
        } catch (_) {
          /* Preserve the prior validated Dart cache. */
        }
      }
      var delay =
          error is TransitRequestError &&
              (error.status == 401 || error.status == 403)
          ? const Duration(hours: 24)
          : const Duration(hours: 1);
      if (error is TransitRequestError &&
          error.retryAfter != null &&
          error.retryAfter! > delay) {
        delay = error.retryAfter!;
      }
      await _meta(root, {...meta, 'retryAt': now.add(delay).toIso8601String()});
      rethrow;
    } finally {
      if (indexLease != null) {
        await const MethodChannel('app.calendula/public-index')
            .invokeMethod('release', indexLease);
      }
      if (sink != null) {
        await sink.close();
      }
      network.close();
      if (await zip.exists()) {
        await zip.delete();
      }
      // Delete only explicitly named public working files, never archive paths.
      for (final name in _tables) {
        final f = File('${work.path}/$name');
        if (await f.exists()) {
          await f.delete();
        }
      }
      if (await work.exists() && await work.list().isEmpty) {
        await work.delete();
      }
    }
  }

  Future<void> _meta(Directory dir, Map<String, dynamic> value) =>
      File('${dir.path}/public-timetable.meta.json')
          .writeAsString(jsonEncode(value), flush: true)
          .then((_) {});
}

/// Reads an already downloaded, native-owned public ZIP. No network client.
class CachedTimetableClient extends http.BaseClient {
  final File file;
  CachedTimetableClient(this.file);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method != 'GET' ||
        request.url != TimetableStore.endpoint ||
        !await file.exists() ||
        await file.length() > 150 * 1024 * 1024) {
      throw const FormatException('Cached public timetable is unavailable.');
    }
    return http.StreamedResponse(
      file.openRead(),
      200,
      contentLength: await file.length(),
    );
  }
}

const _tables = [
  'feed_info.txt',
  'stops.txt',
  'routes.txt',
  'trips.txt',
  'calendar.txt',
  'calendar_dates.txt',
  'stop_times.txt',
  'transfers.txt',
  'pathways.txt',
];
Map<String, dynamic> buildMetroIndexTask(List<String> paths) {
  final result = buildMetroIndex(paths[0], paths[1]);
  final network = result.remove('network') as Map<String, dynamic>;
  final validated = NetworkIndex(network);
  if (paths.length > 3 &&
      (paths[3].compareTo(validated.start) < 0 ||
          paths[3].compareTo(validated.end) > 0)) {
    throw const FormatException(
      'The downloaded timetable does not cover today.',
    );
  }
  if (paths.length > 2) {
    final cache = File(paths[2]), pending = File('${paths[2]}.pending');
    pending.writeAsBytesSync(
      gzip.encode(utf8.encode(jsonEncode(network))),
      flush: true,
    );
    final old = File('${paths[2]}.previous');
    if (old.existsSync()) old.deleteSync();
    if (cache.existsSync()) cache.renameSync(old.path);
    pending.renameSync(cache.path);
  }
  return result;
}

Map<String, dynamic> buildMetroIndex(String zipPath, String workPath) {
  final input = InputFileStream(zipPath);
  try {
    final zip = ZipDecoder().decodeStream(input);
    if (zip.fold<int>(0, (n, e) => n + e.size) > 1024 * 1024 * 1024) {
      throw const FormatException('GTFS archive is too large.');
    }
    for (final name in _tables) {
      final old = File('$workPath/$name');
      if (old.existsSync()) {
        old.deleteSync();
      }
      final entry = zip.findFile(name);
      if (entry == null &&
          (name == 'calendar.txt' ||
              name == 'calendar_dates.txt' ||
              name == 'transfers.txt' ||
              name == 'pathways.txt')) {
        continue;
      }
      if (entry == null ||
          !entry.isFile ||
          entry.isSymbolicLink ||
          entry.size > 384 * 1024 * 1024) {
        throw FormatException('Invalid GTFS table: $name');
      }
      final out = OutputFileStream('$workPath/$name');
      try {
        entry.writeContent(out);
      } finally {
        out.closeSync();
      }
    }
    Iterable<Map<String, String>> rows(String name) =>
        _rows(File('$workPath/$name'));
    // Consume the small metadata table completely: Dart sync* iterators do not
    // close file handles when a caller stops after .first.
    final info = rows('feed_info.txt').toList().single;
    final first = _date(info['feed_start_date']!),
        last = _date(info['feed_end_date']!);
    final length = last.difference(first).inDays + 1;
    if (length < 1 || length > 32) {
      throw const FormatException('Unsupported timetable date span.');
    }
    final active = List.generate(length, (_) => <String>{});
    const weekdays = [
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    ];
    for (final r in rows('calendar.txt')) {
      final a = _date(r['start_date']!), b = _date(r['end_date']!);
      for (var i = 0; i < length; i++) {
        final d = first.add(Duration(days: i));
        if (!d.isBefore(a) &&
            !d.isAfter(b) &&
            r[weekdays[d.weekday - 1]] == '1') {
          active[i].add(r['service_id']!);
        }
      }
    }
    for (final r in rows('calendar_dates.txt')) {
      final i = _date(r['date']!).difference(first).inDays;
      if (i >= 0 && i < length) {
        r['exception_type'] == '1'
            ? active[i].add(r['service_id']!)
            : r['exception_type'] == '2'
            ? active[i].remove(r['service_id']!)
            : throw const FormatException('Invalid calendar exception.');
      }
    }
    final routes = {for (final r in rows('routes.txt')) r['route_id']!: r};
    final trips = {
      for (final r in rows('trips.txt'))
        if (routes.containsKey(r['route_id'])) r['trip_id']!: r,
    };
    final times = {for (final id in trips.keys) id: <List<dynamic>>[]};
    for (final r in rows('stop_times.txt')) {
      final items = times[r['trip_id']];
      if (items == null) {
        continue;
      }
      items.add([
        r['stop_id']!,
        int.parse(r['stop_sequence']!),
        _seconds(r['arrival_time']!),
        _seconds(r['departure_time']!),
        int.parse(r['pickup_type']?.isEmpty == false ? r['pickup_type']! : '0'),
        int.parse(
          r['drop_off_type']?.isEmpty == false ? r['drop_off_type']! : '0',
        ),
      ]);
    }
    final metroIds = {
      for (final t in trips.entries)
        if (routes[t.value['route_id']]!['route_type'] == '1') t.key,
    };
    final used = {
      for (final id in metroIds)
        for (final s in times[id]!) s[0] as String,
    };
    final stopRows = rows('stops.txt').toList();
    final allStops = {
      for (final r in stopRows)
        r['stop_id']!: [
          r['stop_name']!,
          r['parent_station'] ?? '',
          double.parse(r['stop_lat']!),
          double.parse(r['stop_lon']!),
          r['asw_node_id'] ?? '',
          int.parse(
            r['location_type']?.isNotEmpty == true ? r['location_type']! : '0',
          ),
          r['zone_id'] ?? '',
        ],
    };
    final allTrips = [
      for (final t in trips.entries)
        [
          t.key,
          routes[t.value['route_id']]!['route_short_name']!,
          t.value['trip_headsign'] ?? '',
          [
            for (var i = 0; i < length; i++)
              if (active[i].contains(t.value['service_id'])) 1 << i,
          ].fold<int>(0, (a, b) => a | b),
          times[t.key]!..sort((a, b) => (a[1] as int).compareTo(b[1] as int)),
          int.parse(routes[t.value['route_id']]!['route_type']!),
          t.value['block_id'] ?? '',
        ],
    ];
    final transfers = [
      for (final r in rows('transfers.txt'))
        [
          r['from_stop_id']!,
          r['to_stop_id']!,
          int.parse(r['transfer_type']!),
          int.tryParse(r['min_transfer_time'] ?? '') ?? 0,
          r['from_trip_id'] ?? '',
          r['to_trip_id'] ?? '',
        ],
    ];
    final pathways = [
      for (final r in rows('pathways.txt'))
        [
          r['from_stop_id']!,
          r['to_stop_id']!,
          r['is_bidirectional'] == '1',
          int.tryParse(r['traversal_time'] ?? '') ?? 180,
          (r['traversal_time'] ?? '').isEmpty,
        ],
    ];
    final stops = {
      for (final r in stopRows)
        if (used.contains(r['stop_id'])) r['stop_id']!: r['stop_name']!,
    };
    final result = <String, dynamic>{
      'start': dayKey(first),
      'end': dayKey(last),
      'stops': stops,
      'trips': [
        for (final t in allTrips)
          if (metroIds.contains(t[0])) t.take(5).toList(),
      ],
      'network': {
        'start': dayKey(first),
        'end': dayKey(last),
        'stops': allStops,
        'trips': allTrips,
        'transfers': transfers,
        'pathways': pathways,
      },
    };
    if (stops.length < 2 || trips.isEmpty) {
      throw const FormatException('The feed contains no usable metro data.');
    }
    return result;
  } finally {
    input.closeSync();
  }
}

DateTime _date(String value) {
  if (!RegExp(r'^\d{8}$').hasMatch(value)) {
    throw const FormatException('Invalid GTFS date.');
  }
  final y = int.parse(value.substring(0, 4)),
      m = int.parse(value.substring(4, 6)),
      d = int.parse(value.substring(6));
  final date = DateTime.utc(y, m, d);
  if (date.year != y || date.month != m || date.day != d) {
    throw const FormatException('Invalid GTFS date.');
  }
  return date;
}

int _seconds(String value) {
  final parts = value.split(':').map(int.parse).toList();
  if (parts.length != 3 ||
      parts[0] < 0 ||
      parts[0] > 72 ||
      parts[1] < 0 ||
      parts[1] > 59 ||
      parts[2] < 0 ||
      parts[2] > 59) {
    throw const FormatException('Invalid GTFS time.');
  }
  return parts[0] * 3600 + parts[1] * 60 + parts[2];
}

Iterable<Map<String, String>> _rows(File file) sync* {
  if (!file.existsSync()) {
    return;
  }
  final input = InputFileStream(file.path);
  // Line-by-line reading keeps the large stop_times table off the UI heap.
  final decoder = const Utf8Decoder();
  var pending = '', bytes = <int>[];
  List<String>? header;
  try {
    while (!input.isEOS) {
      final b = input.readByte();
      if (b != 10) {
        bytes.add(b);
        if (bytes.length > 65536) {
          throw const FormatException('Oversized GTFS record.');
        }
        continue;
      }
      final line = decoder.convert(bytes).replaceFirst(RegExp(r'\r$'), '');
      bytes = [];
      pending += line;
      if (pending.length > 65536) {
        throw const FormatException('Oversized GTFS record.');
      }
      if (_openQuote(pending)) {
        pending += '\n';
        continue;
      }
      if (pending.isNotEmpty) {
        final fields = _fields(pending);
        pending = '';
        if (header == null) {
          header = fields;
          header[0] = header[0].replaceFirst('\uFEFF', '');
        } else {
          if (fields.length != header.length) {
            throw const FormatException('GTFS column mismatch.');
          }
          yield Map.fromIterables(header, fields);
        }
      }
    }
    if (bytes.isNotEmpty || pending.isNotEmpty) {
      pending += decoder.convert(bytes).replaceFirst(RegExp(r'\r$'), '');
      if (_openQuote(pending)) {
        throw const FormatException('Unclosed GTFS field.');
      }
      final fields = _fields(pending);
      if (header != null) {
        if (fields.length != header.length) {
          throw const FormatException('GTFS column mismatch.');
        }
        yield Map.fromIterables(header, fields);
      }
    }
  } finally {
    input.closeSync();
  }
}

bool _openQuote(String line) {
  var open = false;
  for (var i = 0; i < line.length; i++) {
    if (line[i] == '"') {
      if (open && i + 1 < line.length && line[i + 1] == '"') {
        i++;
      } else {
        open = !open;
      }
    }
  }
  return open;
}

List<String> _fields(String line) {
  final values = <String>[];
  var value = StringBuffer(), quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        value.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == ',' && !quoted) {
      values.add(value.toString());
      value = StringBuffer();
    } else {
      value.write(c);
    }
  }
  if (quoted) {
    throw const FormatException('Unclosed GTFS field.');
  }
  values.add(value.toString());
  return values;
}
