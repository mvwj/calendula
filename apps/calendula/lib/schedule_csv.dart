import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'event_place.dart';

// SIS exports time as minutes since midnight, not a locale-dependent string.
class ScheduleRule {
  final String parentId, id, code, title, room, teachers, parity;
  final int weekday, minute, duration, firstWeek, weeks, row;
  final DateTime? once;
  final String sessionType, address, venue, floor;
  const ScheduleRule({
    required this.parentId,
    required this.id,
    required this.code,
    required this.title,
    required this.room,
    required this.teachers,
    required this.parity,
    required this.weekday,
    required this.minute,
    required this.duration,
    required this.firstWeek,
    required this.weeks,
    required this.row,
    this.once,
    this.sessionType = '',
    this.address = '',
    this.venue = '',
    this.floor = '',
  });
  String get timing => '${_minute(minute)}–${_minute(minute + duration)}';
  String get key => '$parentId/$id';
  String get recurrence => once != null
      ? dayKey(once!)
      : '${parity == 'odd'
            ? 'Odd'
            : parity == 'even'
            ? 'Even'
            : 'Every'} week · from week $firstWeek · $weeks weeks';
}

String _minute(int value) =>
    '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';

class CsvSchedule {
  final List<ScheduleRule> rules;
  final String encoding;
  const CsvSchedule(this.rules, this.encoding);
  static CsvSchedule decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      throw const FormatException('Choose a CSV file smaller than 2 MB.');
    }
    String text, encoding = 'UTF-8';
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      encoding = 'Windows-1250';
      text = String.fromCharCodes(
        bytes.map((b) {
          if (b < 128) {
            return b;
          }
          final cp = _cp1250[b - 128];
          if (cp < 0) {
            throw const FormatException(
              'Unsupported text encoding. Export as UTF-8 or Windows-1250.',
            );
          }
          return cp;
        }),
      );
    }
    text = text.replaceFirst(RegExp('^\uFEFF'), '');
    final first = text.split(RegExp(r'\r?\n')).first;
    final delimiter = first.contains(';') ? ';' : ',';
    final table = _csv(text, delimiter);
    if (table.length < 2) {
      throw const FormatException('The CSV has no schedule rows.');
    }
    final header = table.first.map((v) => v.trim().toLowerCase()).toList();
    const names = [
      'id listku',
      'id podlistku',
      'kod predmetu',
      'nazev',
      'den(',
      'cas(',
      'mistnost',
      'delka(',
      'prvni tyden',
      'prvni den',
      'pocet tydnu',
      'ctrnactideni',
      'ucitele',
    ];
    final indices = names
        .map((name) => header.indexWhere((h) => h.startsWith(name)))
        .toList();
    if (indices.any((i) => i < 0) || indices.toSet().length != 13) {
      throw const FormatException(
        'This importer expects a Charles University SIS schedule CSV (13 named columns).',
      );
    }
    final rules = <ScheduleRule>[];
    final seen = <String>{};
    for (var r = 1; r < table.length; r++) {
      final cells = table[r];
      if (cells.every((c) => c.trim().isEmpty)) {
        continue;
      }
      Never bad(String detail) =>
          throw FormatException('Row ${r + 1}: $detail');
      if (cells.length != header.length) {
        bad('column count does not match the header.');
      }
      String cell(int i) => cells[indices[i]].trim();
      String optional(List<String> names) {
        final index = header.indexWhere(names.contains);
        return index < 0 ? '' : cells[index].trim();
      }

      int integer(int i, int min, int max, {int? empty}) {
        final n = cell(i).isEmpty ? empty : int.tryParse(cell(i));
        if (n == null || n < min || n > max) {
          bad('invalid ${names[i]}.');
        }
        return n;
      }

      final parent = cell(0), id = cell(1), code = cell(2), title = cell(3);
      if (parent.isEmpty ||
          id.isEmpty ||
          parent.length > 100 ||
          id.length > 100 ||
          code.isEmpty ||
          code.length > 80 ||
          title.isEmpty ||
          title.length > 300 ||
          cell(6).length > 300 ||
          cell(12).length > 2000) {
        bad('missing or oversized course information.');
      }
      if (!seen.add('$parent/$id')) {
        bad('duplicate meeting ID; the file needs review.');
      }
      final day = integer(4, 1, 7),
          minute = integer(5, 0, 1439),
          length = integer(7, 1, 1440);
      if (minute + length > 1440) {
        bad('overnight classes are not supported in this SIS importer.');
      }
      DateTime? once;
      if (cell(9).isNotEmpty) {
        final match = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$')
            .firstMatch(cell(9));
        if (match == null) {
          bad('one-off date must be d.m.yyyy.');
        }
        final d = int.parse(match.group(1)!),
            m = int.parse(match.group(2)!),
            y = int.parse(match.group(3)!);
        once = DateTime.utc(y, m, d);
        if (y < 2020 ||
            y > 2040 ||
            once.day != d ||
            once.month != m ||
            once.weekday != day) {
          bad('one-off date is invalid or conflicts with the weekday.');
        }
      }
      final parity = switch (cell(11).toLowerCase()) {
        '' => '',
        'liche' || 'liché' => 'odd',
        'sude' || 'sudé' => 'even',
        _ => bad('unknown fortnightly rule.'),
      };
      final firstWeek = integer(8, 1, 53, empty: once == null ? null : 1);
      final weeks = integer(10, 1, 53);
      if (once != null && (weeks != 1 || parity.isNotEmpty)) {
        bad('contradictory one-off recurrence.');
      }
      rules.add(
        ScheduleRule(
          parentId: parent,
          id: id,
          code: code,
          title: title,
          room: cell(6),
          teachers: cell(12),
          parity: parity,
          weekday: day,
          minute: minute,
          duration: length,
          firstWeek: firstWeek,
          weeks: weeks,
          row: r + 1,
          once: once,
          sessionType:
              sessionTypeFrom(
                optional(['type', 'session type', 'typ', 'typ vyuky']),
              ).isEmpty
              ? explicitTitleType(title)
              : sessionTypeFrom(
                  optional(['type', 'session type', 'typ', 'typ vyuky']),
                ),
          address: optional(['address', 'adresa']),
          venue: optional(['venue', 'location', 'misto', 'místo']),
          floor: optional(['floor', 'patro']),
        ),
      );
      if (rules.length > 1000) {
        bad('more than 1,000 meeting rules.');
      }
    }
    if (rules.isEmpty) {
      throw const FormatException('The CSV has no schedule rows.');
    }
    return CsvSchedule(List.unmodifiable(rules), encoding);
  }

  // A bounded calendar-week preview. Faculty holiday/week-number calendars are
  // deliberately not inferred from course prefixes or a missing semester year.
  List<CalendarEvent> expand({
    required DateTime weekOneMonday,
    required DateTime from,
    required DateTime through,
    Set<String>? selected,
    Map<String, String> types = const {},
    bool mffPlaces = true,
    Map<String, CalendarEvent> meetingDetails = const {},
  }) {
    DateTime date(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    final anchor = date(weekOneMonday), a = date(from), b = date(through);
    if (anchor.weekday != DateTime.monday ||
        b.isBefore(a) ||
        b.difference(a).inDays > 31) {
      throw const FormatException(
        'Choose a Monday for week 1 and an import window of at most 32 days.',
      );
    }
    final events = <CalendarEvent>[];
    for (final rule in rules) {
      if (selected != null && !selected.contains(rule.key)) {
        continue;
      }
      final series =
          'sis:${Uri.encodeComponent(rule.parentId)}:${Uri.encodeComponent(rule.id)}';
      final learned = meetingDetails[series];
      final learnedPlace =
          rule.address.isEmpty && learned?.address.isNotEmpty == true;
      for (var d = a; !d.isAfter(b); d = d.add(const Duration(days: 1))) {
        if (rule.once != null) {
          if (d != rule.once) {
            continue;
          }
        } else {
          if (d.weekday != rule.weekday || d.isBefore(anchor)) {
            continue;
          }
          final week = d.difference(anchor).inDays ~/ 7 + 1;
          if (week < rule.firstWeek ||
              week >= rule.firstWeek + rule.weeks ||
              rule.parity == 'odd' && week.isEven ||
              rule.parity == 'even' && week.isOdd) {
            continue;
          }
        }
        final local = tz.TZDateTime(
          prague,
          d.year,
          d.month,
          d.day,
          rule.minute ~/ 60,
          rule.minute % 60,
        );
        if (local.hour * 60 + local.minute != rule.minute ||
            _sameWall(local, local.subtract(const Duration(hours: 1))) ||
            _sameWall(local, local.add(const Duration(hours: 1)))) {
          throw FormatException(
            'Row ${rule.row}: class time falls on an ambiguous clock change.',
          );
        }
        events.add(
          enrichStudyPlace(
            CalendarEvent(
              id: 'sis:${Uri.encodeComponent(rule.parentId)}:${Uri.encodeComponent(rule.id)}:${dayKey(d)}',
              title: rule.title,
              start: local.toUtc(),
              end: local.add(Duration(minutes: rule.duration)).toUtc(),
              room: rule.room,
              courseCode: rule.code,
              category: 'Study',
              sessionType:
                  types[rule.key] ??
                  (rule.sessionType.isNotEmpty
                      ? rule.sessionType
                      : learned?.sessionType ?? ''),
              address: learnedPlace ? learned!.address : rule.address,
              venue: learnedPlace ? learned!.venue : rule.venue,
              floor: learnedPlace ? learned!.floor : rule.floor,
              locationSource: learnedPlace
                  ? learned!.locationSource
                  : rule.address.isEmpty
                  ? ''
                  : 'SIS CSV',
              placeProfile: mffPlaces ? 'cuni-mff' : 'none',
              notes:
                  '${rule.teachers.isEmpty ? '' : 'Teachers: ${rule.teachers}\n'}'
                  'SIS CSV · ${rule.recurrence}\n'
                  'Week 1: ${dayKey(anchor)}. Calendar-week preview; holidays and cancellations need checking.',
            ),
            mff: mffPlaces,
          ),
        );
        if (events.length > 5000) {
          throw const FormatException('Import contains too many occurrences.');
        }
      }
    }
    events.sort((a, b) {
      final time = a.start.compareTo(b.start);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    return events;
  }
}

bool _sameWall(DateTime a, DateTime b) =>
    a.year == b.year &&
    a.month == b.month &&
    a.day == b.day &&
    a.hour == b.hour &&
    a.minute == b.minute;
bool overlaps(CalendarEvent a, CalendarEvent b) =>
    a.id != b.id && a.start.isBefore(b.end) && b.start.isBefore(a.end);
Set<String> conflictIds(List<CalendarEvent> events) {
  final sorted = [...events]..sort((a, b) => a.start.compareTo(b.start));
  final result = <String>{};
  for (var i = 0; i < sorted.length; i++) {
    for (
      var j = i + 1;
      j < sorted.length && sorted[j].start.isBefore(sorted[i].end);
      j++
    ) {
      if (overlaps(sorted[i], sorted[j])) {
        result.addAll([sorted[i].id, sorted[j].id]);
      }
    }
  }
  return result;
}

List<List<String>> _csv(String text, String delimiter) {
  final rows = <List<String>>[], row = <String>[];
  var field = StringBuffer(), quoted = false, closed = false;
  void finish() {
    row.add(field.toString());
    field = StringBuffer();
    closed = false;
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == delimiter) {
      finish();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
        i++;
      }
      finish();
      rows.add([...row]);
      row.clear();
      if (rows.length > 2000) {
        throw const FormatException('Too many CSV records.');
      }
    } else if (ch == '"' && field.isEmpty && !closed) {
      quoted = true;
    } else if (closed || ch == '"') {
      throw const FormatException('Malformed CSV quotes.');
    } else {
      field.write(ch);
    }
  }
  if (quoted) {
    throw const FormatException('Unclosed CSV quote.');
  }
  if (field.isNotEmpty || row.isNotEmpty || closed) {
    finish();
    rows.add([...row]);
  }
  return rows;
}

const _cp1250 = <int>[
  // Generated from the standard Windows-1250 character table, never user data.
  8364,
  -1,
  8218,
  -1,
  8222,
  8230,
  8224,
  8225,
  -1,
  8240,
  352,
  8249,
  346,
  356,
  381,
  377,
  -1,
  8216,
  8217,
  8220,
  8221,
  8226,
  8211,
  8212,
  -1,
  8482,
  353,
  8250,
  347,
  357,
  382,
  378,
  160,
  711,
  728,
  321,
  164,
  260,
  166,
  167,
  168,
  169,
  350,
  171,
  172,
  173,
  174,
  379,
  176,
  177,
  731,
  322,
  180,
  181,
  182,
  183,
  184,
  261,
  351,
  187,
  317,
  733,
  318,
  380,
  340,
  193,
  194,
  258,
  196,
  313,
  262,
  199,
  268,
  201,
  280,
  203,
  282,
  205,
  206,
  270,
  272,
  323,
  327,
  211,
  212,
  336,
  214,
  215,
  344,
  366,
  218,
  368,
  220,
  221,
  354,
  223,
  341,
  225,
  226,
  259,
  228,
  314,
  263,
  231,
  269,
  233,
  281,
  235,
  283,
  237,
  238,
  271,
  273,
  324,
  328,
  243,
  244,
  337,
  246,
  247,
  345,
  367,
  250,
  369,
  252,
  253,
  355,
  729,
];
