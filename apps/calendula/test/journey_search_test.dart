import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:calendula/address_index.dart';
import 'package:calendula/journey_preferences.dart';
import 'package:calendula/network_planner_page.dart';
import 'package:calendula/network_router.dart';
import 'package:calendula/place_field.dart';
import 'package:calendula/place_search.dart';
import 'package:calendula/journey_endpoint.dart';

class TestEngine extends NetworkEngine {
  final calls = <(String, String, DateTime)>[];
  @override
  Future<void> load(String? path) async {
    stations = ['Dejvická', 'Muzeum', 'Fast stop'];
  }

  @override
  List<(String, double)> nearby(double lat, double lon, {int limit = 10}) => [
    ('Dejvická', 50),
    ('Fast stop', 500),
  ];
  @override
  Future<NetworkJourney?> route(
    String from,
    String to,
    DateTime target, {
    bool arriveBy = true,
    dynamic live,
    DateTime? now,
  }) async {
    calls.add((from, to, target));
    final departure = arriveBy
        ? target.subtract(Duration(minutes: from == 'Fast stop' ? 10 : 20))
        : target;
    return NetworkJourney([
      JourneyLeg(
        from,
        to,
        'A',
        to,
        'fixture',
        1,
        departure,
        arriveBy ? target : target.add(const Duration(minutes: 20)),
      ),
    ]);
  }

  @override
  Future<Map<String, NetworkJourney?>> routeChoices(
    String fixed,
    List<String> choices,
    DateTime target, {
    bool arriveBy = true,
    dynamic live,
    DateTime? now,
  }) async => {
    for (final choice in choices)
      choice: await route(
        arriveBy ? choice : fixed,
        arriveBy ? fixed : choice,
        target,
        arriveBy: arriveBy,
        live: live,
        now: now,
      ),
  };

  @override
  Future<NetworkEndpointRoute?> routeEndpoints(
    List<NetworkEndpoint> origins,
    List<NetworkEndpoint> destinations,
    DateTime target, {
    bool arriveBy = true,
    dynamic live,
    DateTime? now,
  }) async {
    NetworkEndpointRoute? best;
    for (var i = 0; i < origins.length; i++) {
      for (var j = 0; j < destinations.length; j++) {
        final route = await this.route(
          origins[i].stop,
          destinations[j].stop,
          arriveBy
              ? target.subtract(Duration(minutes: destinations[j].walkMinutes))
              : target.add(Duration(minutes: origins[i].walkMinutes)),
          arriveBy: arriveBy,
          live: live,
          now: now,
        );
        final full = endpointWalks(route!, origins[i], destinations[j]);
        if (arriveBy && full.departure.isBefore(now!)) continue;
        if (best == null ||
            (arriveBy
                ? full.departure.isAfter(best.journey.departure)
                : full.arrival.isBefore(best.journey.arrival))) {
          best = NetworkEndpointRoute(full, i, j);
        }
      }
    }
    return best;
  }

  @override
  void dispose() {}
}

AddressIndex addresses() => AddressIndex({
  'date': 'fixture',
  'addresses': [
    ['Testovací', '100', '2', 50.0, 14.0, 'Praha 6'],
    ['Testovací', '2', '7', 50.0, 14.0, 'Praha 6'],
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('Czech accented and unaccented prefixes, reordered words and English aliases rank locally', () {
    final stops = StopSearch([
      'Dejvická',
      'Sídliště Barrandov',
      'Hlavní nádraží',
      'Terminál 1',
      'Terminál 2',
      'Nádraží Veleslavín',
      'Zličín',
    ]);
    expect(stops.search('d').first, 'Dejvická');
    expect(stops.search('dejvicka'), ['Dejvická']);
    expect(stops.search('Dejvic\u0301ka').first, 'Dejvická');
    expect(stops.search('barr sid').single, 'Sídliště Barrandov');
    expect(stops.search('main stat').single, 'Hlavní nádraží');
    expect(stops.resolve('MAIN STATION'), 'Hlavní nádraží');
    expect(stops.search('airport').toSet(), {'Terminál 1', 'Terminál 2'});
    expect(stops.resolve('airport'), isNull);
    expect(stops.resolve('zlicin'), 'Zličín');
  });
  test('Addresses accept accents, full or orientation numbers and reject an ambiguous building', () {
    final index = addresses();
    expect(index.resolve('Testovaci 100/2, Prague 6')!.house, '100');
    expect(index.resolve('Testovaci 100/2, 160 00 Praha 6')!.house, '100');
    expect(index.resolve('Testovací 7, Praha 6')!.house, '2');
    expect(index.resolve('Testovaci 2'), isNull);
    expect(index.resolve('Testovaci'), isNull);
    expect(index.search('testov 100').single.house, '100');
    expect(
      index.resolve(index.addresses.first.label),
      same(index.addresses.first),
    );
  });
  test('Bundled public Prague address index has real bounded coordinates and resolves a university street address', () async {
    final index = await AddressIndex.load();
    expect(index.addresses.length, 134670);
    expect(index.date, '2026-09-30');
    final address = index.resolve('Technicka 1902/2, Prague 6');
    expect(address, isNotNull);
    expect(address!.latitude, inInclusiveRange(50.10, 50.11));
    expect(address.longitude, inInclusiveRange(14.38, 14.40));
  });
  testWidgets(
    'Narrow autocomplete responds without Czech marks and keyboard selection updates the field',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController(), focus = FocusNode();
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: PlaceField(
                label: 'From',
                controller: controller,
                focus: focus,
                stops: StopSearch(['Dejvická', 'Muzeum']),
                addresses: addresses(),
                onSelected: () => selected++,
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'dejv');
      await tester.pumpAndSettle();
      expect(find.text('Dejvická'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(controller.text, 'Dejvická');
      expect(selected, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    },
  );
  test('Real bundled PID engine routes between public Prague addresses with endpoint walks', () async {
    final engine = NetworkEngine();
    try {
      final data = await AddressIndex.load();
      await engine.load(null);
      final stops = StopSearch(engine.stations);
      final origins = resolveEndpoint(
        engine,
        stops,
        data,
        'Technicka 1902/2, Prague 6',
      );
      final destinations = resolveEndpoint(
        engine,
        stops,
        data,
        'Vinohradska 2828/151, Prague 3',
      );
      expect(origins, isNotEmpty);
      expect(destinations, isNotEmpty);
      final result = await findEndpointJourney(
        engine,
        origins,
        destinations,
        DateTime.utc(2026, 10, 5, 10),
        now: DateTime.utc(2026, 10, 5, 6),
      );
      expect(
        result,
        isNotNull,
        reason:
            'Public candidates: ${origins.map((o) => '${o.stop}/${o.walkMinutes}')} -> ${destinations.map((o) => '${o.stop}/${o.walkMinutes}')}',
      );
      expect(result!.journey.estimatedWalking, true);
      expect(
        result.journey.arrival.isAfter(DateTime.utc(2026, 10, 5, 10)),
        false,
      );
    } finally {
      engine.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
  test(
    'Arrive-by excludes a route whose initial walk has already started',
    () async {
      final engine = TestEngine(), now = DateTime.utc(2026, 10, 5, 6);
      const origins = [JourneyEndpoint('Dejvická', 'Home', 6)];
      const destinations = [JourneyEndpoint('Muzeum', 'Muzeum', 0)];
      expect(
        await findEndpointJourney(
          engine,
          origins,
          destinations,
          now.add(const Duration(minutes: 25)),
          now: now,
        ),
        isNull,
      );
      final result = await findEndpointJourney(
        engine,
        origins,
        destinations,
        now.add(const Duration(minutes: 30)),
        now: now,
      );
      expect(result!.journey.departure, now.add(const Duration(minutes: 4)));
    },
  );
  testWidgets(
    'Opening an event uses saved home and destination and calculates immediately, including saved walking buffers',
    (tester) async {
      await const JourneyPreferenceStore().save(
        const JourneyPreferences(mode: OriginMode.home, home: 'dejvicka'),
      );
      final engine = TestEngine(), target = DateTime.utc(2026, 10, 5, 7);
      await tester.pumpWidget(
        MaterialApp(
          home: NetworkPlannerPage(
            live: () => null,
            initialTo: 'Muzeum',
            initialArrival: target,
            now: () => DateTime.utc(2026, 10, 5, 6),
            requireEndpoints: true,
            initialDestinationWalk: 5,
            engine: engine,
            addresses: addresses(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.calls.length, 1);
      expect(engine.calls.single.$1, 'Dejvická');
      expect(engine.calls.single.$2, 'Muzeum');
      expect(
        engine.calls.single.$3,
        target.subtract(const Duration(minutes: 5)),
      );
      expect(find.text('Set home'), findsOneWidget);
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields.map((f) => f.controller!.text), ['dejvicka', 'Muzeum']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Address route compares nearby stops with walking and keeps the original destination text',
    (tester) async {
      await const JourneyPreferenceStore().save(
        const JourneyPreferences(
          mode: OriginMode.home,
          home: 'Testovaci 100/2, Prague 6',
        ),
      );
      final engine = TestEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: NetworkPlannerPage(
            live: () => null,
            initialTo: 'Muzeum',
            initialArrival: DateTime.utc(2026, 10, 5, 7),
            now: () => DateTime.utc(2026, 10, 5, 6),
            requireEndpoints: true,
            engine: engine,
            addresses: addresses(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.calls.map((c) => c.$1).toSet(), {'Dejvická', 'Fast stop'});
      final route = tester.state(find.byType(NetworkPlannerPage)) as dynamic;
      expect((route.journey as NetworkJourney).legs[1].from, 'Fast stop');
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields.last.controller!.text, 'Muzeum');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Desktop with GPS preference falls back to the saved home without another setup',
    (tester) async {
      await const JourneyPreferenceStore().save(
        const JourneyPreferences(mode: OriginMode.current, home: 'dejvicka'),
      );
      final engine = TestEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: NetworkPlannerPage(
            live: () => null,
            initialTo: 'Muzeum',
            initialArrival: DateTime.utc(2026, 10, 5, 7),
            now: () => DateTime.utc(2026, 10, 5, 6),
            requireEndpoints: true,
            engine: engine,
            addresses: addresses(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.calls.single.$1, 'Dejvická');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Past event gives a clear action and Depart now calculates without changing the event destination',
    (tester) async {
      final engine = TestEngine(), now = DateTime.utc(2026, 10, 5, 12);
      await tester.pumpWidget(
        MaterialApp(
          home: NetworkPlannerPage(
            live: () => null,
            initialFrom: 'Dejvická',
            initialTo: 'Muzeum',
            initialArrival: now.subtract(const Duration(hours: 1)),
            now: () => now,
            requireEndpoints: true,
            engine: engine,
            addresses: addresses(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.calls, isEmpty);
      final error = find.text(
        'This arrival time has passed. Choose a future time or use Depart now.',
      );
      final scrollable = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(error, 180, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(error, findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Depart now'),
        -180,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Depart now'));
      await tester.pumpAndSettle();
      expect(engine.calls.single.$3, now);
      expect(engine.calls.single.$2, 'Muzeum');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
