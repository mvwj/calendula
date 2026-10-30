import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:xml/xml.dart';

import 'calendar.dart';
import 'event_place.dart';

class ImportBatch {
  final List<CalendarEvent> events;
  final List<String> warnings;
  final String sourceText;
  const ImportBatch(
    this.events, {
    this.warnings = const [],
    this.sourceText = '',
  });
}

String importId(String source) {
  // Deterministic duplicate key, never used as an authentication primitive.
  var h = BigInt.parse('14695981039346656037');
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final b in utf8.encode(source)) {
    h = ((h ^ BigInt.from(b)) * BigInt.from(1099511628211)) & mask;
  }
  return 'import-${h.toRadixString(16)}';
}

DateTime strictDate(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s.trim());
  if (m == null) {
    throw const FormatException('Use a date with its year, YYYY-MM-DD.');
  }
  final d = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  if (dayKey(d) != s.trim()) {
    throw const FormatException('Invalid calendar date.');
  }
  return d;
}

DateTime strictWall(DateTime day, String time, [tz.Location? zone]) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(time.trim());
  if (m == null) throw const FormatException('Use HH:MM for a time.');
  final h = int.parse(m[1]!),
      minute = int.parse(m[2]!),
      second = int.parse(m[3] ?? '0');
  if (h > 23 || minute > 59 || second > 59) {
    throw const FormatException('Invalid time.');
  }
  final d = tz.TZDateTime(
    zone ?? prague,
    day.year,
    day.month,
    day.day,
    h,
    minute,
    second,
  );
  if (d.day != day.day || d.hour != h || d.minute != minute) {
    throw const FormatException(
      'Time falls in a daylight-saving gap. Check it manually.',
    );
  }
  return d.toUtc();
}

String _unescape(String s) => s.replaceAllMapped(
  RegExp(r'\\([nN,;\\])'),
  (m) => m[1]!.toLowerCase() == 'n' ? '\n' : m[1]!,
);

ImportBatch parseIcs(
  String text, {
  required DateTime from,
  required DateTime through,
}) {
  if (text.length > 2 * 1024 * 1024) {
    throw const FormatException('ICS exceeds 2 MB.');
  }
  if (through.difference(from).inDays > 366 || through.isBefore(from)) {
    throw const FormatException('Choose an import window up to one year.');
  }
  final unfolded = text.replaceAll(RegExp(r'\r?\n[ \t]'), '');
  final blocks = RegExp(
    r'BEGIN:VEVENT\r?\n([\s\S]*?)END:VEVENT',
    caseSensitive: false,
  ).allMatches(unfolded).toList();
  if (blocks.isEmpty || blocks.length > 3000) {
    throw const FormatException(
      'No supported events found, or more than 3,000 source events.',
    );
  }
  final warnings = <String>[], parsed = <_IcsItem>[];
  for (final block in blocks) {
    try {
      final props = <String, List<(String, String)>>{};
      for (final line in block[1]!.split(RegExp(r'\r?\n'))) {
        final colon = line.indexOf(':');
        if (colon < 1) continue;
        final name = line.substring(0, colon),
            key = name.split(';').first.toUpperCase();
        props.putIfAbsent(key, () => []).add((name, line.substring(colon + 1)));
      }
      String value(String k) => _unescape(props[k]?.first.$2 ?? '');
      DateTime stamp((String, String) p) {
        final s = p.$2;
        if (RegExp(r'^\d{8}$').hasMatch(s)) {
          final d = strictDate(
            '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}',
          );
          return tz.TZDateTime(prague, d.year, d.month, d.day).toUtc();
        }
        final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z?)$')
            .firstMatch(s);
        if (m == null) throw const FormatException('Unsupported ICS date.');
        final d = strictDate('${m[1]}-${m[2]}-${m[3]}');
        final zoneName = RegExp(r'TZID="?([^;"\s]+)')
            .firstMatch(p.$1)
            ?.group(1);
        final zone = m[7] == 'Z'
            ? tz.UTC
            : zoneName == null
            ? prague
            : tz.getLocation(zoneName);
        return strictWall(d, '${m[4]}:${m[5]}:${m[6] ?? '00'}', zone);
      }

      final uid = value('UID');
      final cancelled = value('STATUS').toUpperCase() == 'CANCELLED';
      final recurrence = props['RECURRENCE-ID']?.first;
      final rawStart = props['DTSTART']?.first ?? recurrence;
      if (rawStart == null) {
        throw const FormatException('ICS event has no start.');
      }
      final start = stamp(rawStart),
          allDay = RegExp(r'^\d{8}$').hasMatch(rawStart.$2);
      var end = props['DTEND'] == null ? null : stamp(props['DTEND']!.first);
      if (end == null && props['DURATION'] != null) {
        final m = RegExp(
          r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
        ).firstMatch(value('DURATION'));
        if (m == null) {
          throw const FormatException('Unsupported event duration.');
        }
        end = start.add(
          Duration(
            days: int.parse(m[1] ?? '0'),
            hours: int.parse(m[2] ?? '0'),
            minutes: int.parse(m[3] ?? '0'),
            seconds: int.parse(m[4] ?? '0'),
          ),
        );
      }
      if (end == null && allDay) {
        final d = tz.TZDateTime.from(start, prague);
        end = tz.TZDateTime(prague, d.year, d.month, d.day + 1).toUtc();
      }
      if (end == null && !cancelled) {
        throw const FormatException(
          'ICS event has no end; review the source manually.',
        );
      }
      end ??= start.add(const Duration(hours: 1));
      if (!end.isAfter(start) ||
          (!cancelled && value('SUMMARY').trim().isEmpty)) {
        throw const FormatException('ICS has an empty title or invalid end.');
      }
      parsed.add(
        _IcsItem(
          uid,
          value('SUMMARY'),
          start,
          end,
          allDay,
          value('LOCATION'),
          value('DESCRIPTION'),
          value('RRULE'),
          recurrence == null ? null : stamp(recurrence),
          cancelled,
          [
            for (final p in props['EXDATE'] ?? <(String, String)>[])
              for (final s in p.$2.split(',')) stamp((p.$1, s)),
          ],
          [
            for (final p in props['RDATE'] ?? <(String, String)>[])
              for (final s in p.$2.split(',')) stamp((p.$1, s)),
          ],
          rawStart.$2.endsWith('Z')
              ? tz.UTC
              : tz.getLocation(
                  RegExp(r'TZID="?([^;"\s]+)')
                          .firstMatch(rawStart.$1)
                          ?.group(1) ??
                      'Europe/Prague',
                ),
        ),
      );
    } catch (e) {
      warnings.add(
        e is FormatException
            ? e.message
            : 'An event uses an unsupported time zone or format.',
      );
    }
  }
  final overrides = <String, _IcsItem>{
    for (final i in parsed.where((e) => e.recurrence != null))
      '${i.uid}:${i.recurrence!.millisecondsSinceEpoch}': i,
  };
  final events = <String, CalendarEvent>{};
  final lower = tz.TZDateTime(prague, from.year, from.month, from.day).toUtc(),
      upper = tz.TZDateTime(
        prague,
        through.year,
        through.month,
        through.day + 1,
      ).toUtc();
  void add(_IcsItem i, DateTime occurrence, {DateTime? original}) {
    final identity = original ?? occurrence;
    final replacement =
        overrides['${i.uid}:${identity.millisecondsSinceEpoch}'];
    if (replacement != null && replacement != i) {
      add(replacement, replacement.start, original: identity);
      return;
    }
    if (i.cancelled) {
      warnings.add(
        'Cancellation for ${i.title.isEmpty ? 'an event' : i.title}: check existing events manually.',
      );
      return;
    }
    if (i.excluded.any((d) => d.isAtSameMomentAs(identity))) return;
    final a = tz.TZDateTime.from(i.start, i.zone),
        b = tz.TZDateTime.from(i.end, i.zone),
        d = tz.TZDateTime.from(occurrence, i.zone);
    final days = DateTime.utc(
      b.year,
      b.month,
      b.day,
    ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
    final end = i.allDay
        ? tz.TZDateTime(i.zone, d.year, d.month, d.day + days).toUtc()
        : occurrence.add(i.end.difference(i.start));
    if (!occurrence.isBefore(upper) || !end.isAfter(lower)) return;
    final id = importId(
      'ics:${i.uid.isEmpty ? '${i.title}:${i.location}' : i.uid}:${identity.toIso8601String()}',
    );
    events[id] = CalendarEvent(
      id: id,
      title: i.title,
      start: occurrence,
      end: end,
      venue: i.location,
      notes: i.notes,
      allDay: i.allDay,
    );
    if (events.length > 5000) {
      throw const FormatException(
        'Import contains more than 5,000 occurrences. Choose a shorter window.',
      );
    }
  }

  for (final i in parsed.where((e) => e.recurrence == null)) {
    if (i.rule.isEmpty) {
      add(i, i.start);
      continue;
    }
    try {
      final rule = <String, String>{
        for (final p in i.rule.split(';'))
          if (p.contains('='))
            p.split('=').first: p.substring(p.indexOf('=') + 1),
      };
      if (!['DAILY', 'WEEKLY'].contains(rule['FREQ']) ||
          rule.keys.any(
            (k) => ![
              'FREQ',
              'INTERVAL',
              'COUNT',
              'UNTIL',
              'BYDAY',
              'WKST',
            ].contains(k),
          )) {
        warnings.add(
          'Unsupported recurrence for ${i.title}. Daily and weekly rules are supported; review other rules manually.',
        );
        continue;
      }
      final interval = int.tryParse(rule['INTERVAL'] ?? '1') ?? 0,
          count = int.tryParse(rule['COUNT'] ?? '10000') ?? 0;
      if (interval < 1 || interval > 366 || count < 1 || count > 10000) {
        throw const FormatException('Invalid recurrence limit.');
      }
      final base = tz.TZDateTime.from(i.start, i.zone),
          baseDay = DateTime.utc(base.year, base.month, base.day);
      const weekdays = {
        'MO': 1,
        'TU': 2,
        'WE': 3,
        'TH': 4,
        'FR': 5,
        'SA': 6,
        'SU': 7,
      };
      final byDay =
          rule['BYDAY']?.split(',') ??
          [weekdays.entries.firstWhere((e) => e.value == base.weekday).key];
      if (byDay.any((s) => !weekdays.containsKey(s))) {
        throw const FormatException('Ordinal weekdays need manual review.');
      }
      final wkst = weekdays[rule['WKST'] ?? 'MO'];
      if (wkst == null) throw const FormatException('Invalid week start.');
      final weekBase = baseDay.subtract(
        Duration(days: (baseDay.weekday - wkst + 7) % 7),
      );
      DateTime? until;
      if (rule['UNTIL'] != null) {
        final s = rule['UNTIL']!;
        if (s.endsWith('Z')) {
          final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$')
              .firstMatch(s);
          if (m == null) throw const FormatException('Invalid recurrence end.');
          until = strictWall(
            strictDate('${m[1]}-${m[2]}-${m[3]}'),
            '${m[4]}:${m[5]}:${m[6]}',
            tz.UTC,
          );
        } else if (s.length == 8) {
          final d = strictDate(
            '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}',
          );
          until = tz.TZDateTime(
            prague,
            d.year,
            d.month,
            d.day + 1,
          ).toUtc().subtract(const Duration(microseconds: 1));
        } else {
          throw const FormatException('Recurrence end needs UTC or a date.');
        }
      }
      var emitted = 0;
      for (var n = 0; n <= 36600 && emitted < count; n++) {
        final day = baseDay.add(Duration(days: n));
        if (day.isAfter(
          DateTime.utc(through.year, through.month, through.day),
        )) {
          break;
        }
        final include = rule['FREQ'] == 'DAILY'
            ? n % interval == 0 &&
                  (rule['BYDAY'] == null ||
                      byDay.contains(
                        weekdays.entries
                            .firstWhere((e) => e.value == day.weekday)
                            .key,
                      ))
            : day.difference(weekBase).inDays ~/ 7 % interval == 0 &&
                  byDay.any((s) => weekdays[s] == day.weekday);
        if (!include) continue;
        final occurrence = tz.TZDateTime(
          i.zone,
          day.year,
          day.month,
          day.day,
          base.hour,
          base.minute,
          base.second,
        ).toUtc();
        if (until != null && occurrence.isAfter(until)) break;
        emitted++;
        add(i, occurrence);
      }
      for (final d in i.additional) {
        add(i, d);
      }
    } on FormatException catch (e) {
      warnings.add('${i.title}: ${e.message}');
    }
  }
  for (final i in parsed.where((e) => e.recurrence != null)) {
    add(i, i.start, original: i.recurrence);
  }
  final list = events.values.toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  return ImportBatch(
    list,
    warnings: warnings.toSet().toList(),
    sourceText: text,
  );
}

class _IcsItem {
  final String uid, title, location, notes, rule;
  final DateTime start, end;
  final bool allDay, cancelled;
  final DateTime? recurrence;
  final List<DateTime> excluded, additional;
  final tz.Location zone;
  _IcsItem(
    this.uid,
    this.title,
    this.start,
    this.end,
    this.allDay,
    this.location,
    this.notes,
    this.rule,
    this.recurrence,
    this.cancelled,
    this.excluded,
    this.additional,
    this.zone,
  );
}

List<List<String>> readXlsx(Uint8List bytes) {
  if (bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('Spreadsheet exceeds 20 MB.');
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  var total = 0;
  final files = <String, String>{};
  for (final f in archive) {
    total += f.size;
    if (total > 80 * 1024 * 1024 || f.size > 20 * 1024 * 1024) {
      throw const FormatException(
        'Expanded spreadsheet exceeds its size limit.',
      );
    }
    if (f.isFile &&
        (f.name == 'xl/sharedStrings.xml' ||
            f.name == 'xl/workbook.xml' ||
            RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name))) {
      final s = utf8.decode(f.content as List<int>);
      if (s.contains('<!DOCTYPE') || s.contains('<!ENTITY')) {
        throw const FormatException('External XML entities are not accepted.');
      }
      files[f.name] = s;
    }
  }
  List<XmlElement> elements(XmlNode n, String name) => n.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == name)
      .toList();
  final shared = files['xl/sharedStrings.xml'] == null
      ? <String>[]
      : elements(
          XmlDocument.parse(files['xl/sharedStrings.xml']!),
          'si',
        ).map((e) => elements(e, 't').map((t) => t.innerText).join()).toList();
  final rows = <List<String>>[];
  final workbook = files['xl/workbook.xml'];
  final date1904 =
      workbook != null &&
      elements(
        XmlDocument.parse(workbook),
        'workbookPr',
      ).any((e) => {'1', 'true'}.contains(e.getAttribute('date1904')));
  for (final entry in files.entries.where(
    (e) => e.key.startsWith('xl/worksheets/'),
  )) {
    int? dateColumn;
    var firstRow = true;
    for (final row in elements(XmlDocument.parse(entry.value), 'row')) {
      final values = <int, String>{};
      for (final c in row.childElements.where((e) => e.name.local == 'c')) {
        final ref = RegExp(r'^([A-Z]+)\d+$')
            .firstMatch(c.getAttribute('r') ?? '');
        if (ref == null) continue;
        var column = 0;
        for (final code in ref[1]!.codeUnits) {
          column = column * 26 + code - 64;
        }
        if (column > 100) continue;
        final raw = elements(c, 'v').firstOrNull?.innerText ?? '';
        values[column - 1] = switch (c.getAttribute('t')) {
          's' => shared.elementAtOrNull(int.tryParse(raw) ?? -1) ?? '',
          'inlineStr' => elements(c, 't').map((e) => e.innerText).join(),
          _ => raw,
        };
      }
      if (values.isNotEmpty) {
        if (firstRow) {
          for (final v in values.entries) {
            if ({
              'date',
              'datum',
              'day',
            }.contains(v.value.toLowerCase().trim())) {
              dateColumn = v.key;
            }
          }
          firstRow = false;
        } else if (date1904 && dateColumn != null) {
          final serial = double.tryParse(values[dateColumn] ?? '');
          if (serial != null && serial >= 0 && serial < 100000) {
            values[dateColumn] = '${serial + 1462}';
          }
        }
        rows.add(
          List.generate(
            values.keys.reduce((a, b) => a > b ? a : b) + 1,
            (i) => values[i] ?? '',
          ),
        );
      }
      if (rows.length > 10000) {
        throw const FormatException(
          'Spreadsheet contains more than 10,000 rows.',
        );
      }
    }
  }
  return rows;
}

ImportBatch parseScheduleRows(
  List<List<String>> rows, {
  String source = 'table',
}) {
  if (rows.isEmpty) throw const FormatException('The table is empty.');
  const aliases = {
    'title': [
      'title',
      'subject',
      'event',
      'name',
      'předmět',
      'predmet',
      'název',
      'nazev',
      'movie',
    ],
    'date': ['date', 'datum', 'day'],
    'start': ['start', 'from', 'begin', 'začátek', 'zacatek', 'od'],
    'end': ['end', 'to', 'finish', 'konec', 'do'],
    'address': ['address', 'adresa'],
    'venue': ['venue', 'location', 'place', 'místo', 'misto'],
    'room': ['room', 'auditorium', 'učebna', 'ucebna', 'místnost', 'mistnost'],
    'floor': ['floor', 'patro'],
    'notes': ['notes', 'description', 'poznámka', 'poznamka'],
    'type': [
      'type',
      'session type',
      'class type',
      'typ',
      'typ výuky',
      'typ vyuky',
    ],
  };
  final columns = <String, int>{};
  for (var i = 0; i < rows.first.length; i++) {
    final header = rows.first[i].trim().toLowerCase();
    for (final e in aliases.entries) {
      if (e.value.contains(header)) columns[e.key] = i;
    }
  }
  if (!['title', 'date', 'start', 'end'].every(columns.containsKey)) {
    throw const FormatException(
      'Table needs Title, Date, Start and End columns. Optional: Venue, Address, Room, Floor, Notes.',
    );
  }
  final events = <CalendarEvent>[], warnings = <String>[];
  for (var i = 1; i < rows.length; i++) {
    String value(String key) => columns[key] == null
        ? ''
        : rows[i].elementAtOrNull(columns[key]!)?.trim() ?? '';
    if (rows[i].every((s) => s.trim().isEmpty)) continue;
    try {
      var ds = value('date');
      final european = RegExp(r'^(\d{1,2})[./](\d{1,2})[./](\d{4})$')
          .firstMatch(ds);
      if (european != null) {
        ds =
            '${european[3]}-${european[2]!.padLeft(2, '0')}-${european[1]!.padLeft(2, '0')}';
      }
      final number = double.tryParse(ds);
      if (number != null && number >= 1 && number < 100000) {
        ds = dayKey(
          DateTime.utc(1899, 12, 30).add(Duration(days: number.floor())),
        );
      }
      final day = strictDate(ds);
      String time(String s) {
        final n = double.tryParse(s);
        if (n != null && n >= 0 && n < 1) {
          final minute = (n * 1440).round();
          return '${minute ~/ 60}:${(minute % 60).toString().padLeft(2, '0')}';
        }
        return s;
      }

      final start = strictWall(day, time(value('start'))),
          end = strictWall(day, time(value('end'))),
          title = value('title');
      if (title.isEmpty || !end.isAfter(start)) {
        throw const FormatException('Check title and end time.');
      }
      final sessionType = sessionTypeFrom(value('type')).isEmpty
          ? explicitTitleType(title)
          : sessionTypeFrom(value('type'));
      events.add(
        CalendarEvent(
          id: importId(
            '$source:$title:${start.toIso8601String()}:${value('venue')}:${value('room')}',
          ),
          title: title,
          start: start,
          end: end,
          venue: value('venue'),
          address: value('address'),
          room: value('room'),
          floor: value('floor'),
          notes: value('notes'),
          sessionType: sessionType,
          category: sessionType.isEmpty ? 'Personal' : 'Study',
          locationSource: value('address').isEmpty ? '' : source,
        ),
      );
    } on FormatException catch (e) {
      warnings.add('Row ${i + 1}: ${e.message}');
    }
  }
  return ImportBatch(events, warnings: warnings);
}

ImportBatch recognizeText(String text, {String source = 'text'}) {
  if (text.length > 500000) {
    throw const FormatException('Text exceeds 500,000 characters.');
  }
  final events = <CalendarEvent>[], warnings = <String>[];
  // Explicit labelled messages are recognized without guessing dates or sending text away.
  final labels = <String, String>{};
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final labelled = RegExp(
      r'^\s*(Title|Subject|Date|Start|End|Venue|Location|Address|Room|Floor|Notes)\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (labelled == null) continue;
    var label = labelled[1]!.toLowerCase();
    if (label == 'subject') label = 'title';
    if (label == 'location') label = 'venue';
    labels[label] = labelled[2]!.trim();
  }
  if (['title', 'date', 'start', 'end'].every(labels.containsKey)) {
    final keys = [
      'title',
      'date',
      'start',
      'end',
      'venue',
      'address',
      'room',
      'floor',
      'notes',
    ];
    final structured = parseScheduleRows([
      keys,
      keys.map((k) => labels[k] ?? '').toList(),
    ], source: source);
    return ImportBatch(
      structured.events,
      warnings: structured.warnings,
      sourceText: text,
    );
  }
  final pattern = RegExp(
    r'(\d{4}-\d{2}-\d{2}|\d{1,2}[./]\d{1,2}[./]\d{4})[^\n]*?(\d{1,2}:\d{2})\s*(?:[-–—]|to|až|az)\s*(\d{1,2}:\d{2})',
    caseSensitive: false,
  );
  for (final m in pattern.allMatches(text).take(3000)) {
    final lineStart = text.lastIndexOf('\n', m.start) + 1,
        next = text.indexOf('\n', m.end);
    final line = text
        .substring(lineStart, next < 0 ? text.length : next)
        .trim();
    final before = text.substring(lineStart, m.start).trim(),
        after = text.substring(m.end, next < 0 ? text.length : next).trim();
    final fields = after.split(RegExp(r'\s*[|\t]\s*'));
    final title = before.isNotEmpty ? before : fields.firstOrNull ?? '';
    if (title.isEmpty) {
      warnings.add('A dated time range has no title. Add its title manually.');
      continue;
    }
    final batch = parseScheduleRows([
      ['Title', 'Date', 'Start', 'End', 'Venue'],
      [title, m[1]!, m[2]!, m[3]!, fields.length > 1 ? fields[1] : ''],
    ], source: source);
    events.addAll(batch.events);
    warnings.addAll(batch.warnings);
    if (line.toLowerCase().contains('cancel') ||
        line.toLowerCase().contains('zrušen')) {
      warnings.add(
        'Possible cancellation: check this item against your calendar before saving.',
      );
    }
  }
  if (events.isEmpty) {
    warnings.add(
      'No complete date and time range found. Add or correct Title, Date, Start and End manually. Dates without a year are not guessed.',
    );
  }
  return ImportBatch(events, warnings: warnings, sourceText: text);
}
