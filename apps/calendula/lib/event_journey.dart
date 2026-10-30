import 'address_index.dart';

import 'dart:io';

import 'calendar.dart';
import 'event_place.dart';
import 'journey_endpoint.dart';
import 'journey_preferences.dart';
import 'network_router.dart';
import 'place_search.dart';
import 'transit.dart';

import 'package:timezone/timezone.dart' as tz;

class EventJourneyPlan {
  final NetworkJourney? planned, departNow;
  final String status, origin;
  final DateTime calculatedAt;
  final bool departNowChecked;
  const EventJourneyPlan({
    this.planned,
    this.departNow,
    required this.status,
    required this.origin,
    required this.calculatedAt,
    this.departNowChecked = false,
  });
  bool get predicted => planned?.legs.any((leg) => leg.predicted) ?? false;
  String leaveLine(CalendarEvent e) => planned != null
      ? '${planned!.departure.isBefore(calculatedAt) ? 'Missed departure' : 'Leave'} ${clockLocal(planned!.departure)} · ${planned!.arrival.difference(planned!.departure).inMinutes} min'
      : e.travelMinutes > 0
      ? 'Leave ${clock(e.leaveAt)} · manual estimate'
      : status;
  String nowLine(CalendarEvent e) {
    if (!departNowChecked) return 'Leave now · open to refresh';
    if (departNow == null) {
      return 'Leave now · ${planned == null ? status : 'no connection found'}';
    }
    final arrival = departNow!.arrival;
    final target = e.start.subtract(Duration(minutes: e.bufferMinutes));
    final late = arrival.difference(e.start).inSeconds;
    return 'Leave now → ${clockLocal(arrival)} · ${late > 0
        ? '${(late / 60).ceil()} min late'
        : arrival.isAfter(target)
        ? 'buffer reduced'
        : 'on time'}';
  }
}

String clockLocal(DateTime time) => clock(tz.TZDateTime.from(time, prague));

String startingPointText(CalendarEvent event, JourneyPreferences preferences) =>
    event.originStop.isNotEmpty
    ? event.originStop
    : Platform.isWindows && preferences.mode == OriginMode.current
    ? preferences.home
    : preferences.address;

Future<EventJourneyPlan> planEventJourney(
  CalendarEvent original,
  NetworkEngine engine,
  AddressIndex? addresses,
  JourneyPreferences preferences, {
  LiveFeed? live,
  required DateTime now,
  OriginFix? fix,
  bool includeDepartNow = false,
  Map<String, NetworkJourney?>? departNowCache,
}) async {
  final e = effectiveEvent(original), stops = StopSearch(engine.stations);
  final originText = startingPointText(e, preferences);
  final useFix =
      originText.isEmpty &&
      preferences.mode == OriginMode.current &&
      fix != null &&
      fix.usableAt(now);
  final origins = useFix
      ? nearbyEndpoints(
          engine,
          fix.latitude,
          fix.longitude,
          'Last GPS location',
        )
      : resolveEndpoint(engine, stops, addresses, originText);
  final destinations = resolveEndpoint(
    engine,
    stops,
    addresses,
    eventDestination(e),
  );
  final origin = useFix ? 'GPS ${clockLocal(fix.at)}' : originText;
  EventJourneyPlan missing(String message) => EventJourneyPlan(
    status: message,
    origin: origin,
    calculatedAt: now,
    departNowChecked: includeDepartNow,
  );
  if (origins.isEmpty) return missing('Set home or open the app for GPS');
  if (destinations.isEmpty) return missing('Add an exact destination address');
  List<JourneyEndpoint> addWalk(List<JourneyEndpoint> points, int minutes) => [
    for (final point in points)
      JourneyEndpoint(
        point.stop,
        point.label,
        point.walkMinutes == 0 ? minutes : point.walkMinutes,
      ),
  ];
  final from = addWalk(origins, e.originWalkMinutes),
      to = addWalk(destinations, e.destinationWalkMinutes),
      target = e.start.subtract(Duration(minutes: e.bufferMinutes));
  NetworkJourney? planned;
  var status = 'No connection found';
  if (target.isAfter(now)) {
    planned = (await findEndpointJourney(
      engine,
      from,
      to,
      target,
      live: live,
      now: now,
    ))?.journey;
    planned = preferDirectWalk(
      planned,
      directWalkJourney(
        engine,
        addresses,
        originText,
        eventDestination(e),
        target,
        now: now,
        currentPoint: useFix ? (fix.latitude, fix.longitude) : null,
      ),
    );
  }
  // Retain a useful, explicitly missed scheduled departure instead of inventing
  // a leave time when no feasible connection remains before the appointment.
  if (planned == null) {
    final missed = (await findEndpointJourney(
      engine,
      from,
      to,
      target,
      now: target.subtract(const Duration(hours: 8)),
    ))?.journey;
    if (missed != null && missed.departure.isBefore(now)) planned = missed;
    if (planned != null) status = 'Scheduled departure · replan now';
  } else {
    status = planned.legs.every((l) => l.mode < 0)
        ? 'Estimated walk'
        : planned.legs.any((l) => l.predicted)
        ? 'Available delay predictions'
        : 'Scheduled connection';
  }
  final key =
      '${from.map((e) => '${e.stop}:${e.walkMinutes}').join('|')}>'
      '${to.map((e) => '${e.stop}:${e.walkMinutes}').join('|')}';
  var current = !includeDepartNow
      ? null
      : departNowCache?.containsKey(key) == true
      ? departNowCache![key]
      : includeDepartNow
      ? (await findEndpointJourney(
          engine,
          from,
          to,
          now,
          arriveBy: false,
          live: live,
          now: now,
        ))?.journey
      : null;
  if (includeDepartNow) {
    current = preferDirectWalk(
      current,
      directWalkJourney(
        engine,
        addresses,
        originText,
        eventDestination(e),
        now,
        arriveBy: false,
        now: now,
        currentPoint: useFix ? (fix.latitude, fix.longitude) : null,
      ),
      arriveBy: false,
    );
    departNowCache?[key] = current;
  }
  return EventJourneyPlan(
    planned: planned,
    departNow: current,
    status: status,
    origin: origin,
    calculatedAt: now,
    departNowChecked: includeDepartNow,
  );
}

/// Local recomputation cadence; does not request any provider data.
Duration planRefreshInterval(Iterable<CalendarEvent> events, DateTime now) {
  final imminent = events.any(
    (e) =>
        !e.allDay &&
        e.end.isAfter(now) &&
        e.start.isBefore(now.add(const Duration(hours: 2))),
  );
  return imminent ? const Duration(minutes: 2) : const Duration(minutes: 15);
}
