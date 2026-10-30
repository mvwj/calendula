import 'dart:math';

import 'address_index.dart';
import 'network_router.dart';
import 'place_search.dart';
import 'transit.dart';

class JourneyEndpoint extends NetworkEndpoint {
  const JourneyEndpoint(super.stop, super.label, super.walkMinutes);
}

List<JourneyEndpoint> nearbyEndpoints(
  NetworkEngine engine,
  double lat,
  double lon,
  String label,
) {
  final nearby = engine
      .nearby(lat, lon, limit: 30)
      .where((s) => s.$2 <= 1500)
      .toList();
  final choices = {for (final s in nearby.take(3)) s.$1: s.$2};
  // Nearby bus/tram names can crowd out a useful metro or railway station,
  // especially while a closer station is closed. Include the nearest of each mode.
  for (final mode in [1, 2, 0, 3]) {
    final match = nearby
        .where((s) => engine.stationModes[s.$1]?.contains(mode) ?? false)
        .firstOrNull;
    if (match != null) choices[match.$1] = match.$2;
  }
  return [
    for (final s in choices.entries)
      JourneyEndpoint(s.key, label, max(2, (s.value * 1.3 / 75).ceil())),
  ];
}

List<JourneyEndpoint> resolveEndpoint(
  NetworkEngine engine,
  StopSearch stops,
  AddressIndex? addresses,
  String text,
) {
  final stop = stops.resolve(text);
  if (stop != null) return [JourneyEndpoint(stop, stop, 0)];
  final address = addresses?.resolve(text);
  return address == null
      ? []
      : nearbyEndpoints(
          engine,
          address.latitude,
          address.longitude,
          address.label,
        );
}

NetworkJourney withEndpointWalks(
  NetworkJourney route,
  JourneyEndpoint from,
  JourneyEndpoint to,
) => endpointWalks(route, from, to);

class EndpointJourney {
  final NetworkJourney journey;
  final JourneyEndpoint from, to;
  const EndpointJourney(this.journey, this.from, this.to);
}

/// Short direct walks are candidates too, especially when already at the venue.
/// This remains a distance estimate until a pedestrian street graph is available.
NetworkJourney? directWalkJourney(
  NetworkEngine engine,
  AddressIndex? addresses,
  String from,
  String to,
  DateTime target, {
  bool arriveBy = true,
  DateTime? now,
  (double, double)? currentPoint,
}) {
  (double, double)? point(String text) {
    final address = addresses?.resolve(text);
    if (address != null) return (address.latitude, address.longitude);
    final name = StopSearch(engine.stations).resolve(text);
    final stop = engine.coordinates.where((p) => p[0] == name).firstOrNull;
    return stop == null
        ? null
        : ((stop[1] as num).toDouble(), (stop[2] as num).toDouble());
  }

  final a = currentPoint ?? point(from), b = point(to);
  if (a == null || b == null) return null;
  final h =
      pow(sin((a.$1 - b.$1) * pi / 360), 2) +
      cos(a.$1 * pi / 180) *
          cos(b.$1 * pi / 180) *
          pow(sin((a.$2 - b.$2) * pi / 360), 2);
  final distance = 6371000 * 2 * atan2(sqrt(h), sqrt(max(0, 1 - h)));
  if (distance > 1500) return null;
  final duration = Duration(minutes: max(1, (distance * 1.3 / 75).ceil()));
  final departure = arriveBy ? target.subtract(duration) : target;
  if (now != null && departure.isBefore(now)) return null;
  return NetworkJourney([
    JourneyLeg(
      currentPoint == null ? from : 'Last GPS location',
      to,
      '',
      '',
      '',
      -1,
      departure,
      departure.add(duration),
      estimated: true,
    ),
  ]);
}

NetworkJourney? preferDirectWalk(
  NetworkJourney? transit,
  NetworkJourney? walk, {
  bool arriveBy = true,
}) =>
    walk != null &&
        (transit == null ||
            (arriveBy
                ? walk.departure.isAfter(transit.departure)
                : walk.arrival.isBefore(transit.arrival)))
    ? walk
    : transit;

Future<EndpointJourney?> findEndpointJourney(
  NetworkEngine engine,
  List<JourneyEndpoint> origins,
  List<JourneyEndpoint> destinations,
  DateTime target, {
  bool arriveBy = true,
  LiveFeed? live,
  DateTime? now,
  bool Function()? cancelled,
}) async {
  EndpointJourney? best;
  final referenceNow = now ?? DateTime.now();
  if (cancelled?.call() == true || origins.isEmpty || destinations.isEmpty) {
    return null;
  }
  if (!origins.any((o) => destinations.any((d) => o.stop == d.stop))) {
    final result = await engine.routeEndpoints(
      origins,
      destinations,
      target,
      arriveBy: arriveBy,
      live: live,
      now: referenceNow,
    );
    if (cancelled?.call() == true || result == null) return null;
    return EndpointJourney(
      result.journey,
      origins[result.origin],
      destinations[result.destination],
    );
  }
  // Partition the pair matrix into disjoint endpoint groups. Shared nearby
  // stops must never become zero-ride seeds that hide a valid transit journey.
  // Most pairs still share one weighted scan; only overlapping choices split.
  final fixed = arriveBy ? destinations : origins;
  final choices = arriveBy ? origins : destinations;
  final independent = choices
      .where((p) => !fixed.any((q) => q.stop == p.stop))
      .toList();
  final groups = <(List<JourneyEndpoint>, List<JourneyEndpoint>)>[
    if (independent.isNotEmpty) (independent, fixed),
    for (final choice in choices.where(
      (p) => fixed.any((q) => q.stop == p.stop),
    ))
      ([choice], fixed.where((p) => p.stop != choice.stop).toList()),
  ];
  for (final group in groups) {
    if (cancelled?.call() == true) return null;
    final from = arriveBy ? group.$1 : group.$2;
    final to = arriveBy ? group.$2 : group.$1;
    if (from.isEmpty || to.isEmpty) continue;
    final result = await engine.routeEndpoints(
      from,
      to,
      target,
      arriveBy: arriveBy,
      live: live,
      now: referenceNow,
    );
    if (cancelled?.call() == true) return null;
    if (result == null) continue;
    final full = result.journey;
    if (best == null ||
        (arriveBy
            ? full.departure.isAfter(best.journey.departure)
            : full.arrival.isBefore(best.journey.arrival))) {
      best = EndpointJourney(full, from[result.origin], to[result.destination]);
    }
  }
  return best;
}
