import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'desktop_tor.dart';

const privateTransitChannel = MethodChannel('app.calendula/private-transit');

class PrivateNetwork {
  static Future<Map<String, dynamic>> status() async {
    if (Platform.isWindows) return DesktopTor.instance.status();
    if (!Platform.isAndroid) {
      return {
        'enabled': false,
        'background': false,
        'transport': 'Private transport is not connected on this platform yet.',
      };
    }
    return Map<String, dynamic>.from(
      await privateTransitChannel.invokeMapMethod<String, dynamic>('status') ??
          {},
    );
  }

  // The native gateway permits only fixed, allowlisted endpoints. Requests to
  // PID cannot fall back to Dart's direct socket path when Tor fails.
  static Future<http.StreamedResponse> timetableResponse({
    Map<String, String> headers = const {},
  }) async {
    if (Platform.isWindows) {
      final client = await DesktopTor.instance.client();
      final http.StreamedResponse response;
      try {
        response = await client
            .send(
              http.Request('GET', Uri.parse('https://data.pid.cz/PID_GTFS.zip'))
                ..followRedirects = false
                ..headers.addAll(headers),
            )
            .timeout(const Duration(seconds: 45));
      } catch (_) {
        client.close();
        rethrow;
      }
      return http.StreamedResponse(
        _closingStream(response.stream, client),
        response.statusCode,
        headers: response.headers,
      );
    }
    final r = await privateTransitChannel.invokeMapMethod<String, dynamic>(
      'timetable',
    );
    if (r == null || r['path'] is! String) {
      throw const FormatException('Private timetable download failed.');
    }
    final f = File(r['path']);
    return http.StreamedResponse(
      f.openRead(),
      200,
      contentLength: await f.length(),
      headers: {
        if (r['etag'] is String) 'etag': r['etag'],
        if (r['modified'] is String) 'last-modified': r['modified'],
      },
    );
  }

  static Stream<List<int>> _closingStream(
    Stream<List<int>> stream,
    http.Client client,
  ) async* {
    try {
      yield* stream;
    } finally {
      client.close();
    }
  }
}
