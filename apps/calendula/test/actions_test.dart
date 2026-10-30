import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:calendula/calendar.dart';
import 'package:calendula/main.dart';
import 'package:calendula/journey_preferences.dart';
import 'package:calendula/refresh_policy.dart';
import 'package:calendula/timetable_store.dart';
import 'package:calendula/transit.dart';
import 'package:calendula/network_planner_page.dart';

class MemoryRepository implements EventRepository {
  List<CalendarEvent> values;
  MemoryRepository(this.values);
  @override
  Future<List<CalendarEvent>> load() async => values;
  @override
  Future<void> save(List<CalendarEvent> next) async {
    values = next;
  }
}

CalendarEvent event(
  String id,
  DateTime day,
  int hour, {
  int minutes = 90,
  int travel = 0,
}) => CalendarEvent(
  id: id,
  title: 'Course $id',
  start: tz.TZDateTime(prague, day.year, day.month, day.day, hour).toUtc(),
  end: tz.TZDateTime(
    prague,
    day.year,
    day.month,
    day.day,
    hour,
  ).add(Duration(minutes: minutes)).toUtc(),
  travelMinutes: travel,
);
Future<void> reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    250,
    scrollable: find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

List<int> tinyGtfs() {
  final tables = {
    'feed_info.txt': 'feed_start_date,feed_end_date\n20261003,20261004\n',
    'stops.txt': 'stop_id,stop_name,stop_lat,stop_lon\na,Alpha,50.0,14.0\nb,Beta,50.1,14.1\n',
    'routes.txt': 'route_id,route_short_name,route_type\nr,A,1\n',
    'trips.txt': 'route_id,service_id,trip_id,trip_headsign\nr,s,t,Beta\n',
    'calendar.txt': 'service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\ns,1,1,1,1,1,1,1,20261003,20261004\n',
    'calendar_dates.txt': 'service_id,date,exception_type\ns,20261004,2\n',
    'stop_times.txt': 'trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type\nt,10:00:00,10:00:00,a,1,0,0\nt,10:10:00,10:10:00,b,2,0,0\n',
    '../unrelated.txt': 'must never be extracted',
  };
  final archive = Archive();
  for (final t in tables.entries) {
    final bytes = utf8.encode(t.value);
    archive.addFile(ArchiveFile(t.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  test('A downloaded public ZIP can rebuild the index locally without another HTTP request', () async {
    final root = await Directory.systemTemp.createTemp(
      'calendula-cache-index-',
    );
    try {
      final zip = File('${root.path}/native-cache.zip');
      await zip.writeAsBytes(tinyGtfs());
      final store = TimetableStore(
        directory: () async => root,
        client: () => CachedTimetableClient(zip),
      );
      final next = await store.update(
        DateTime.utc(2026, 10, 3, 12),
        MetroIndex('2026-10-03', '2026-10-04', {'a': 'Alpha', 'b': 'Beta'}, []),
      );
      expect(next.stops.values, containsAll(['Alpha', 'Beta']));
      expect(
        await File('${root.path}/public-network.json.gz').exists(),
        isTrue,
      );
      expect(await zip.exists(), isTrue);
      final fileClient = CachedTimetableClient(zip);
      await expectLater(
        fileClient.send(
          http.Request('GET', Uri.parse('https://other.invalid/')),
        ),
        throwsFormatException,
      );
      fileClient.close();
    } finally {
      await root.delete(recursive: true);
    }
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  test(
    'Day boundary includes overnight events and excludes the next occurrence',
    () {
      final day = DateTime.utc(2026, 10, 25),
          overnight = event(
            'overnight',
            DateTime.utc(2026, 10, 24),
            23,
            minutes: 180,
          ),
          next = event('next', DateTime.utc(2026, 10, 26), 0);
      expect(eventsOnDay([overnight, next], day).map((e) => e.id), [
        'overnight',
      ]);
      expect(eventsOnDay([overnight], DateTime.utc(2026, 10, 26)), isEmpty);
    },
  );
  testWidgets(
    'Long press deletes one occurrence or one day, supports cancel and Undo',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = localNow(),
          one = event('one', today, 9),
          two = event('two', today, 11),
          next = event(
            'next',
            DateTime.utc(today.year, today.month, today.day + 7),
            9,
          );
      final repo = MemoryRepository([one, two, next]);
      await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
      await tester.pumpAndSettle();
      final first = find.byKey(ValueKey('event:one:${dayKey(today)}'));
      await reveal(tester, first);
      await tester.longPress(first);
      await tester.pumpAndSettle();
      expect(find.text('Only this occurrence'), findsOneWidget);
      await tester.tap(find.text('Delete this event'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(repo.values.length, 3);
      await tester.longPress(first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete this event'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(repo.values.map((e) => e.id), ['two', 'next']);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(repo.values.map((e) => e.id).toSet(), {'one', 'two', 'next'});
      await reveal(tester, first);
      await tester.longPress(first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete all events on this day'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep events'));
      await tester.pumpAndSettle();
      expect(repo.values.length, 3);
      await tester.longPress(first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete all events on this day'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete day'));
      await tester.pumpAndSettle();
      expect(repo.values.single.id, 'next');
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(repo.values.length, 3);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
      await tester.pumpAndSettle();
      expect(repo.values.length, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('Similar event periods use local start dates across DST and week boundaries', () {
    CalendarEvent named(
      String id,
      DateTime day,
      int hour, {
      int minutes = 90,
      String title = '  Weekly   Course  ',
    }) => CalendarEvent.fromJson({
      ...event(id, day, hour, minutes: minutes).toJson(),
      'title': title,
    });
    final anchor = named('anchor', DateTime.utc(2026, 10, 25), 10);
    final week = EventDatePeriod.weekOf(anchor.localStart);
    expect(dayKey(week.firstDate), '2026-10-19');
    expect(dayKey(week.lastDate), '2026-10-25');
    final values = [
      named('previous', DateTime.utc(2026, 10, 18), 23, minutes: 180),
      named('monday', DateTime.utc(2026, 10, 19), 0, title: 'weekly course'),
      anchor,
      named('late-sunday', DateTime.utc(2026, 10, 25), 23, minutes: 180),
      named('next', DateTime.utc(2026, 10, 26), 0),
      named(
        'partial',
        DateTime.utc(2026, 10, 25),
        12,
        title: 'Weekly Course tutorial',
      ),
    ];
    expect(similarEventsInPeriod(values, anchor, week).map((e) => e.id), [
      'monday',
      'anchor',
      'late-sunday',
    ]);
  });
  test('Month and custom deletion ranges are inclusive and exclude unrelated titles', () {
    CalendarEvent named(
      String id,
      int month,
      int day, {
      String title = 'Résumé seminar',
    }) => CalendarEvent.fromJson({
      ...event(id, DateTime.utc(2026, month, day), 10).toJson(),
      'title': title,
    });
    final anchor = named('anchor', 10, 20);
    final values = [
      named('before', 9, 30),
      named('first', 10, 1),
      anchor,
      named('last', 10, 31, title: '  RÉSUMÉ seminar '),
      named('after', 11, 1),
      named('different', 10, 20, title: 'Resume seminar'),
    ];
    expect(
      similarEventsInPeriod(
        values,
        anchor,
        EventDatePeriod.monthOf(anchor.localStart),
      ).map((e) => e.id),
      ['first', 'anchor', 'last'],
    );
    expect(
      similarEventsInPeriod(
        values,
        anchor,
        EventDatePeriod(DateTime.utc(2026, 10, 20), DateTime.utc(2026, 10, 31)),
      ).map((e) => e.id),
      ['anchor', 'last'],
    );
    expect(
      similarEventsInPeriod(
        values,
        anchor,
        EventDatePeriod(DateTime.utc(2026, 11, 2), DateTime.utc(2026, 11, 3)),
      ),
      isEmpty,
    );
    expect(
      () =>
          EventDatePeriod(DateTime.utc(2026, 10, 2), DateTime.utc(2026, 10, 1)),
      throwsArgumentError,
    );
  });
  testWidgets(
    'Similar week deletion requires confirmation, preserves other events and supports Undo',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = localNow(), week = EventDatePeriod.weekOf(today);
      CalendarEvent named(String id, DateTime day, String title) =>
          CalendarEvent.fromJson({
            ...event(id, day, 9).toJson(),
            'title': title,
          });
      final one = named('similar-one', today, 'Weekly Course'),
          two = named('similar-two', week.firstDate, ' weekly   course '),
          next = named(
            'similar-next',
            week.lastDate.add(const Duration(days: 1)),
            'Weekly Course',
          ),
          other = named('unrelated', today, 'Weekly Course tutorial');
      final repo = MemoryRepository([one, two, next, other]);
      await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
      await tester.pumpAndSettle();
      final card = find.byKey(ValueKey('event:similar-one:${dayKey(today)}'));
      Future<void> chooseWeek() async {
        await reveal(tester, card);
        await tester.longPress(card);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete similar events'));
        await tester.pumpAndSettle();
        await tester.tap(find.text("This event's week"));
        await tester.pumpAndSettle();
      }

      await chooseWeek();
      expect(find.text('Delete 2 similar events?'), findsOneWidget);
      await tester.tap(find.text('Keep events'));
      await tester.pumpAndSettle();
      expect(repo.values.length, 4);
      await chooseWeek();
      await tester.tap(find.text('Delete matches'));
      await tester.pumpAndSettle();
      expect(repo.values.map((e) => e.id).toSet(), {
        'similar-next',
        'unrelated',
      });
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(repo.values.map((e) => e.id).toSet(), {
        'similar-one',
        'similar-two',
        'similar-next',
        'unrelated',
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Similar month deletion persists and custom date cancellation keeps the calendar',
    (tester) async {
      final today = localNow(), month = EventDatePeriod.monthOf(today);
      CalendarEvent named(String id, DateTime day, String title) =>
          CalendarEvent.fromJson({
            ...event(id, day, 9).toJson(),
            'title': title,
          });
      final repo = MemoryRepository([
        named('month-one', today, 'Film night'),
        named('month-two', month.firstDate, 'FILM NIGHT'),
        named(
          'month-next',
          month.lastDate.add(const Duration(days: 1)),
          'Film night',
        ),
        named('month-other', today, 'Film night with friends'),
      ]);
      await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
      await tester.pumpAndSettle();
      final card = find.byKey(ValueKey('event:month-one:${dayKey(today)}'));
      Future<void> openPeriods() async {
        await reveal(tester, card);
        await tester.longPress(card);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete similar events'));
        await tester.pumpAndSettle();
      }

      await openPeriods();
      await tester.tap(find.text('Choose dates'));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop();
      await tester.pumpAndSettle();
      expect(repo.values.length, 4);
      await openPeriods();
      await tester.tap(find.text("This event's month"));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 similar events?'), findsOneWidget);
      await tester.tap(find.text('Delete matches'));
      await tester.pumpAndSettle();
      expect(repo.values.map((e) => e.id).toSet(), {
        'month-next',
        'month-other',
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
      await tester.pumpAndSettle();
      expect(repo.values.map((e) => e.id).toSet(), {
        'month-next',
        'month-other',
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('Deleting the last event keeps an empty calendar after restart', (
    tester,
  ) async {
    final day = localNow(),
        repo = MemoryRepository([event('last', localNow(), 9)]);
    await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('event:last:${dayKey(day)}'));
    await reveal(tester, card);
    await tester.longPress(card);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete this event'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(repo.values, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('0 events'));
    expect(find.text('0 events'), findsOneWidget);
    expect(find.text('Sample day · manual travel'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'Transport card opens full connection planner with buffered arrival time',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({});
      final e = event('trip', localNow(), 14, travel: 30);
      final ready = Completer<MetroIndex>();
      await tester.pumpWidget(
        CalendulaApp(
          repository: MemoryRepository([e]),
          fetchLive: false,
          loadTimetable: () => ready.future,
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('journey:trip'));
      await reveal(tester, card);
      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final opened = tester.widget<NetworkPlannerPage>(
        find.byType(NetworkPlannerPage),
      );
      expect(clock(opened.initialArrival!), '13:50');
      expect(find.text('The whole connection'), findsOneWidget);
      ready.complete(
        MetroIndex('2026-10-03', '2026-10-16', {
          'a': 'Dejvická',
          'b': 'Muzeum',
        }, []),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('Protected journey settings keep home and other address without GPS history', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const store = JourneyPreferenceStore();
    await store.save(
      const JourneyPreferences(
        mode: OriginMode.other,
        home: 'A test address',
        other: 'Another test address',
      ),
    );
    final loaded = await store.load();
    expect(loaded.mode, OriginMode.other);
    expect(loaded.home, 'A test address');
    expect(loaded.address, 'Another test address');
    expect(loaded.toJson().keys.toSet(), {'mode', 'home', 'other'});
  });
  test('Refresh throttling honors Retry-After, exponential backoff and access denial', () {
    final now = DateTime.utc(2026, 10, 3, 12), policy = RefreshPolicy();
    policy.start(now);
    expect(policy.canStart(now.add(const Duration(seconds: 29))), false);
    policy.fail(
      now,
      const TransitRequestError(429, retryAfter: Duration(seconds: 120)),
    );
    expect(policy.waitAt(now), const Duration(seconds: 120));
    expect(policy.canStart(now.add(const Duration(seconds: 121))), true);
    expect(parseRetryAfter('120', now), const Duration(seconds: 120));
    expect(
      parseRetryAfter(
        HttpDate.format(now.add(const Duration(minutes: 3))),
        now,
      ),
      const Duration(minutes: 3),
    );
    policy.success();
    policy.start(now);
    policy.fail(now, const TransitRequestError(403));
    expect(policy.waitAt(now), const Duration(hours: 24));
  });
  test('Public timetable update validates calendar exceptions and keeps prior cache on failure', () async {
    final root = await Directory.systemTemp.createTemp(
      'calendula-public-test-',
    );
    try {
      var calls = 0;
      final store = TimetableStore(
        directory: () async => root,
        client: () => MockClient((request) async {
          expect(request.url, TimetableStore.endpoint);
          expect(request.url.query, isEmpty);
          calls++;
          return calls == 1
              ? http.Response.bytes(
                  tinyGtfs(),
                  200,
                  headers: {'etag': 'public-v1'},
                )
              : http.Response('Unavailable', 503);
        }),
      );
      final old = MetroIndex(
        '2026-10-03',
        '2026-10-04',
        {'a': 'Alpha', 'b': 'Beta'},
        [
          [
            'old',
            'A',
            'Beta',
            3,
            [
              ['a', 1, 36000, 36000, 0, 0],
              ['b', 2, 36600, 36600, 0, 0],
            ],
          ],
        ],
      );
      final next = await store.update(DateTime.utc(2026, 10, 3, 12), old);
      expect(
        next.arriveBy(
          'Alpha',
          'Beta',
          tz.TZDateTime(prague, 2026, 10, 3, 10, 15),
        ),
        isNotNull,
      );
      expect(
        next.arriveBy(
          'Alpha',
          'Beta',
          tz.TZDateTime(prague, 2026, 10, 4, 10, 15),
        ),
        isNull,
      );
      expect(await File('${root.path}/unrelated.txt').exists(), false);
      expect(await store.due(DateTime.utc(2026, 10, 3, 15), next), false);
      await expectLater(
        store.update(DateTime.utc(2026, 10, 4, 12), next),
        throwsA(isA<TransitRequestError>()),
      );
      expect((await store.load()).trips.single[0], 't');
      expect(await store.due(DateTime.utc(2026, 10, 4, 12, 10), next), false);
    } finally {
      if (!root.absolute.path.startsWith(Directory.systemTemp.absolute.path)) {
        throw StateError('Invalid temporary path');
      }
      await root.delete(recursive: true);
    }
  });
  final path = Platform.environment['PID_GTFS_FILE'];
  if (path != null) {
    test('Actual full public PID archive builds the same bounded native metro routes', () async {
      final root = await Directory.systemTemp.createTemp(
        'calendula-public-gtfs-',
      );
      final timer = Stopwatch()..start();
      try {
        final data = buildMetroIndex(path, root.path),
            index = MetroIndex.fromJson(data);
        expect(index.trips.length, 2602);
        expect(index.stops.length, 120);
        final route = index.arriveBy(
          'Dejvická',
          'Muzeum',
          tz.TZDateTime(prague, 2026, 10, 3, 10),
        );
        expect(route!.tripId, '991_12117_260207');
        expect(clock(route.departure), '09:51');
        // ignore: avoid_print -- aggregate public-data performance only.
        print(
          'PUBLIC INDEX: ${index.trips.length} trips in ${timer.elapsedMilliseconds} ms',
        );
      } finally {
        if (!root.absolute.path.startsWith(
          Directory.systemTemp.absolute.path,
        )) {
          throw StateError('Invalid temporary path');
        }
        await root.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
