import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:calendula/address_index.dart';
import 'package:calendula/calendar.dart';
import 'package:calendula/day_timeline.dart';
import 'package:calendula/event_journey.dart';
import 'package:calendula/event_place.dart';
import 'package:calendula/journey_preferences.dart';
import 'package:calendula/network_router.dart';
import 'package:calendula/schedule_csv.dart';
import 'package:calendula/schedule_import.dart';
import 'package:calendula/sync.dart';
import 'package:calendula/transit.dart';
import 'package:calendula/widget_snapshot.dart';
import 'package:calendula/main.dart';

import 'actions_test.dart' show MemoryRepository, reveal;

import 'csv_test.dart' show header;
import 'network_test.dart' show fixture;

class CountEngine extends NetworkEngine {
  int forward = 0, reverse = 0;
  @override
  Future<NetworkEndpointRoute?> routeEndpoints(
    List<NetworkEndpoint> origins,
    List<NetworkEndpoint> destinations,
    DateTime target, {
    bool arriveBy = true,
    LiveFeed? live,
    DateTime? now,
  }) {
    if (arriveBy) {
      reverse++;
    } else {
      forward++;
    }
    return super.routeEndpoints(
      origins,
      destinations,
      target,
      arriveBy: arriveBy,
      live: live,
      now: now,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  DateTime time(int h, int m) => tz.TZDateTime(prague, 2026, 10, 5, h, m);
  CalendarEvent event({
    String id = 'sis:p:one:2026-10-05',
    String room = 'S3',
    String address = '',
    String type = '',
    int originWalk = 0,
    int destWalk = 0,
  }) => CalendarEvent(
    id: id,
    title: 'Synthetic course',
    start: time(8, 40),
    end: time(10, 10),
    category: 'Study',
    room: room,
    address: address,
    sessionType: type,
    originStop: 'Alpha',
    destinationStop: 'Charlie',
    originWalkMinutes: originWalk,
    destinationWalkMinutes: destWalk,
    notes: 'SIS CSV · fixture',
  );
  CsvSchedule schedule([
    String extra = '',
    String values = '',
  ]) => CsvSchedule.decode(
    utf8.encode(
      '$header$extra\np;one;TEST;Synthetic course;1;520;S3;90;1;;14;;Teacher$values\n',
    ),
  );
  List<CalendarEvent> expand(
    CsvSchedule csv, {
    Map<String, CalendarEvent> details = const {},
    bool mff = true,
  }) => csv.expand(
    weekOneMonday: DateTime.utc(2026, 9, 28),
    from: DateTime.utc(2026, 10, 5),
    through: DateTime.utc(2026, 10, 18),
    meetingDetails: details,
    mffPlaces: mff,
  );

  test(
    'SIS imports get an exact public address/floor, but no invented class type',
    () {
      final events = expand(schedule());
      expect(events.first.address, 'Malostranské náměstí 2/25, Praha 1');
      expect(events.first.floor, '3');
      expect(events.first.sessionType, '');
      expect(events.first.locationSource, mffRoomSource);
      expect(eventDestination(event()), events.first.address);
      expect(effectiveEvent(event()).id, event().id);
      expect(effectiveEvent(event(room: 'S999')).address, '');
      expect(effectiveEvent(event(id: 'personal-room')).address, '');
      expect(effectiveEvent(expand(schedule(), mff: false).first).address, '');
      expect(enrichStudyPlace(event(room: 'SU2')).floor, 'Ground');
      expect(enrichStudyPlace(event(room: 'S6')).floor, '');
      expect(
        enrichStudyPlace(event(address: 'Confirmed custom address')).address,
        'Confirmed custom address',
      );
    },
  );

  test('Explicit Czech/English class types and confirmed series details survive future imports', () {
    final imported = expand(
      schedule(';type;address', ';cvičení;Testovací 100/2, Praha 6'),
    );
    expect(imported.first.sessionType, 'Practice');
    expect(imported.first.address, 'Testovací 100/2, Praha 6');
    final learned = reusableMeetingDetails([
      event(address: 'Confirmed address', type: 'Lecture'),
    ]);
    final reused = expand(schedule(), details: learned);
    expect(reused.first.address, 'Confirmed address');
    expect(reused.first.sessionType, 'Lecture');
    expect(
      expand(
        schedule(';type', ';Practice'),
        details: learned,
      ).first.sessionType,
      'Practice',
    );
    final conflicting = reusableMeetingDetails([
      event(address: 'A', type: 'Lecture'),
      event(id: 'sis:p:one:2026-10-12', address: 'B', type: 'Practice'),
    ]);
    expect(conflicting.values.single.address, '');
    expect(conflicting.values.single.sessionType, '');
    expect(sessionTypeFrom('přednáška'), 'Lecture');
    expect(explicitTitleType('Synthetic subject (lecture)'), 'Lecture');
    expect(explicitTitleType('Lecture about practice'), '');
    expect(
      CalendarEvent.fromJson(imported.first.toJson()).sessionType,
      'Practice',
    );
    final table = parseScheduleRows([
      ['Title', 'Date', 'Start', 'End', 'Type', 'Address'],
      ['Synthetic lesson', '2026-10-05', '08:40', '10:10', 'Lab', 'Test 1'],
    ]);
    expect(table.events.single.sessionType, 'Lab');
    expect(table.events.single.address, 'Test 1');
  });

  test(
    'New metadata merges with independent simultaneous edits through sync',
    () {
      final e = event(),
          base = SyncOperation('device_A_123456789', 1, e.id, {}, {
            '_alive': true,
            ...(e.toJson()..remove('id')),
          });
      final place = SyncOperation(
        'device_B_123456789',
        1,
        e.id,
        {base.actor: 1},
        {'address': 'Verified place', 'locationSource': 'User', '_alive': true},
      );
      final type = SyncOperation(
        'device_C_123456789',
        1,
        e.id,
        {base.actor: 1},
        {'sessionType': 'Practice', '_alive': true},
      );
      final document = SyncDocument(
        [type, place, base]
            .map(
              (op) =>
                  SyncOperation.fromJson(jsonDecode(jsonEncode(op.toJson()))),
            )
            .toList(),
      );
      expect(document.events().single.address, 'Verified place');
      expect(document.events().single.sessionType, 'Practice');
      expect(document.conflicts, isEmpty);
    },
  );

  late Directory temp;
  late CountEngine engine;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('calendula-event-plan-');
    final graph = fixture();
    graph['stops']['c'][2] = 50.1;
    graph['stops']['c'][3] = 14.1;
    graph['stops']['b'][2] = 50.05;
    final file = File('${temp.path}/network.gz');
    await file.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(graph))));
    engine = CountEngine();
    await engine.load(file.path);
  });
  tearDown(() async {
    engine.dispose();
    await temp.delete(recursive: true);
  });

  test('Address routes calculate both rows, include walks once and arrive ten minutes early', () async {
    final e = event(room: '', originWalk: 4, destWalk: 3);
    final plan = await planEventJourney(
      e,
      engine,
      null,
      const JourneyPreferences(mode: OriginMode.home, home: 'Alpha'),
      now: time(7, 30),
      includeDepartNow: true,
    );
    expect(plan.planned!.departure.isAtSameMomentAs(time(7, 56)), true);
    expect(plan.planned!.arrival.isAtSameMomentAs(time(8, 28)), true);
    expect(
      plan.planned!.arrival.isAfter(
        e.start.subtract(const Duration(minutes: 10)),
      ),
      false,
    );
    expect(plan.leaveLine(e), 'Leave 07:56 · 32 min');
    expect(plan.nowLine(e), contains('on time'));
    expect(engine.reverse, 1);
    expect(engine.forward, 1);
    final addresses = AddressIndex({
      'date': 'fixture',
      'addresses': [
        ['Malostranské náměstí', '2', '25', 50.1, 14.1, 'Praha 1'],
      ],
    });
    final addressPlan = await planEventJourney(
      event(),
      engine,
      addresses,
      const JourneyPreferences(mode: OriginMode.home, home: 'Alpha'),
      now: time(7, 30),
    );
    expect(addressPlan.planned, isNotNull);
    expect(addressPlan.planned!.legs.last.mode, -1);
    expect(addressPlan.planned!.legs.last.to, contains('Malostranské'));
  });

  test('Background snapshots never calculate leave-now; visible duplicate destinations share it', () async {
    final e = event(room: '');
    final later = CalendarEvent.fromJson({
      ...e.toJson(),
      'id': 'later',
      'start': time(9, 10).toUtc().toIso8601String(),
      'end': time(10, 40).toUtc().toIso8601String(),
    });
    final bg = await buildWidgetSnapshot(
      [e, later],
      null,
      routing: engine,
      addresses: AddressIndex({'date': 'fixture', 'addresses': []}),
      preferences: const JourneyPreferences(
        mode: OriginMode.home,
        home: 'Alpha',
      ),
      at: time(7, 30),
    );
    expect(engine.forward, 0);
    expect(bg.data['departNow'], '');
    expect(bg.data['leave'], startsWith('Leave 08:00'));
    final ui = await buildWidgetSnapshot(
      [e, later],
      null,
      routing: engine,
      addresses: AddressIndex({'date': 'fixture', 'addresses': []}),
      preferences: const JourneyPreferences(
        mode: OriginMode.home,
        home: 'Alpha',
      ),
      includeDepartNow: true,
      at: time(7, 30),
    );
    expect(engine.forward, 1);
    expect(ui.data['departNow'], contains('Leave now'));
    expect(ui.plans.length, 2);
  });

  test('Cancellation never becomes a future scheduled recommendation; stale predictions expire', () async {
    final e = event(room: '');
    final feed = LiveFeed(time(7, 30), {
      'ab|20261005': const TripPrediction(
        id: 'ab',
        serviceDate: '20261005',
        relationship: 3,
      ),
      'ac|20261005': const TripPrediction(
        id: 'ac',
        serviceDate: '20261005',
        relationship: 3,
      ),
    });
    final cancelled = await planEventJourney(
      e,
      engine,
      null,
      const JourneyPreferences(),
      now: time(7, 30),
      live: feed,
    );
    expect(cancelled.planned, isNull);
    expect(cancelled.leaveLine(e), 'No connection found');
    final stale = await planEventJourney(
      e,
      engine,
      null,
      const JourneyPreferences(),
      now: time(7, 34),
      live: feed,
    );
    expect(stale.planned, isNotNull);
    expect(stale.predicted, false);
    expect(stale.status, 'Scheduled connection');
    final missed = await planEventJourney(
      e,
      engine,
      null,
      const JourneyPreferences(),
      now: time(8, 20),
      includeDepartNow: true,
    );
    expect(missed.leaveLine(e), startsWith('Missed departure'));
  });

  test('Expired GPS requires an origin; adaptive plan cadence avoids extra HTTP work', () async {
    final e = CalendarEvent.fromJson({...event().toJson(), 'originStop': ''});
    final plan = await planEventJourney(
      e,
      engine,
      null,
      const JourneyPreferences(),
      now: time(7, 30),
      fix: OriginFix(
        50,
        14,
        20,
        time(7, 30).subtract(const Duration(hours: 13)),
      ),
    );
    expect(plan.planned, isNull);
    expect(plan.status, 'Set home or open the app for GPS');
    expect(planRefreshInterval([e], time(7, 30)), const Duration(minutes: 2));
    expect(planRefreshInterval([e], time(5, 30)), const Duration(minutes: 15));
  });

  test('Already at the venue produces a labelled short walk instead of no transit connection', () async {
    final samePlace = CalendarEvent.fromJson({
      ...event(room: '').toJson(),
      'originStop': 'Charlie',
    });
    final plan = await planEventJourney(
      samePlace,
      engine,
      null,
      const JourneyPreferences(),
      now: time(7, 30),
      includeDepartNow: true,
    );
    expect(plan.planned!.legs.single.mode, -1);
    expect(plan.planned!.departure.isAtSameMomentAs(time(8, 29)), true);
    expect(plan.status, 'Estimated walk');
    expect(plan.planned!.estimatedWalking, true);
    expect(plan.departNow!.arrival.isAtSameMomentAs(time(7, 31)), true);
  });

  testWidgets(
    'Current-time marker moves on the local day scale and disappears on another day',
    (tester) async {
      Widget timeline(DateTime now, DateTime day) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: DayTimeline(day: day, now: now, events: [event()]),
          ),
        ),
      );
      await tester.pumpWidget(timeline(time(8, 0), time(8, 0)));
      final first = tester
          .widget<Positioned>(find.byKey(const ValueKey('timeline-now')))
          .top!;
      await tester.pumpWidget(timeline(time(9, 0), time(8, 0)));
      expect(
        tester
            .widget<Positioned>(find.byKey(const ValueKey('timeline-now')))
            .top!,
        greaterThan(first),
      );
      await tester.pumpWidget(
        timeline(time(9, 0), time(8, 0).add(const Duration(days: 1))),
      );
      expect(find.byKey(const ValueKey('timeline-now')), findsNothing);
    },
  );
  testWidgets(
    'Editing class metadata can apply it to only the exact imported series',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = localNow();
      CalendarEvent lesson(
        String series,
        int days, {
        String type = '',
      }) => CalendarEvent(
        id: 'sis:fixture:$series:${dayKey(today.add(Duration(days: days)))}',
        title: 'Synthetic lesson',
        courseCode: 'TEST1234',
        category: 'Study',
        sessionType: type,
        room: 'S3',
        start: tz.TZDateTime(
          prague,
          today.year,
          today.month,
          today.day + days,
          10,
        ),
        end: tz.TZDateTime(
          prague,
          today.year,
          today.month,
          today.day + days,
          11,
        ),
        notes: 'SIS CSV · fixture',
      );
      final first = lesson('one', 0),
          next = lesson('one', 7),
          other = lesson('two', 2, type: 'Lecture');
      final repo = MemoryRepository([first, next, other]);
      await tester.pumpWidget(CalendulaApp(repository: repo, fetchLive: false));
      await tester.pumpAndSettle();
      final card = find.byKey(ValueKey('event:${first.id}:${dayKey(today)}'));
      await reveal(tester, card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Edit event'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit event'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Practice').last);
      await tester.pumpAndSettle();
      final series = find.text(
        'Apply place and class type to this meeting series',
      );
      await reveal(tester, series);
      await tester.tap(series);
      await reveal(tester, find.text('Save event'));
      await tester.tap(find.text('Save event'));
      await tester.pumpAndSettle();
      expect(
        repo.values
            .where((e) => meetingSeries(e.id) == meetingSeries(first.id))
            .every(
              (e) =>
                  e.sessionType == 'Practice' &&
                  e.address.isNotEmpty &&
                  e.floor == '3',
            ),
        true,
      );
      expect(
        repo.values.singleWhere((e) => e.id == other.id).sessionType,
        'Lecture',
      );
      expect(repo.values.singleWhere((e) => e.id == other.id).address, '');
      expect(repo.values.length, 3);
    },
  );
}
