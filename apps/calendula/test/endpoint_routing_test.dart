import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:calendula/network_router.dart';
import 'package:calendula/calendar.dart';
import 'package:calendula/transit.dart';
import 'package:calendula/journey_endpoint.dart';

import 'network_test.dart' show fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  final now = DateTime.utc(2026, 10, 5, 5, 30);
  DateTime time(int h, int m) => tz.TZDateTime(prague, 2026, 10, 5, h, m);
  const origins = [
    NetworkEndpoint('Alpha', 'Home', 7),
    NetworkEndpoint('Bravo', 'Home', 3),
  ];
  const destinations = [
    NetworkEndpoint('Charlie', 'Venue', 5),
    NetworkEndpoint('Charlie', 'Venue', 1),
  ];

  NetworkJourney? separate(
    NetworkIndex index,
    DateTime target,
    bool arriveBy,
    LiveFeed? live,
  ) {
    NetworkJourney? best;
    for (final from in origins) {
      for (final to in destinations) {
        final route = index.route(
          from.stop,
          to.stop,
          arriveBy
              ? target.subtract(Duration(minutes: to.walkMinutes))
              : target.add(Duration(minutes: from.walkMinutes)),
          arriveBy: arriveBy,
          live: live,
          now: now,
        );
        if (route == null) continue;
        final full = endpointWalks(route, from, to);
        if (arriveBy && full.departure.isBefore(now)) continue;
        if (best == null ||
            (arriveBy
                ? full.departure.isAfter(best.departure)
                : full.arrival.isBefore(best.arrival))) {
          best = full;
        }
      }
    }
    return best;
  }

  test('Weighted search agrees with the full pair matrix for both directions, walking costs and fresh/stale cancellations', () {
    final index = NetworkIndex(fixture());
    final live = LiveFeed(now, {
      'bc|20261005': const TripPrediction(
        id: 'bc',
        serviceDate: '20261005',
        relationship: 3,
      ),
    });
    for (final arriveBy in [true, false]) {
      for (final feed in [
        null,
        live,
        LiveFeed(now.subtract(const Duration(minutes: 4)), live.trips),
      ]) {
        for (var minute = 0; minute < 45; minute += 3) {
          final target = time(8, minute);
          final expected = separate(index, target, arriveBy, feed);
          final actual = index.routeEndpoints(
            origins,
            destinations,
            target,
            arriveBy: arriveBy,
            live: feed,
            now: now,
            cachePrepared: true,
          );
          expect(actual == null, expected == null);
          if (actual == null) continue;
          expect(actual.journey.departure, expected!.departure);
          if (arriveBy) expect(actual.journey.arrival.isAfter(target), false);
          if (!arriveBy) expect(actual.journey.arrival, expected.arrival);
          expect(actual.journey.legs.first.from, 'Home');
          expect(actual.journey.legs.last.to, 'Venue');
        }
      }
    }
  });

  test('Rejects expired initial walking, overlap and unbounded endpoints', () {
    final index = NetworkIndex(fixture());
    expect(
      index.routeEndpoints(
        [const NetworkEndpoint('Alpha', 'Home', 7)],
        [const NetworkEndpoint('Charlie', 'Venue', 1)],
        time(8, 30),
        now: time(7, 58),
      ),
      isNull,
    );
    expect(
      () =>
          index.routeEndpoints(origins, [origins.first], time(8, 30), now: now),
      throwsStateError,
    );
    expect(
      () => index.routeEndpoints(
        [const NetworkEndpoint('Alpha', 'Home', 181)],
        destinations,
        time(8, 30),
        now: now,
      ),
      throwsStateError,
    );
  });

  test('Walking seed across midnight keeps the preceding service-day trip', () {
    final data = fixture();
    data['trips'] = [
      [
        'night',
        'N',
        'Charlie',
        7,
        [
          ['a', 1, 23 * 3600 + 45 * 60, 23 * 3600 + 45 * 60, 0, 0],
          ['c', 2, 24 * 3600, 24 * 3600, 0, 0],
        ],
        3,
        '',
      ],
    ];
    final target = tz.TZDateTime(prague, 2026, 10, 6, 0, 10);
    final route = NetworkIndex(data).routeEndpoints(
      [const NetworkEndpoint('Alpha', 'Home', 3)],
      [
        const NetworkEndpoint('Charlie', 'Venue', 12),
        const NetworkEndpoint('Charlie', 'Venue', 8),
      ],
      target,
      now: now,
    );
    expect(route, isNotNull);
    expect(route!.destination, 1);
    expect(route.journey.arrival.isAfter(target), false);
  });

  test('Persistent worker returns the weighted endpoint choice and survives a second direction', () async {
    final dir = await Directory.systemTemp.createTemp('calendula-weighted-');
    final engine = NetworkEngine();
    try {
      final file = File('${dir.path}/network.gz');
      await file.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(fixture()))));
      await engine.load(file.path);
      for (final arriveBy in [true, false]) {
        final result = await engine.routeEndpoints(
          origins,
          destinations,
          arriveBy ? time(8, 30) : time(7, 50),
          arriveBy: arriveBy,
          now: now,
        );
        expect(result, isNotNull);
        expect(result!.destination, 1);
        expect(result.journey.legs.first.from, 'Home');
        expect(result.journey.legs.last.to, 'Venue');
      }
    } finally {
      engine.dispose();
      await dir.delete(recursive: true);
    }
  });

  test(
    'Overlapping access groups agree with every valid pair in both directions',
    () async {
      final dir = await Directory.systemTemp.createTemp('calendula-overlap-');
      final engine = NetworkEngine(), index = NetworkIndex(fixture());
      final from = [
        const JourneyEndpoint('Alpha', 'Home', 7),
        const JourneyEndpoint('Bravo', 'Home', 3),
        const JourneyEndpoint('Bravo', 'Home', 1),
      ];
      final to = [
        const JourneyEndpoint('Bravo', 'Venue', 5),
        const JourneyEndpoint('Charlie', 'Venue', 1),
      ];
      final cancellation = LiveFeed(now, {
        'bc|20261005': const TripPrediction(
          id: 'bc',
          serviceDate: '20261005',
          relationship: 3,
        ),
      });
      try {
        final file = File('${dir.path}/network.gz');
        await file.writeAsBytes(
          gzip.encode(utf8.encode(jsonEncode(fixture()))),
        );
        await engine.load(file.path);
        for (final arriveBy in [true, false]) {
          for (final live in [
            null,
            cancellation,
            LiveFeed(
              now.subtract(const Duration(minutes: 4)),
              cancellation.trips,
            ),
          ]) {
            for (var minute = 0; minute < 45; minute += 3) {
              final target = time(8, minute);
              NetworkJourney? expected;
              for (final a in from) {
                for (final b in to) {
                  if (a.stop == b.stop) continue;
                  final route = index.route(
                    a.stop,
                    b.stop,
                    arriveBy
                        ? target.subtract(Duration(minutes: b.walkMinutes))
                        : target.add(Duration(minutes: a.walkMinutes)),
                    arriveBy: arriveBy,
                    live: live,
                    now: now,
                  );
                  if (route == null) continue;
                  final full = endpointWalks(route, a, b);
                  if (arriveBy && full.departure.isBefore(now)) continue;
                  if (expected == null ||
                      (arriveBy
                          ? full.departure.isAfter(expected.departure)
                          : full.arrival.isBefore(expected.arrival))) {
                    expected = full;
                  }
                }
              }
              final actual = await findEndpointJourney(
                engine,
                from,
                to,
                target,
                arriveBy: arriveBy,
                live: live,
                now: now,
              );
              expect(actual == null, expected == null);
              if (actual == null) continue;
              expect(
                arriveBy ? actual.journey.departure : actual.journey.arrival,
                arriveBy ? expected!.departure : expected!.arrival,
              );
              expect(actual.from.stop == actual.to.stop, false);
            }
          }
        }
      } finally {
        engine.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
