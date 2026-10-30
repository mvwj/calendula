// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:calendula/calendar.dart';
import 'package:calendula/network_router.dart';
import 'package:calendula/timetable_store.dart';
import 'package:calendula/transit.dart';

Map<String, dynamic> fixture() => {
  'start': '2026-10-04',
  'end': '2026-10-06',
  'stops': {
    for (final (id, name) in [('a', 'Alpha'), ('b', 'Bravo'), ('c', 'Charlie')])
      id: [name, '', 50.0, 14.0, '', 0],
  },
  'trips': [
    [
      'ab',
      '12',
      'Bravo',
      7,
      [
        ['a', 1, 8 * 3600, 8 * 3600, 0, 0],
        ['b', 2, 8 * 3600 + 600, 8 * 3600 + 600, 0, 0],
      ],
      0,
      '',
    ],
    [
      'bc',
      'C',
      'Charlie',
      7,
      [
        ['b', 1, 8 * 3600 + 840, 8 * 3600 + 840, 0, 0],
        ['c', 2, 8 * 3600 + 1500, 8 * 3600 + 1500, 0, 0],
      ],
      1,
      '',
    ],
    [
      'ac',
      '100',
      'Charlie',
      7,
      [
        ['a', 1, 8 * 3600 - 120, 8 * 3600 - 120, 0, 0],
        ['c', 2, 8 * 3600 + 1740, 8 * 3600 + 1740, 0, 0],
      ],
      3,
      '',
    ],
  ],
  'transfers': [],
  'pathways': [],
};

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test('closing a planner during startup releases its pending load', () async {
    final dir = await Directory.systemTemp.createTemp('calendula-engine-');
    try {
      final file = File('${dir.path}/network.gz');
      await file.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(fixture()))));
      final engine = NetworkEngine();
      final pending = engine.load(file.path);
      engine.dispose();
      await expectLater(
        pending.timeout(const Duration(seconds: 5)),
        throwsStateError,
      );
      await expectLater(engine.load(file.path), throwsStateError);
    } finally {
      await File('${dir.path}/network.gz').delete();
      await dir.delete();
    }
  });
  DateTime time(int hour, int minute) =>
      tz.TZDateTime(prague, 2026, 10, 5, hour, minute);
  final now = DateTime.utc(2026, 10, 5, 5, 30);
  test('One graph pass compares endpoint choices and keeps live cancellations and freshness', () {
    final index = NetworkIndex(fixture());
    final latest = index.routeChoices(
      'Charlie',
      ['Alpha', 'Bravo'],
      time(8, 30),
      now: now,
    );
    expect(latest['Alpha']!.legs.map((leg) => leg.tripId), ['ab', 'bc']);
    expect(latest['Bravo']!.legs.map((leg) => leg.tripId), ['bc']);
    final earliest = index.routeChoices(
      'Alpha',
      ['Bravo', 'Charlie'],
      time(8, 0),
      now: now,
      arriveBy: false,
    );
    expect(earliest['Bravo']!.arrival.isAtSameMomentAs(time(8, 10)), true);
    expect(earliest['Charlie']!.arrival.isAtSameMomentAs(time(8, 25)), true);
    final cancelled = LiveFeed(now, {
      'ab|20261005': const TripPrediction(
        id: 'ab',
        serviceDate: '20261005',
        delay: 300,
      ),
      'ac|20261005': const TripPrediction(
        id: 'ac',
        serviceDate: '20261005',
        relationship: 3,
      ),
    });
    final fresh = index.routeChoices(
      'Charlie',
      ['Alpha', 'Bravo'],
      time(8, 30),
      now: now,
      live: cancelled,
      cachePrepared: true,
    );
    expect(fresh['Alpha'], isNull);
    expect(fresh['Bravo']!.legs.single.tripId, 'bc');
    final stale = index.routeChoices(
      'Charlie',
      ['Alpha', 'Bravo'],
      time(8, 30),
      now: now.add(const Duration(minutes: 4)),
      live: cancelled,
      cachePrepared: true,
    );
    expect(stale['Alpha']!.legs.first.tripId, 'ab');
    expect(
      () => index.routeChoices('Charlie', [], time(8, 30)),
      throwsStateError,
    );
  });
  test(
    'latest departure and earliest arrival choose a mixed-mode connection',
    () {
      final index = NetworkIndex(fixture());
      final latest = index.route('Alpha', 'Charlie', time(8, 30), now: now)!;
      expect(latest.legs.map((l) => l.tripId), ['ab', 'bc']);
      expect(latest.departure.isAtSameMomentAs(time(8, 0)), true);
      expect(latest.arrival.isAtSameMomentAs(time(8, 25)), true);
      final earliest = index.route(
        'Alpha',
        'Charlie',
        time(8, 0),
        arriveBy: false,
        now: now,
      )!;
      expect(earliest.arrival.isAtSameMomentAs(time(8, 25)), true);
      expect(earliest.changes, 1);
    },
  );
  test(
    'a propagated delay misses a transfer; cancellation changes the route',
    () {
      final index = NetworkIndex(fixture());
      final live = LiveFeed(now, {
        'ab|20261005': const TripPrediction(
          id: 'ab',
          serviceDate: '20261005',
          delay: 300,
        ),
      });
      final r = index.route(
        'Alpha',
        'Charlie',
        time(8, 30),
        live: live,
        now: now,
      )!;
      expect(r.legs.map((l) => l.tripId), ['ac']);
      final cancelled = LiveFeed(now, {
        ...live.trips,
        'ac|20261005': const TripPrediction(
          id: 'ac',
          serviceDate: '20261005',
          relationship: 3,
        ),
      });
      expect(
        index.route('Alpha', 'Charlie', time(8, 30), live: cancelled, now: now),
        isNull,
      );
      // Stale information cannot cancel/retime tomorrow's scheduled journey.
      expect(
        index
            .route(
              'Alpha',
              'Charlie',
              time(8, 30),
              live: cancelled,
              now: now.add(const Duration(minutes: 4)),
            )!
            .legs
            .first
            .tripId,
        'ab',
      );
    },
  );
  test('published minimum transfer and boarding restrictions are enforced', () {
    final j = fixture();
    j['transfers'] = [
      ['b', 'b', 2, 300, '', ''],
    ];
    expect(
      NetworkIndex(j)
          .route('Alpha', 'Charlie', time(8, 30), now: now)!
          .legs
          .first
          .tripId,
      'ac',
    );
    final k = fixture();
    k['trips'][0][4][0][4] = 1;
    expect(
      NetworkIndex(k)
          .route('Alpha', 'Charlie', time(8, 30), now: now)!
          .legs
          .first
          .tripId,
      'ac',
    );
  });
  test('request stops are usable, prebooked stops are excluded', () {
    final j = fixture();
    j['trips'][0][4][0][4] = 3;
    final r = NetworkIndex(j).route('Alpha', 'Charlie', time(8, 30), now: now)!;
    expect(r.legs.first.tripId, 'ab');
    expect(r.legs.first.requestStop, true);
    j['trips'][0][4][0][4] = 2;
    expect(
      NetworkIndex(j)
          .route('Alpha', 'Charlie', time(8, 30), now: now)!
          .legs
          .first
          .tripId,
      'ac',
    );
  });
  test('regional namesakes cannot impersonate Prague stops', () {
    final j = fixture();
    j['stops']['a'].add('P');
    j['stops']['c'].add('P');
    j['stops']['remote-a'] = ['Alpha', '', 49.6, 14.0, '', 0, '5'];
    j['stops']['remote-c'] = ['Charlie', '', 49.6, 14.1, '', 0, '5'];
    j['trips'].add([
      'remote',
      '9',
      '',
      7,
      [
        ['remote-a', 1, 8 * 3600 + 1680, 8 * 3600 + 1680, 0, 0],
        ['remote-c', 2, 8 * 3600 + 1740, 8 * 3600 + 1740, 0, 0],
      ],
      3,
      '',
    ]);
    expect(
      NetworkIndex(j)
          .route('Alpha', 'Charlie', time(8, 30), now: now)!
          .legs
          .first
          .tripId,
      'ab',
    );
  });
  test('different platforms need a continuous, explicitly estimated walk', () {
    final j = fixture();
    j['stops']['b2'] = ['Bravo metro', '', 50.0001, 14.0, 'hub', 0];
    j['stops']['b'][4] = 'hub';
    j['trips'][1][4][0][0] = 'b2';
    final r = NetworkIndex(j).route('Alpha', 'Charlie', time(8, 30), now: now)!;
    expect(r.legs.map((l) => l.mode), [0, -1, 1]);
    expect(r.estimatedWalking, true);
    expect(
      r.legs[1].departure,
      r.legs[0].arrival.add(const Duration(minutes: 2)),
    );
    expect(r.legs[1].arrival, r.legs[2].departure);
  });
  test('after-midnight service uses previous day and expires explicitly', () {
    final j = fixture();
    j['trips'] = [
      [
        'night',
        '91',
        'Charlie',
        1,
        [
          ['a', 1, 25 * 3600, 25 * 3600, 0, 0],
          ['c', 2, 25 * 3600 + 1200, 25 * 3600 + 1200, 0, 0],
        ],
        0,
        '',
      ],
    ];
    final r = NetworkIndex(
      j,
    ).route('Alpha', 'Charlie', time(1, 30), now: DateTime.utc(2026, 10, 4))!;
    expect(r.departure.isAtSameMomentAs(time(1, 0)), true);
    expect(
      () => NetworkIndex(j).route(
        'Alpha',
        'Charlie',
        tz.TZDateTime(prague, 2026, 10, 7, 9),
        now: now,
      ),
      throwsStateError,
    );
  });

  final cached = Platform.environment['PUBLIC_NETWORK_CACHE'];
  if (cached != null) {
    test('cached graph produces continuous complex public connections', () {
      final index = NetworkIndex(
        jsonDecode(utf8.decode(gzip.decode(File(cached).readAsBytesSync()))),
      );
      for (final pair in [
        ('Terminál 1', 'Háje'),
        ('Sídliště Barrandov', 'Černý Most'),
        ('Zoo Praha - Troja', 'Nemocnice Motol'),
      ]) {
        final r = index.route(
          pair.$1,
          pair.$2,
          time(8, 0),
          arriveBy: false,
          now: now,
        );
        expect(r, isNotNull, reason: '${pair.$1} → ${pair.$2}');
        expect(r!.changes, greaterThanOrEqualTo(1));
        expect(r.departure.isBefore(time(8, 0)), false);
        for (var i = 1; i < r.legs.length; i++) {
          expect(r.legs[i].departure.isBefore(r.legs[i - 1].arrival), false);
          expect(r.legs[i].from, r.legs[i - 1].to);
        }
        print(
          'PUBLIC ${pair.$1}→${pair.$2}: ${r.departure} — ${r.arrival}; ${r.legs.map((l) => '${l.line} ${l.from}→${l.to}').join(' / ')}',
        );
      }
    });
  }
  final zip = Platform.environment['PID_GTFS_FILE'];
  if (zip != null) {
    test('full PID graph produces three complex public connections', () async {
      final work = await Directory.systemTemp.createTemp('calendula-network-');
      try {
        final data = buildMetroIndex(zip, work.path);
        final network = data['network'] as Map<String, dynamic>;
        final index = NetworkIndex(network);
        final export = Platform.environment['NETWORK_INDEX_OUTPUT'];
        if (export != null) {
          await File(export).writeAsBytes(
            gzip.encode(utf8.encode(jsonEncode(network))),
            flush: true,
          );
        }
        print(
          'PUBLIC NETWORK: ${index.trips.length} trips, ${index.stops.length} stop records, ${index.stations.length} names',
        );
        for (final (from, to) in [
          ('Terminál 1', 'Háje'),
          ('Sídliště Barrandov', 'Černý Most'),
          ('Zoo Praha - Troja', 'Nemocnice Motol'),
        ]) {
          final started = DateTime.now();
          final route = index.route(
            from,
            to,
            time(8, 0),
            arriveBy: false,
            now: now,
          );
          expect(route, isNotNull, reason: '$from → $to');
          expect(route!.departure.isBefore(time(8, 0)), false);
          expect(route.changes, greaterThanOrEqualTo(1));
          expect(route.arrival.difference(time(8, 0)).inMinutes, lessThan(180));
          print(
            '$from → $to: ${route.departure} — ${route.arrival}; ${DateTime.now().difference(started).inMilliseconds} ms; ${route.legs.map((l) => '${l.line} ${l.from}→${l.to} ${l.estimated ? "estimated" : ""}').join(" / ")}',
          );
        }
      } finally {
        final resolved = work.resolveSymbolicLinksSync();
        if (!resolved.startsWith(
          Directory.systemTemp.resolveSymbolicLinksSync(),
        )) {
          throw StateError('Temporary test path escaped.');
        }
        await work.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
