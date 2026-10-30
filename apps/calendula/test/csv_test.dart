import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:calendula/calendar.dart';
import 'package:calendula/csv_import_page.dart';
import 'package:calendula/schedule_csv.dart';

const header =
    'id listku;id podlistku;kod predmetu;nazev;den(1=po);cas(min od 0:00);mistnost;delka(min);prvni tyden vyuky;prvni den vyuky pro jednorazovou;pocet tydnu vyuky;ctrnactideni vyuka;ucitele';
String csv(List<String> rows) => '$header\r\n${rows.join('\r\n')}\r\n';
CsvSchedule parse(List<String> rows) =>
    CsvSchedule.decode(utf8.encode(csv(rows)));
List<CalendarEvent> expand(
  CsvSchedule schedule, {
  DateTime? from,
  DateTime? through,
}) => schedule.expand(
  weekOneMonday: DateTime.utc(2026, 9, 28),
  from: from ?? DateTime.utc(2026, 10, 5),
  through: through ?? DateTime.utc(2026, 10, 18),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  test('Quoted fields, UTF-8 BOM and CP1250 preserve Czech characters', () {
    final s = CsvSchedule.decode(
      utf8.encode(
        '\uFEFF${csv(['p;one;TEST;"Žák; ""data""";1;550;S2;95;1;;14;;"Prof. A\nProf. B"'])}',
      ),
    );
    expect(s.rules.single.title, 'Žák; "data"');
    expect(s.rules.single.teachers, 'Prof. A\nProf. B');
    final raw = ascii
        .encode(csv(['p;one;TEST;TITLE;1;550;S2;95;1;;14;;']))
        .toList();
    final at = ascii.decode(raw).indexOf('TITLE');
    raw.replaceRange(at, at + 5, [0x8e, 0xe1, 0x6b, 0x20, 0xf8, 0xf9]);
    final cp = CsvSchedule.decode(raw);
    expect(cp.encoding, 'Windows-1250');
    expect(cp.rules.single.title, 'Žák řů');
  });
  test(
    'Meeting IDs, odd/even weeks and exact one-off dates remain separate',
    () {
      final s = parse([
        'p;one;TEST;Every week;1;550;S2;95;1;;14;;Teacher',
        'p;two;TEST;Even week;4;840;S6;90;2;;13;sude;',
        'p;three;TEST;Odd week;5;740;S1;90;1;;13;liche;',
        'p;four;TEST;Once;5;930;;170;;9.10.2026;1;;',
      ]);
      final events = expand(s);
      expect(events.length, 5);
      expect(
        events.where((e) => e.title == 'Even week').single.localStart.day,
        8,
      );
      expect(
        events.where((e) => e.title == 'Odd week').single.localStart.day,
        16,
      );
      final once = events.where((e) => e.title == 'Once').single;
      expect(clock(once.localStart), '15:30');
      expect(clock(once.localEnd), '18:20');
      expect(once.address, isEmpty);
      expect(once.floor, isEmpty);
      expect(events.map((e) => e.id).toSet().length, events.length);
      expect(expand(s).map((e) => e.id), events.map((e) => e.id));
      expect(CalendarEvent.fromJson(once.toJson()).courseCode, 'TEST');
      expect(
        s
            .expand(
              weekOneMonday: DateTime.utc(2026, 9, 28),
              from: DateTime.utc(2026, 10, 5),
              through: DateTime.utc(2026, 10, 18),
              selected: {'p/two'},
            )
            .single
            .title,
        'Even week',
      );
    },
  );
  test('Local wall times survive DST; touching events do not conflict', () {
    final s = parse(['p;one;TEST;Morning;1;550;;95;1;;14;;']);
    final e = expand(
      s,
      from: DateTime.utc(2026, 10, 19),
      through: DateTime.utc(2026, 11, 2),
    );
    expect(e.map((v) => clock(v.localStart)), ['09:10', '09:10', '09:10']);
    expect(e.first.start.hour, 7);
    expect(e.last.start.hour, 8);
    final later = CalendarEvent(
      id: 'later',
      title: 'Later',
      start: e.first.end,
      end: e.first.end.add(const Duration(minutes: 90)),
    );
    expect(overlaps(e.first, later), false);
    final conflict = CalendarEvent(
      id: 'conflict',
      title: 'Conflict',
      start: e.first.start.add(const Duration(minutes: 90)),
      end: e.first.end.add(const Duration(minutes: 90)),
    );
    expect(conflictIds([e.first, later, conflict]), {
      e.first.id,
      later.id,
      conflict.id,
    });
  });
  test(
    'Malformed rules reject the entire import rather than silently drop rows',
    () {
      for (final row in [
        'p;one;TEST;Bad;1;1440;;95;1;;14;;',
        'p;one;TEST;Bad;1;550;;95;1;;14;unknown;',
        'p;one;TEST;Bad;5;550;;95;;31.2.2026;1;;',
        'p;one;TEST;Bad;1;550;;95;;9.10.2026;1;;',
        'p;one;TEST;"Bad;1;550;;95;1;;14;;',
      ]) {
        expect(() => parse([row]), throwsFormatException);
      }
      expect(
        () => parse([
          'p;one;TEST;A;1;550;;95;1;;14;;',
          'p;one;TEST;B;2;550;;95;1;;14;;',
        ]),
        throwsFormatException,
      );
      final s = parse(['p;one;TEST;A;1;550;;95;1;;14;;']);
      expect(
        () => s.expand(
          weekOneMonday: DateTime.utc(2026, 9, 29),
          from: DateTime.utc(2026, 10, 5),
          through: DateTime.utc(2026, 10, 18),
        ),
        throwsFormatException,
      );
      expect(
        () => expand(s, through: DateTime.utc(2027, 1, 8)),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'Native file review commits the batch once and skips edited imported IDs',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final oneoff = DateTime.now().toUtc().add(const Duration(days: 7));
      final content = utf8.encode(
        csv([
          'p;one;TEST;A sample course;${oneoff.weekday};550;S2;95;;${oneoff.day}.${oneoff.month}.${oneoff.year};1;;',
        ]),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            importChannel,
            (call) async => {
              'name': 'synthetic.csv',
              'bytes': Uint8List.fromList(content),
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(importChannel, null),
      );
      List<CalendarEvent>? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: CsvImportPage(
            existing: const [],
            pickFile: () =>
                importChannel.invokeMapMethod<String, dynamic>('pickCsv'),
            commit: (events) async {
              saved = events;
              return true;
            },
          ),
        ),
      );
      await tester.tap(find.text('Choose CSV file'));
      await tester.pumpAndSettle();
      expect(find.text('Import 1 events'), findsOneWidget);
      await tester.tap(find.text('Import 1 events'));
      await tester.pumpAndSettle();
      expect(saved!.single.courseCode, 'TEST');
      expect(saved!.single.room, 'S2');
      final original = saved!.single;
      final edited = CalendarEvent(
        id: original.id,
        title: 'My edited course',
        start: original.start,
        end: original.end,
        address: 'My address',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: CsvImportPage(
            existing: [edited],
            pickFile: () =>
                importChannel.invokeMapMethod<String, dynamic>('pickCsv'),
            commit: (_) async {
              fail('Duplicate import must not commit or overwrite edits');
            },
          ),
        ),
      );
      await tester.tap(find.text('Choose CSV file'));
      await tester.pumpAndSettle();
      expect(find.text('Import 0 events'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Import 0 events'),
            )
            .onPressed,
        isNull,
      );
    },
  );
  final path = Platform.environment['CALENDULA_TEST_CSV'];
  if (path != null) {
    test(
      'Optional local CSV preserves source meeting times and identities',
      () {
        final schedule = CsvSchedule.decode(File(path).readAsBytesSync());
        expect(schedule.rules, isNotEmpty);
        final events = expand(schedule);
        expect(events, isNotEmpty);
        for (final event in events) {
          final parts = event.id.split(':');
          final rule = schedule.rules.singleWhere(
            (r) =>
                r.parentId == Uri.decodeComponent(parts[1]) &&
                r.id == Uri.decodeComponent(parts[2]),
          );
          expect(
            event.localStart.hour * 60 + event.localStart.minute,
            rule.minute,
          );
          expect(event.end.difference(event.start).inMinutes, rule.duration);
          expect(event.room, rule.room);
          expect(event.title, rule.title);
          if (rule.once != null) {
            expect(dayKey(event.localStart), dayKey(rule.once!));
          }
        }
        expect(events.map((e) => e.id).toSet().length, events.length);
        expect(expand(schedule).map((e) => e.id), events.map((e) => e.id));
      },
    );
  }
}
