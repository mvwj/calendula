import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'network_router.dart';
import 'private_network.dart';
import 'desktop_tor.dart';

class GoogleRoutes {
  static const _storage = FlutterSecureStorage();
  static const keyName = 'calendula.google.routes.key.v1';
  static Future<String?> key() => _storage.read(key: keyName);
  static Future<void> saveKey(String value) => value.trim().isEmpty
      ? _storage.delete(key: keyName)
      : _storage.write(key: keyName, value: value.trim());
  static Map<String, dynamic> request(
    Map<String, dynamic> from,
    Map<String, dynamic> to,
    DateTime target, {
    bool arriveBy = true,
  }) => {
    'origin': from,
    'destination': to,
    'travelMode': 'TRANSIT',
    'computeAlternativeRoutes': true,
    'languageCode': 'en',
    arriveBy ? 'arrivalTime' : 'departureTime': target
        .toUtc()
        .toIso8601String(),
  };
  static Future<List<NetworkJourney>> route(
    Map<String, dynamic> from,
    Map<String, dynamic> to,
    DateTime target, {
    bool arriveBy = true,
  }) async {
    final secret = await key();
    if (secret == null || secret.isEmpty) {
      throw StateError('Add a Google Maps key first.');
    }
    final body = jsonEncode(request(from, to, target, arriveBy: arriveBy));
    final raw = Platform.isWindows
        ? await DesktopTor.instance.google(secret, body)
        : await privateTransitChannel.invokeMethod<String>('google', {
            'key': secret,
            'body': body,
          });
    if (raw == null) throw StateError('No Google route response.');
    return decode(jsonDecode(raw), target, arriveBy: arriveBy);
  }

  static int seconds(String? value) {
    if (value == null || !RegExp(r'^\d+(\.\d+)?s$').hasMatch(value)) {
      throw const FormatException('Invalid route duration.');
    }
    return double.parse(value.substring(0, value.length - 1)).ceil();
  }

  static List<NetworkJourney> decode(
    Map<String, dynamic> response,
    DateTime target, {
    bool arriveBy = true,
  }) {
    final results = <NetworkJourney>[];
    for (final route in (response['routes'] as List? ?? []).take(4)) {
      final steps = [
        for (final leg in route['legs'] ?? []) ...leg['steps'] as List,
      ];
      if (steps.isEmpty || steps.length > 300) continue;
      DateTime? firstDeparture;
      var leadingWalk = 0;
      for (final step in steps) {
        if (step['transitDetails'] != null) {
          firstDeparture = DateTime.parse(
            step['transitDetails']['stopDetails']['departureTime'],
          );
          break;
        }
        leadingWalk += seconds(step['staticDuration']);
      }
      if (firstDeparture == null) continue;
      var cursor = firstDeparture.subtract(Duration(seconds: leadingWalk));
      final legs = <JourneyLeg>[];
      for (final step in steps) {
        final transit = step['transitDetails'];
        if (transit != null) {
          final stop = transit['stopDetails'], line = transit['transitLine'];
          final departure = DateTime.parse(stop['departureTime']),
              arrival = DateTime.parse(stop['arrivalTime']);
          if (arrival.isBefore(departure) || departure.isBefore(cursor)) {
            legs.clear();
            break;
          }
          final type = line['vehicle']?['type'];
          final mode = switch (type) {
            'SUBWAY' => 1,
            'TRAM' || 'LIGHT_RAIL' => 0,
            'RAIL' ||
            'HEAVY_RAIL' ||
            'COMMUTER_TRAIN' ||
            'HIGH_SPEED_TRAIN' => 2,
            'FERRY' => 4,
            'TROLLEYBUS' => 11,
            _ => 3,
          };
          legs.add(
            JourneyLeg(
              stop['departureStop']['name'],
              stop['arrivalStop']['name'],
              line['nameShort'] ?? line['name'] ?? '',
              transit['headsign'] ?? '',
              '',
              mode,
              departure,
              arrival,
            ),
          );
          cursor = arrival;
        } else {
          final duration = seconds(step['staticDuration']);
          final instruction =
              (step['navigationInstruction']?['instructions'] ?? 'Walk')
                  .toString()
                  .replaceAll(RegExp(r'<[^>]*>'), '');
          final end = cursor.add(Duration(seconds: duration));
          legs.add(
            JourneyLeg('Walk', instruction, '', '', '', -1, cursor, end),
          );
          cursor = end;
        }
      }
      if (legs.isEmpty) continue;
      final journey = NetworkJourney(legs);
      if (arriveBy
          ? journey.arrival.isAfter(target)
          : journey.departure.isBefore(target)) {
        continue;
      }
      results.add(journey);
    }
    results.sort(
      (a, b) => arriveBy
          ? b.departure.compareTo(a.departure)
          : a.arrival.compareTo(b.arrival),
    );
    return results;
  }
}
