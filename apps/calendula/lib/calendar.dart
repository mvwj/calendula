import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/timezone.dart' as tz;

final prague = tz.getLocation('Europe/Prague');
tz.TZDateTime localNow() => tz.TZDateTime.now(prague);
String dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String clock(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String newId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

class CalendarEvent {
  final String id,
      title,
      venue,
      address,
      room,
      floor,
      category,
      sessionType,
      locationSource,
      placeProfile,
      notes,
      courseCode,
      originStop,
      destinationStop;
  final DateTime start, end;
  final int travelMinutes, bufferMinutes;
  final int originWalkMinutes, destinationWalkMinutes;
  final bool sample, allDay;
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.venue = '',
    this.address = '',
    this.room = '',
    this.floor = '',
    this.category = 'Personal',
    this.sessionType = '',
    this.locationSource = '',
    this.placeProfile = '',
    this.notes = '',
    this.courseCode = '',
    this.travelMinutes = 0,
    this.bufferMinutes = 10,
    this.sample = false,
    this.allDay = false,
    this.originStop = '',
    this.destinationStop = '',
    this.originWalkMinutes = 0,
    this.destinationWalkMinutes = 0,
  });
  DateTime get localStart => tz.TZDateTime.from(start, prague);
  DateTime get localEnd => tz.TZDateTime.from(end, prague);
  DateTime get leaveAt =>
      localStart.subtract(Duration(minutes: travelMinutes + bufferMinutes));
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'venue': venue,
    'address': address,
    'room': room,
    'floor': floor,
    'category': category,
    'sessionType': sessionType,
    'locationSource': locationSource,
    'placeProfile': placeProfile,
    'notes': notes,
    'courseCode': courseCode,
    'travelMinutes': travelMinutes,
    'bufferMinutes': bufferMinutes,
    'sample': sample,
    'allDay': allDay,
    'originStop': originStop,
    'destinationStop': destinationStop,
    'originWalkMinutes': originWalkMinutes,
    'destinationWalkMinutes': destinationWalkMinutes,
  };
  factory CalendarEvent.fromJson(Map<String, dynamic> j) {
    final e = CalendarEvent(
      id: j['id'] as String,
      title: j['title'] as String,
      start: DateTime.parse(j['start']).toUtc(),
      end: DateTime.parse(j['end']).toUtc(),
      venue: j['venue'] ?? '',
      address: j['address'] ?? '',
      room: j['room'] ?? '',
      floor: j['floor'] ?? '',
      category: j['category'] ?? 'Personal',
      sessionType: j['sessionType'] ?? '',
      locationSource: j['locationSource'] ?? '',
      placeProfile: j['placeProfile'] ?? '',
      notes: j['notes'] ?? '',
      courseCode: j['courseCode'] ?? '',
      travelMinutes: j['travelMinutes'] ?? 0,
      bufferMinutes: j['bufferMinutes'] ?? 10,
      sample: j['sample'] ?? false,
      allDay: j['allDay'] ?? false,
      originStop: j['originStop'] ?? '',
      destinationStop: j['destinationStop'] ?? '',
      originWalkMinutes: j['originWalkMinutes'] ?? 0,
      destinationWalkMinutes: j['destinationWalkMinutes'] ?? 0,
    );
    if (e.sessionType.length > 80 ||
        e.placeProfile.length > 100 ||
        e.locationSource.length > 1000 ||
        e.title.trim().isEmpty ||
        !e.end.isAfter(e.start) ||
        e.travelMinutes < 0 ||
        e.bufferMinutes < 0 ||
        e.travelMinutes > 1440 ||
        e.bufferMinutes > 1440 ||
        e.originWalkMinutes < 0 ||
        e.destinationWalkMinutes < 0 ||
        e.originWalkMinutes > 180 ||
        e.destinationWalkMinutes > 180) {
      throw const FormatException('Invalid calendar event');
    }
    return e;
  }
}

List<CalendarEvent> eventsOnDay(Iterable<CalendarEvent> events, DateTime day) {
  final start = tz.TZDateTime(prague, day.year, day.month, day.day),
      end = tz.TZDateTime(prague, day.year, day.month, day.day + 1);
  return events
      .where((e) => e.start.isBefore(end) && e.end.isAfter(start))
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));
}

/// Inclusive calendar dates, independent of elapsed hours around DST changes.
class EventDatePeriod {
  final DateTime firstDate, lastDate;

  EventDatePeriod(DateTime first, DateTime last)
    : firstDate = DateTime.utc(first.year, first.month, first.day),
      lastDate = DateTime.utc(last.year, last.month, last.day) {
    if (lastDate.isBefore(firstDate)) {
      throw ArgumentError('The end date must not precede the start date.');
    }
  }

  factory EventDatePeriod.weekOf(DateTime date) {
    final day = DateTime.utc(date.year, date.month, date.day);
    final monday = day.subtract(Duration(days: day.weekday - DateTime.monday));
    return EventDatePeriod(monday, monday.add(const Duration(days: 6)));
  }

  factory EventDatePeriod.monthOf(DateTime date) => EventDatePeriod(
    DateTime.utc(date.year, date.month),
    DateTime.utc(date.year, date.month + 1, 0),
  );

  bool containsStart(CalendarEvent event) {
    final local = event.localStart;
    final day = DateTime.utc(local.year, local.month, local.day);
    return !day.isBefore(firstDate) && !day.isAfter(lastDate);
  }
}

String matchingEventTitle(String title) =>
    title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

List<CalendarEvent> similarEventsInPeriod(
  Iterable<CalendarEvent> events,
  CalendarEvent selected,
  EventDatePeriod period,
) {
  final title = matchingEventTitle(selected.title);
  return events
      .where(
        (event) =>
            !event.sample &&
            matchingEventTitle(event.title) == title &&
            period.containsStart(event),
      )
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));
}

List<CalendarEvent> demoEvents(DateTime day) {
  DateTime at(int h, int m) =>
      tz.TZDateTime(prague, day.year, day.month, day.day, h, m).toUtc();
  return [
    CalendarEvent(
      id: 'demo-study',
      title: 'Design & everyday life',
      start: at(10, 0),
      end: at(11, 30),
      venue: 'University · sample',
      address: 'Dejvická, Prague',
      room: '204',
      floor: '2',
      category: 'Study',
      travelMinutes: 25,
      bufferMinutes: 10,
      sample: true,
    ),
    CalendarEvent(
      id: 'demo-coffee',
      title: 'A little time for yourself',
      start: at(13, 0),
      end: at(14, 0),
      venue: 'Your favourite café · sample',
      category: 'Personal',
      sample: true,
    ),
    CalendarEvent(
      id: 'demo-film',
      title: 'An evening at the cinema',
      start: at(18, 30),
      end: at(20, 30),
      venue: 'Cinema · sample',
      address: 'Prague',
      category: 'Culture',
      travelMinutes: 30,
      bufferMinutes: 15,
      sample: true,
    ),
  ];
}

abstract class EventRepository {
  Future<List<CalendarEvent>> load();
  Future<void> save(List<CalendarEvent> events);
}

class EncryptedEventRepository implements EventRepository {
  static const _keyName = 'calendula.vault.key.v1';
  final FlutterSecureStorage _secure;
  final Future<Directory> Function() _directory;
  EncryptedEventRepository({
    FlutterSecureStorage? storage,
    Future<Directory> Function()? directory,
  }) : _secure = storage ?? const FlutterSecureStorage(),
       _directory = directory ?? getApplicationSupportDirectory;
  final _cipher = AesGcm.with256bits();
  SecretKey? _key;
  File? _file;
  Future<void> _open() async {
    if (_file != null) {
      return;
    }
    final dir = await _directory();
    final f = File('${dir.path}/calendar.vault');
    final existing = await _secure.read(key: _keyName);
    if (existing == null &&
        (await f.exists() || await File('${f.path}.previous').exists())) {
      throw StateError(
        'The calendar encryption key is unavailable. Your data has been preserved.',
      );
    }
    final key = existing == null
        ? await _cipher.newSecretKey()
        : SecretKey(base64Decode(existing));
    if (existing == null) {
      await _secure.write(
        key: _keyName,
        value: base64Encode(await key.extractBytes()),
      );
    }
    _key = key;
    _file = f;
  }

  Future<List<CalendarEvent>> _read(File f) async {
    if (await f.length() > 16 * 1024 * 1024) {
      throw const FormatException('Calendar file exceeds the supported size');
    }
    final box = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    if (box['version'] != 1) {
      throw const FormatException('Unsupported calendar version');
    }
    final clear = await _cipher.decrypt(
      SecretBox(
        base64Decode(box['ciphertext']),
        nonce: base64Decode(box['nonce']),
        mac: Mac(base64Decode(box['mac'])),
      ),
      secretKey: _key!,
      aad: utf8.encode('calendula-vault-v1'),
    );
    final data = jsonDecode(utf8.decode(clear)) as List;
    return data
        .map((j) => CalendarEvent.fromJson(Map<String, dynamic>.from(j)))
        .toList();
  }

  @override
  Future<List<CalendarEvent>> load() async {
    await _open();
    if (await _file!.exists()) {
      return _read(_file!);
    }
    final previous = File('${_file!.path}.previous');
    if (await previous.exists()) {
      return _read(previous);
    }
    return [];
  }

  @override
  Future<void> save(List<CalendarEvent> events) async {
    await _open();
    final clear = utf8.encode(
      jsonEncode(events.map((e) => e.toJson()).toList()),
    );
    if (clear.length > 12 * 1024 * 1024) {
      throw const FormatException('Calendar is too large');
    }
    final box = await _cipher.encrypt(
      clear,
      secretKey: _key!,
      aad: utf8.encode('calendula-vault-v1'),
    );
    final pending = File('${_file!.path}.pending');
    await pending.writeAsString(
      jsonEncode({
        'version': 1,
        'nonce': base64Encode(box.nonce),
        'mac': base64Encode(box.mac.bytes),
        'ciphertext': base64Encode(box.cipherText),
      }),
      flush: true,
    );
    final previous = File('${_file!.path}.previous');
    if (await _file!.exists()) {
      if (await previous.exists()) {
        await previous.delete();
      }
      await _file!.rename(previous.path);
    }
    await pending.rename(_file!.path);
  }
}
