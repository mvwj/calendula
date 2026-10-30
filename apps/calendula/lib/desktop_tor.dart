import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

/// Bundled child process; only app-owned HTTP clients use its proxy.
class DesktopTor {
  static final instance = DesktopTor._();
  DesktopTor._();
  Process? _process;
  int? _port;
  Future<void>? _starting;
  bool _enabled = true;
  DateTime? _liveAttempt, _retry, _checked;
  Map<String, dynamic> _prefs = {};
  Future<void> _loadPrefs() async {
    final dir = await getApplicationSupportDirectory(),
        file = File('${dir.path}/public-desktop-network.json');
    if (await file.exists()) {
      try {
        _prefs = jsonDecode(await file.readAsString());
      } catch (_) {}
    }
    _enabled = _prefs['enabled'] != false;
    _liveAttempt = DateTime.tryParse(_prefs['liveAttempt'] ?? '');
    _retry = DateTime.tryParse(_prefs['retry'] ?? '');
    _checked = DateTime.tryParse(_prefs['checked'] ?? '');
  }

  Future<void> _save() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    await File('${dir.path}/public-desktop-network.json').writeAsString(
      jsonEncode({
        ..._prefs,
        'enabled': _enabled,
        'liveAttempt': _liveAttempt?.toIso8601String(),
        'retry': _retry?.toIso8601String(),
        'checked': _checked?.toIso8601String(),
      }),
      flush: true,
    );
  }

  Future<Map<String, dynamic>> status() async {
    await _loadPrefs();
    return {
      'enabled': _enabled,
      'background': true,
      'liveChecked': _checked?.millisecondsSinceEpoch ?? 0,
      'activeUntil': 0,
      'version': '0.4.9.13',
    };
  }

  Future<void> configure(bool enabled) async {
    await _loadPrefs();
    _enabled = enabled;
    await _save();
    if (!enabled) await stop();
  }

  Future<void> ready() => _starting ??= _start().catchError((Object e) {
    _starting = null;
    throw e;
  });
  Future<void> _start() async {
    await _loadPrefs();
    if (!_enabled) throw StateError('Private networking is paused.');
    if (_process != null && _port != null) return;
    final root = File(Platform.resolvedExecutable).parent,
        executable = File(
          '${File(Platform.resolvedExecutable).parent.path}/tor/tor.exe',
        );
    if (!await executable.exists()) {
      throw StateError(
        'Bundled Tor is missing. Use the complete Calendula folder.',
      );
    }
    final dir = await getApplicationSupportDirectory(),
        data = await Directory('${dir.path}/tor-state').create(recursive: true);
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        port = probe.port;
    await probe.close();
    final process = await Process.start(executable.path, [
      '--DataDirectory',
      data.path,
      '--SocksPort',
      '0',
      '--HTTPTunnelPort',
      '127.0.0.1:$port',
      '--ControlPort',
      '0',
      '--__OwningControllerProcess',
      '$pid',
      '--ClientOnly',
      '1',
      '--SafeLogging',
      '1',
      '--AvoidDiskWrites',
      '1',
      '--GeoIPFile',
      '${root.path}/tor/geoip',
      '--GeoIPv6File',
      '${root.path}/tor/geoip6',
      '--Log',
      'notice stdout',
    ], workingDirectory: root.path);
    _process = process;
    final done = Completer<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.contains('Bootstrapped 100%') && !done.isCompleted) {
            _port = port;
            done.complete();
          }
        });
    process.stderr.drain<void>();
    process.exitCode.then((_) {
      if (!done.isCompleted) {
        done.completeError(StateError('Tor stopped before connecting.'));
      }
      if (_process == process) {
        _process = null;
        _port = null;
        _starting = null;
      }
    });
    try {
      await done.future.timeout(const Duration(seconds: 100));
      if (_port == null) throw StateError('Tor proxy port is unavailable.');
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<http.Client> client() async {
    await _loadPrefs();
    if (!_enabled) throw StateError('Private networking is paused.');
    await ready();
    if (!_enabled || _port == null) {
      throw StateError('Private networking is paused.');
    }
    final port = _port!;
    final socket = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..findProxy = ((uri) => 'PROXY 127.0.0.1:$port');
    return IOClient(socket); // No DIRECT alternative; normal TLS validation.
  }

  Future<int> imapProxyPort() async {
    await _loadPrefs();
    if (!_enabled) throw StateError('Private networking is paused.');
    await ready();
    if (_port == null) throw StateError('Private proxy is unavailable.');
    return _port!;
  }

  Future<http.Response> request(
    String verb,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    int maximum = 5 * 1024 * 1024,
  }) async {
    final client = await this.client();
    try {
      final request = http.Request(verb, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body != null) request.body = body;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 45));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        if (bytes.length + chunk.length > maximum) {
          throw const FormatException(
            'Private response exceeds its size limit.',
          );
        }
        bytes.addAll(chunk);
      }
      return http.Response.bytes(
        bytes,
        response.statusCode,
        headers: response.headers,
      );
    } finally {
      client.close();
    }
  }

  Future<List<int>> live() async {
    await _loadPrefs();
    final now = DateTime.now(),
        dir = await getApplicationSupportDirectory(),
        file = File('${dir.path}/public-desktop-live.pb');
    if ((_retry?.isAfter(now) ?? false) ||
        (_liveAttempt != null &&
            now.difference(_liveAttempt!).inSeconds < 60)) {
      if (await file.exists()) return file.readAsBytes();
      throw StateError('Private refresh is waiting for its retry time.');
    }
    _liveAttempt = now;
    await _save();
    try {
      final r = await request(
        'GET',
        Uri.parse(
          'https://api.golemio.cz/v2/vehiclepositions/gtfsrt/trip_updates.pb',
        ),
        maximum: 8 * 1024 * 1024,
      );
      if (r.statusCode != 200) {
        final retry = int.tryParse(r.headers['retry-after'] ?? '');
        _retry = now.add(
          Duration(
            seconds:
                retry?.clamp(60, 86400) ??
                (r.statusCode == 401 || r.statusCode == 403 ? 86400 : 300),
          ),
        );
        throw StateError('PID returned HTTP ${r.statusCode}.');
      }
      await file.writeAsBytes(r.bodyBytes, flush: true);
      _checked = DateTime.now();
      _retry = null;
      await _save();
      return r.bodyBytes;
    } catch (_) {
      _retry ??= now.add(const Duration(minutes: 2));
      await _save();
      rethrow;
    }
  }

  Future<Uint8List?> cachedLive() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/public-desktop-live.pb');
    if (!await file.exists() || await file.length() > 8 * 1024 * 1024) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<String> google(String key, String body) async {
    if (!RegExp(r'^AIza[A-Za-z0-9_-]{20,100}$').hasMatch(key) ||
        body.length > 2048) {
      throw const FormatException('Enter a valid Google Maps key.');
    }
    await _loadPrefs();
    final now = DateTime.now(),
        today = now.toUtc().toIso8601String().substring(0, 10);
    if (_prefs['googleDay'] != today) {
      _prefs['googleDay'] = today;
      _prefs['googleCount'] = 0;
    }
    if ((_prefs['googleCount'] as int? ?? 0) >= 80) {
      throw StateError(
        'This device’s 80-request daily Google budget is exhausted.',
      );
    }
    final retry = DateTime.tryParse(_prefs['googleRetry'] ?? ''),
        attempted = DateTime.tryParse(_prefs['googleAttempt'] ?? '');
    if (retry?.isAfter(now) == true ||
        (attempted != null && now.difference(attempted).inSeconds < 5)) {
      throw StateError('Google refresh is paused. Try later.');
    }
    _prefs['googleAttempt'] = now.toIso8601String();
    _prefs['googleCount'] = (_prefs['googleCount'] as int? ?? 0) + 1;
    await _save();
    try {
      final response = await request(
        'POST',
        Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': key,
          'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters,routes.legs.steps.travelMode,routes.legs.steps.staticDuration,routes.legs.steps.transitDetails,routes.legs.steps.navigationInstruction',
        },
        body: body,
        maximum: 2 * 1024 * 1024,
      );
      if (response.statusCode != 200) {
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        _prefs['googleRetry'] = now
            .add(
              Duration(
                seconds:
                    (seconds ??
                            (response.statusCode == 401 ||
                                    response.statusCode == 403
                                ? 86400
                                : response.statusCode == 429
                                ? 900
                                : 60))
                        .clamp(60, 86400),
              ),
            )
            .toIso8601String();
        throw StateError(
          'Google Routes returned HTTP ${response.statusCode}. Check access and quota.',
        );
      }
      _prefs['googleRetry'] = null;
      await _save();
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      _prefs['googleRetry'] ??= now
          .add(const Duration(minutes: 1))
          .toIso8601String();
      await _save();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> check() async {
    final r = await request(
      'GET',
      Uri.parse('https://check.torproject.org/api/ip'),
      maximum: 2048,
    );
    final j = jsonDecode(r.body);
    if (r.statusCode != 200 || j['IsTor'] != true) {
      throw StateError(
        'Tor verification failed. Networking remains private-only.',
      );
    }
    return {'ip': j['IP']};
  }

  Future<void> stop() async {
    _process?.kill();
    _process = null;
    _port = null;
    _starting = null;
  }
}

class DesktopPrivateClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = utf8.decode(await request.finalize().toBytes());
    final r = await DesktopTor.instance.request(
      request.method,
      request.url,
      headers: request.headers,
      body: body.isEmpty ? null : body,
    );
    return http.StreamedResponse(
      Stream.value(r.bodyBytes),
      r.statusCode,
      headers: r.headers,
    );
  }
}
