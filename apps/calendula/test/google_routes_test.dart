import 'package:flutter_test/flutter_test.dart';
import 'package:calendula/google_routes.dart';

Map<String, dynamic> ride(
  String departure,
  String arrival,
  String from,
  String to,
  String type,
) => {
  'travelMode': 'TRANSIT',
  'transitDetails': {
    'stopDetails': {
      'departureTime': departure,
      'arrivalTime': arrival,
      'departureStop': {'name': from},
      'arrivalStop': {'name': to},
    },
    'transitLine': {
      'nameShort': '12',
      'vehicle': {'type': type},
    },
    'headsign': to,
  },
};
Map<String, dynamic> sample({bool impossible = false}) => {
  'routes': [
    {
      'legs': [
        {
          'steps': [
            {
              'travelMode': 'WALK',
              'staticDuration': '180s',
              'navigationInstruction': {'instructions': '<b>Walk</b> to Alpha'},
            },
            ride(
              '2026-10-05T06:04:00Z',
              '2026-10-05T06:14:00Z',
              'Alpha',
              'Bravo',
              'BUS',
            ),
            {'travelMode': 'WALK', 'staticDuration': '120s'},
            ride(
              impossible ? '2026-10-05T06:15:00Z' : '2026-10-05T06:18:00Z',
              '2026-10-05T06:25:00Z',
              'Bravo metro',
              'Charlie',
              'SUBWAY',
            ),
            {'travelMode': 'WALK', 'staticDuration': '240s'},
          ],
        },
      ],
    },
  ],
};

void main() {
  test(
    'minimal transit request omits calendar metadata and normalizes UTC',
    () {
      final target = DateTime.parse('2026-10-05T09:00:00+02:00');
      final body = GoogleRoutes.request(
        {'address': 'Prague public test origin'},
        {'address': 'Prague public test destination'},
        target,
      );
      expect(body.keys.toSet(), {
        'origin',
        'destination',
        'travelMode',
        'computeAlternativeRoutes',
        'languageCode',
        'arrivalTime',
      });
      expect(body['arrivalTime'], '2026-10-05T07:00:00.000Z');
      expect(body['travelMode'], 'TRANSIT');
      expect(body.containsKey('key'), false);
    },
  );
  test('walking and waiting preserve the full transit timeline', () {
    final r = GoogleRoutes.decode(
      sample(),
      DateTime.utc(2026, 10, 5, 6, 30),
    ).single;
    expect(r.departure, DateTime.utc(2026, 10, 5, 6, 1));
    expect(r.arrival, DateTime.utc(2026, 10, 5, 6, 29));
    expect(r.changes, 1);
    expect(r.legs.map((l) => l.mode), [-1, 3, -1, 1, -1]);
    expect(r.legs.first.to, 'Walk to Alpha');
    expect(r.legs.every((l) => !l.predicted), true);
    expect(r.legs[3].departure.difference(r.legs[2].arrival).inMinutes, 2);
  });
  test('late, too-early and impossible connections are rejected', () {
    expect(
      GoogleRoutes.decode(sample(), DateTime.utc(2026, 10, 5, 6, 28)),
      isEmpty,
    );
    expect(
      GoogleRoutes.decode(
        sample(),
        DateTime.utc(2026, 10, 5, 6, 2),
        arriveBy: false,
      ),
      isEmpty,
    );
    expect(
      GoogleRoutes.decode(
        sample(impossible: true),
        DateTime.utc(2026, 10, 5, 6, 30),
      ),
      isEmpty,
    );
  });
}
