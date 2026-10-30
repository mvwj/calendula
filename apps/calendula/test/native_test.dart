import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:calendula/calendar.dart';
import 'package:calendula/editor.dart';
import 'package:calendula/main.dart';
import 'package:calendula/transit.dart';

class MemoryEvents implements EventRepository {
  List<CalendarEvent> values = [];
  @override
  Future<List<CalendarEvent>> load() async => values;
  @override
  Future<void> save(List<CalendarEvent> events) async {
    values = events;
  }
}

List<int> varint(int value) {
  var b = BigInt.from(value);
  if (value < 0) {
    b += BigInt.one << 64;
  }
  final bytes = <int>[];
  do {
    final v = (b & BigInt.from(127)).toInt();
    b >>= 7;
    bytes.add(v | (b > BigInt.zero ? 128 : 0));
  } while (b > BigInt.zero);
  return bytes;
}

List<int> number(int key, int value) => [...varint(key << 3), ...varint(value)];
List<int> bytes(int key, List<int> value) => [
  ...varint((key << 3) | 2),
  ...varint(value.length),
  ...value,
];
List<int> str(int key, String value) => bytes(key, utf8.encode(value));
Uint8List fixture({
  int delay = -30,
  int relationship = 0,
  int incrementality = 0,
}) {
  final header = [
    ...str(1, '2.0'),
    ...number(2, incrementality),
    ...number(3, 1791054000),
  ];
  final descriptor = [
    ...str(1, 'test-trip'),
    ...str(3, '20261003'),
    ...number(4, relationship),
  ];
  final stop = [
    ...number(1, 1),
    ...bytes(2, number(1, delay)),
    ...str(4, 'stop-a'),
  ];
  final update = [...bytes(1, descriptor), ...bytes(2, stop)];
  return Uint8List.fromList([
    ...bytes(1, header),
    ...bytes(2, [...str(1, 'entity'), ...bytes(3, update)]),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  test('GTFS-RT signed early running and cancelled trip remain distinct', () {
    final feed = LiveFeed.decode(fixture());
    expect(feed.trips.values.single.stops.single.arrivalDelay, -30);
    expect(feed.delayed, 0);
    expect(LiveFeed.decode(fixture(delay: 120)).delayed, 1);
    expect(
      LiveFeed.decode(fixture(relationship: 3)).trips.values.single.cancelled,
      true,
    );
    expect(feed.fresh(feed.generated.add(const Duration(minutes: 4))), false);
    expect(
      feed.fresh(feed.generated.subtract(const Duration(minutes: 1))),
      false,
    );
  });
  test('Malformed and differential live feeds are rejected', () {
    expect(
      () => LiveFeed.decode(Uint8List.fromList([10, 127, 1])),
      throwsFormatException,
    );
    expect(
      () => LiveFeed.decode(fixture(incrementality: 1)),
      throwsFormatException,
    );
    expect(
      () => LiveFeed.decode(Uint8List(8 * 1024 * 1024 + 1)),
      throwsFormatException,
    );
  });
  test('Invitation import validates dates, UTC, recurrence and DST', () {
    final e = parseInvitation(
      'Title: Cinema\nDate: 2026-10-04\nStart: 18:30\nEnd: 20:30\nRoom: 2',
    );
    expect(clock(e.localStart), '18:30');
    expect(e.room, '2');
    expect(
      () => parseInvitation(
        'Title: X\nDate: 2026-02-31\nStart: 10:00\nEnd: 11:00',
      ),
      throwsFormatException,
    );
    expect(
      () =>
          wallTime(DateTime(2026, 3, 29), const TimeOfDay(hour: 2, minute: 30)),
      throwsFormatException,
    );
    expect(
      () => wallTime(
        DateTime(2026, 10, 25),
        const TimeOfDay(hour: 2, minute: 30),
      ),
      throwsFormatException,
    );
    final ics =
        'BEGIN:VEVENT\nSUMMARY:Film\nDTSTART:20261004T163000Z\nDTEND:20261004T183000Z\nEND:VEVENT';
    expect(clock(parseInvitation(ics).localStart), '18:30');
    expect(
      () => parseInvitation(
        ics.replaceFirst('SUMMARY:Film', 'SUMMARY:Film\nRRULE:FREQ=DAILY'),
      ),
      throwsFormatException,
    );
  });
  test('Real PID asset reproduces the inspected scheduled fixture and rejects expired dates', () async {
    final index = await MetroIndex.load();
    final route = index.arriveBy(
      'Dejvická',
      'Muzeum',
      tz.TZDateTime(prague, 2026, 10, 3, 10),
    );
    expect(route, isNotNull);
    expect(clock(route!.departure), '09:51');
    expect(route.arrival.second, 10);
    expect(route.tripId, '991_12117_260207');
    expect(route.updated, false);
    expect(
      () => index.arriveBy(
        'Dejvická',
        'Muzeum',
        tz.TZDateTime(prague, 2026, 10, 17, 10),
      ),
      throwsStateError,
    );
  });
  test(
    'Fresh predictions alter arrive-by selection, cancellation removes a trip',
    () {
      final index = MetroIndex(
        '2026-10-03',
        '2026-10-04',
        {'a': 'A', 'b': 'B'},
        [
          [
            't',
            'A',
            'B',
            3,
            [
              ['a', 1, 36000, 36000, 0, 0],
              ['b', 2, 36600, 36600, 0, 0],
            ],
          ],
        ],
      );
      final now = tz.TZDateTime(prague, 2026, 10, 3, 9, 50),
          target = tz.TZDateTime(prague, 2026, 10, 3, 10, 11);
      final delayed = LiveFeed(now.toUtc(), {
        't|20261003': const TripPrediction(
          id: 't',
          serviceDate: '20261003',
          stops: [
            StopPrediction(sequence: 1, departureDelay: 120),
            StopPrediction(sequence: 2, arrivalDelay: 120),
          ],
        ),
      });
      expect(index.arriveBy('A', 'B', target, live: delayed, now: now), null);
      final cancelled = LiveFeed(now.toUtc(), {
        't|20261003': const TripPrediction(
          id: 't',
          serviceDate: '20261003',
          relationship: 3,
        ),
      });
      expect(index.arriveBy('A', 'B', target, live: cancelled, now: now), null);
      expect(
        index.arriveBy(
          'A',
          'B',
          tz.TZDateTime(prague, 2026, 10, 4, 10, 11),
          live: cancelled,
          now: now,
        ),
        isNotNull,
      );
    },
  );
  test('Vault survives restart, authenticates data and never writes clear event text', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('calendula-test-');
    try {
      final repo = EncryptedEventRepository(directory: () async => dir);
      final e = demoEvents(DateTime(2026, 10, 3)).first;
      await repo.save([e]);
      final file = File('${dir.path}/calendar.vault');
      expect(await file.readAsString(), isNot(contains(e.title)));
      final again = EncryptedEventRepository(directory: () async => dir);
      expect((await again.load()).single.title, e.title);
      final data = jsonDecode(await file.readAsString());
      data['mac'] = base64Encode(List.filled(16, 0));
      await file.writeAsString(jsonEncode(data));
      await expectLater(again.load(), throwsA(anything));
      FlutterSecureStorage.setMockInitialValues({});
      await expectLater(
        EncryptedEventRepository(directory: () async => dir).load(),
        throwsStateError,
      );
      expect(await file.exists(), true);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  testWidgets('Native calendar creates and reopens an event at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = MemoryEvents();
    await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
    await tester.pumpAndSettle();
    expect(find.text('calendula'), findsOneWidget);
    await tester.tap(find.text('New event'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Native test event',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save event'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save event'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save event'));
    await tester.pumpAndSettle();
    expect(repo.values.single.title, 'Native test event');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
    await tester.pumpAndSettle();
    expect(find.text('Native test event'), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox());
  });
  final publicFeed = Platform.environment['TRANSIT_FEED_FILE'];
  if (publicFeed != null) {
    test('Actual downloaded public PID protobuf decodes', () async {
      final feed = LiveFeed.decode(await File(publicFeed).readAsBytes());
      expect(feed.trips.length, greaterThan(100));
      final index = await MetroIndex.load();
      final ids = index.trips.map((t) => t[0]).toSet();
      final matching = feed.trips.values
          .where((t) => ids.contains(t.id))
          .length;
      // ignore: avoid_print -- Only aggregate public fixture metadata is printed.
      print(
        'PUBLIC FEED: ${feed.trips.length} updates; ${feed.delayed} delayed; $matching metro trip IDs matched; ${feed.generated.toIso8601String()}',
      );
    });
  }
}
