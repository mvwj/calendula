import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'place_search.dart';

class LocalAddress {
  final String street, house, orientation, district;
  final double latitude, longitude;
  LocalAddress(List<dynamic> row)
    : street = row[0],
      house = row[1],
      orientation = row[2],
      latitude = (row[3] as num).toDouble(),
      longitude = (row[4] as num).toDouble(),
      district = row[5];
  String get number => orientation.isEmpty ? house : '$house/$orientation';
  String get label => '$street $number, $district';
  late String _key = foldPlace('$street $house $orientation');
  String get key => _key;
}

String addressQuery(String text) =>
    foldPlace(text.replaceAll(RegExp(r'\b\d{3}\s+\d{2}\b'), ''))
        .replaceAll(RegExp(r'\b(praha|prague)\s*\d*\b'), '')
        .replaceAll(
          RegExp(r'\b(czech republic|czechia|ceska republika|cz)\b'),
          '',
        )
        .replaceAll(RegExp(r'\b\d{5}\b'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

class AddressIndex {
  final List<LocalAddress> addresses;
  final String date;
  final Map<String, List<LocalAddress>> _exact = {};
  AddressIndex(Map<String, dynamic> json)
    : addresses = [for (final r in json['addresses']) LocalAddress(r)],
      date = json['date'] {
    final streets = <String, String>{},
        streetQueries = <String, String>{},
        districts = <String, String>{},
        numbers = <String, String>{};
    String joined(Iterable<String> parts) =>
        parts.where((p) => p.isNotEmpty).join(' ');
    for (final a in addresses) {
      // Streets and districts repeat thousands of times. Normalize them once;
      // building the same regular expressions for every full address dominated
      // native startup. Keep the generic normalizer for unusual imported numbers.
      final street = streets.putIfAbsent(a.street, () => foldPlace(a.street)),
          queryStreet = streetQueries.putIfAbsent(
            a.street,
            () => addressQuery(a.street),
          ),
          district = districts.putIfAbsent(
            a.district,
            () => foldPlace(a.district),
          ),
          house = numbers.putIfAbsent(a.house, () => foldPlace(a.house)),
          orientation = numbers.putIfAbsent(
            a.orientation,
            () => foldPlace(a.orientation),
          );
      final number = joined([house, orientation]);
      final ordinary = a.house.length < 5 && a.orientation.length < 5;
      for (final key in {
        joined([street, number, district]),
        ordinary
            ? joined([queryStreet, number])
            : addressQuery('${a.street} ${a.number}'),
        ordinary
            ? joined([queryStreet, house])
            : addressQuery('${a.street} ${a.house}'),
        if (a.orientation.isNotEmpty)
          ordinary
              ? joined([queryStreet, orientation])
              : addressQuery('${a.street} ${a.orientation}'),
      }) {
        (_exact[key] ??= []).add(a);
      }
      a._key = joined([street, house, orientation]);
    }
  }
  static Future<AddressIndex>? _bundled;
  static Future<AddressIndex> load() =>
      _bundled ??= _load().catchError((Object e) {
        _bundled = null;
        throw e;
      });
  static Future<AddressIndex> _load() async {
    final data = await rootBundle.load('assets/prague-addresses.json.gz');
    return compute(
      _decodeAddresses,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  List<LocalAddress> search(String text, {int limit = 6}) {
    final q = addressQuery(text);
    if (q.length < 2) return [];
    final words = q.split(' ');
    final numbers = {
      for (final w in words.where((w) => RegExp(r'^\d').hasMatch(w)))
        w: RegExp('(?:^| )$w'),
    };
    final prefix = <LocalAddress>[], other = <LocalAddress>[];
    for (final a in addresses) {
      if (!words.every(
        (w) => a.key.contains(w) && (numbers[w]?.hasMatch(a.key) ?? true),
      )) {
        continue;
      }
      if (a.key.startsWith(q)) {
        prefix.add(a);
        if (prefix.length == limit) break;
      } else if (other.length < limit) {
        other.add(a);
      }
    }
    return [...prefix, ...other].take(limit).toList();
  }

  LocalAddress? resolve(String text) {
    final exactLabel = _exact[foldPlace(text)] ?? [];
    if (exactLabel.length == 1) return exactLabel.single;
    final matches = _exact[addressQuery(text)] ?? [];
    // Do not silently send the user to a namesake building.
    return matches.length == 1 ? matches.single : null;
  }
}

AddressIndex _decodeAddresses(Uint8List bytes) =>
    AddressIndex(jsonDecode(utf8.decode(gzip.decode(bytes))));
