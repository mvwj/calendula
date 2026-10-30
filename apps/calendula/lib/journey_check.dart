import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'address_index.dart';
import 'calendar.dart';
import 'journey_endpoint.dart';
import 'event_place.dart';
import 'journey_preferences.dart';
import 'widget_snapshot.dart';
import 'network_router.dart';
import 'place_search.dart';

/// Native asset/route probe using common public places. No calendar, settings,
/// GPS, mailbox or network transport is read.
Future<Map<String, dynamic>> journeyReport() async {
  final report = <String, dynamic>{
    'version': '0.2.6',
    'calendarRead': false,
    'gpsRead': false,
    'settingsRead': false,
    'networkRequests': 0,
    'referenceNow': '2026-10-05T06:00:00Z',
  };
  final engine = NetworkEngine();
  var passed = false;
  try {
    final startup = Stopwatch()..start();
    final addressLoading = AddressIndex.load().then((value) {
      report['addressLoadMilliseconds'] = startup.elapsedMilliseconds;
      return value;
    });
    addressLoading.ignore();
    final graphTimer = Stopwatch()..start();
    await engine.load(null);
    report['graphLoadMilliseconds'] = graphTimer.elapsedMilliseconds;
    final addresses = await addressLoading;
    report['coldLoadMilliseconds'] = startup.elapsedMilliseconds;
    report['timetableStart'] = engine.start;
    report['timetableEnd'] = engine.end;
    final stops = StopSearch(engine.stations);
    report['publicAddresses'] = addresses.addresses.length;
    report['unaccentedStop'] = stops.resolve('dejvicka') == 'Dejvická';
    report['englishAlias'] = stops.resolve('main station') == 'Hlavní nádraží';
    final cases = <Map<String, dynamic>>[];
    for (final pair in [
      ('Technicka 1902/2, Prague 6', 'Vinohradska 2828/151, Prague 3'),
      ('Vinohradska 2828/151, Prague 3', 'Vaclavske namesti 1700/68, Prague 1'),
      ('Terminál 2', 'Háje'),
      ('Zličín', 'Letňany'),
    ]) {
      final origins = resolveEndpoint(engine, stops, addresses, pair.$1),
          destinations = resolveEndpoint(engine, stops, addresses, pair.$2);
      final timer = Stopwatch()..start();
      final result = await findEndpointJourney(
        engine,
        origins,
        destinations,
        DateTime.utc(2026, 10, 5, 10),
        now: DateTime.utc(2026, 10, 5, 6),
      );
      if (result == null) throw StateError('Public address route unavailable.');
      cases.add({
        'originChoices': origins.length,
        'calculationMilliseconds': timer.elapsedMilliseconds,
        'destinationChoices': destinations.length,
        'fromStop': result.from.stop,
        'toStop': result.to.stop,
        'originWalk': result.from.walkMinutes,
        'destinationWalk': result.to.walkMinutes,
        'minutes': result.journey.arrival
            .difference(result.journey.departure)
            .inMinutes,
        'changes': result.journey.changes,
        'estimatedWalking': result.journey.estimatedWalking,
      });
    }
    report['publicCases'] = cases;
    report['allCalculationsWithinTwoSeconds'] = cases.every(
      (c) => (c['calculationMilliseconds'] as int) <= 2000,
    );
    // Synthetic appointment + public campus address; no owner stores/GPS/mail.
    final appointment = CalendarEvent(
      id: 'sis:fixture:lecture:2026-10-08',
      title: 'Synthetic campus appointment',
      category: 'Study',
      room: 'S3',
      sessionType: 'Lecture',
      notes: 'SIS CSV · diagnostic fixture',
      start: DateTime.utc(2026, 10, 8, 10),
      end: DateTime.utc(2026, 10, 8, 11),
    );
    final enriched = effectiveEvent(appointment);
    final background = await buildWidgetSnapshot(
      [appointment],
      null,
      routing: engine,
      addresses: addresses,
      preferences: const JourneyPreferences(
        mode: OriginMode.home,
        home: 'Technicka 1902/2, Prague 6',
      ),
      at: DateTime.utc(2026, 10, 8, 6),
    );
    final visibleTimer = Stopwatch()..start();
    final visible = await buildWidgetSnapshot(
      [appointment],
      null,
      routing: engine,
      addresses: addresses,
      preferences: const JourneyPreferences(
        mode: OriginMode.home,
        home: 'Technicka 1902/2, Prague 6',
      ),
      at: DateTime.utc(2026, 10, 8, 6),
      includeDepartNow: true,
    );
    report['eventRouteMilliseconds'] = visibleTimer.elapsedMilliseconds;
    report['eventAddressRecognised'] =
        addresses.resolve(eventDestination(appointment)) != null;
    report['eventFloorResolved'] = enriched.floor == '3';
    report['backgroundHasNoLeaveNow'] = background.data['departNow'] == '';
    report['visibleHasLeaveNow'] = (visible.data['departNow'] as String)
        .startsWith('Leave now →');
    report['eventArrivesBeforeBuffer'] =
        background.journeys[appointment.id]?.arrival.isAfter(
          appointment.start.subtract(const Duration(minutes: 10)),
        ) ==
        false;
    passed =
        report['unaccentedStop'] == true &&
        report['englishAlias'] == true &&
        cases.length == 4 &&
        report['eventAddressRecognised'] == true &&
        report['eventFloorResolved'] == true &&
        report['backgroundHasNoLeaveNow'] == true &&
        report['visibleHasLeaveNow'] == true &&
        report['eventArrivesBeforeBuffer'] == true;
  } catch (e) {
    report['errorType'] = e.runtimeType.toString();
    if (e is StateError) report['publicError'] = e.message;
  } finally {
    engine.dispose();
  }
  report['passed'] = passed;
  return report;
}

Future<void> journeyCheck() async {
  runApp(const SizedBox.shrink());
  final report = await journeyReport();
  await File(
    '${File(Platform.resolvedExecutable).parent.path}/journey-check.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  exit(report['passed'] == true ? 0 : 1);
}

Future<void> androidJourneyCheck() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  final report = await journeyReport();
  await const MethodChannel('app.calendula/sync-check').invokeMethod(
    'complete',
    '${report['passed'] == true ? 'PASS' : 'FAIL'}: ${jsonEncode(report)}',
  );
}
