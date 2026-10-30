import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:calendula/schedule_import.dart';
import 'package:calendula/import_review_page.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  final from = DateTime(2026, 10, 1), through = DateTime(2026, 10, 31);
  test('Weekly ICS exceptions and moved occurrence retain stable identity', () {
    const source = '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:lecture
SUMMARY:Lecture
DTSTART;TZID=Europe/Prague:20260928T100000
DTEND;TZID=Europe/Prague:20260928T113000
RRULE:FREQ=WEEKLY;COUNT=6;BYDAY=MO
EXDATE;TZID=Europe/Prague:20261012T100000
LOCATION:Campus\\, Prague
END:VEVENT
BEGIN:VEVENT
UID:lecture
RECURRENCE-ID;TZID=Europe/Prague:20261019T100000
SUMMARY:Moved lecture
DTSTART;TZID=Europe/Prague:20261020T120000
DTEND;TZID=Europe/Prague:20261020T133000
END:VEVENT
END:VCALENDAR''';
    final batch = parseIcs(source, from: from, through: through);
    expect(batch.warnings, isEmpty);
    expect(batch.events.length, 3);
    expect(batch.events.map((e) => e.localStart.day), [5, 20, 26]);
    expect(batch.events.last.localStart.hour, 10);
    expect(
      batch.events.last.start.hour,
      9,
    ); // DST changed, wall time is stable.
    expect(batch.events.first.venue, 'Campus, Prague');
    expect(
      parseIcs(source, from: from, through: through).events.map((e) => e.id),
      batch.events.map((e) => e.id),
    );
  });
  test('Cancelled invitation is warning and unsupported recurrence is never flattened', () {
    final batch = parseIcs(
      '''BEGIN:VEVENT
UID:x
SUMMARY:Cancelled
DTSTART:20261005T100000Z
STATUS:CANCELLED
END:VEVENT
BEGIN:VEVENT
UID:y
SUMMARY:Monthly
DTSTART:20261005T100000Z
DTEND:20261005T110000Z
RRULE:FREQ=MONTHLY
END:VEVENT''',
      from: from,
      through: through,
    );
    expect(batch.events, isEmpty);
    expect(batch.warnings.length, 2);
  });
  test('All-day ICS uses exclusive end and refuses invalid dates', () {
    final good = parseIcs(
      '''BEGIN:VEVENT
SUMMARY:Day off
UID:day
DTSTART;VALUE=DATE:20261005
DTEND;VALUE=DATE:20261006
END:VEVENT''',
      from: from,
      through: through,
    );
    expect(good.events.single.allDay, isTrue);
    expect(good.events.single.localEnd.day, 6);
    expect(() => strictDate('2026-02-30'), throwsFormatException);
    expect(
      () => strictWall(DateTime(2026, 3, 29), '02:30'),
      throwsFormatException,
    );
  });
  test(
    'XLSX handles shared strings, sparse cells and dates without network',
    () {
      final archive = Archive();
      void add(String name, String value) {
        final bytes = utf8.encode(value);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add(
        'xl/sharedStrings.xml',
        '<sst><si><t>Title</t></si><si><t>Date</t></si><si><t>Start</t></si><si><t>End</t></si><si><t>Cinema</t></si></sst>',
      );
      add(
        'xl/worksheets/sheet1.xml',
        '<worksheet><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row><row><c r="A2" t="s"><v>4</v></c><c r="B2" t="inlineStr"><is><t>2026-10-05</t></is></c><c r="C2"><v>0.75</v></c><c r="D2"><v>0.8333333333333</v></c></row></sheetData></worksheet>',
      );
      final rows = readXlsx(Uint8List.fromList(ZipEncoder().encode(archive)));
      final e = parseScheduleRows(rows).events.single;
      expect(e.title, 'Cinema');
      expect(e.localStart.hour, 18);
      expect(e.localEnd.hour, 20);
    },
  );
  test('Natural text uses explicit years and structured CSV quoted cells', () {
    final text = recognizeText('Cinema 5.10.2026 18:30–20:30 | Kino');
    expect(text.events.single.venue, 'Kino');
    expect(recognizeText('Cinema tomorrow 18:30–20:30').events, isEmpty);
    expect(
      parseDelimited(
        'Title,Date,Start,End\n"Cinema, film",2026-10-05,18:00,20:00',
        ',',
      ).last.first,
      'Cinema, film',
    );
  });
  test('Labelled mail text preserves room, address and floor', () {
    final e = recognizeText(
      'Subject: Seminar\nDate: 2026-10-05\nStart: 10:00\nEnd: 11:30\nRoom: S3\nFloor: 2\nAddress: Prague',
    ).events.single;
    expect(e.title, 'Seminar');
    expect(e.room, 'S3');
    expect(e.floor, '2');
    expect(e.address, 'Prague');
  });
  test('Foreign timezone recurrence remains in its source timezone across Prague DST', () {
    final batch = parseIcs(
      '''BEGIN:VEVENT
UID:foreign
SUMMARY:Remote meeting
DTSTART;TZID=America/New_York:20261019T100000
DTEND;TZID=America/New_York:20261019T110000
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT''',
      from: DateTime(2026, 10, 1),
      through: DateTime(2026, 11, 5),
    );
    expect(batch.warnings, isEmpty);
    expect(batch.events.map((e) => e.start.hour), [14, 14, 15]);
    expect(batch.events.map((e) => e.localStart.hour), [16, 15, 16]);
  });
}
