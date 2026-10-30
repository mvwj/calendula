// Explicit native integration probe. All events, pairing and keys are synthetic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/data/latest.dart' as tzdata;

import 'calendar.dart';
import 'secure_json_store.dart';
import 'sync.dart';

class _EmptyCalendar implements EventRepository {
  @override
  Future<List<CalendarEvent>> load() async => [];
  @override
  Future<void> save(List<CalendarEvent> events) async =>
      throw StateError('The probe must not write a legacy calendar.');
}

class _Probe {
  final Directory directory;
  final String name = 'device-check-${randomSyncId()}';
  late final String profileKey = 'calendula.$name.profile.v1';
  _Probe(this.directory);
  SyncRepository repository() => SyncRepository(
    legacy: _EmptyCalendar(),
    store: SecureJsonStore(name, directory: () async => directory),
    profileStorageKey: profileKey,
    manageBackground: false,
  );
  Future<void> clean() async {
    const secure = FlutterSecureStorage();
    await secure.delete(key: profileKey);
    await secure.delete(key: 'calendula.$name.key.v1');
    // Only an OS-generated temporary directory with our prefix may be removed.
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}calendula-sync-device-';
    if (directory.absolute.path.startsWith(prefix) &&
        !await FileSystemEntity.isLink(directory.path)) {
      await directory.delete(recursive: true);
    }
  }
}

CalendarEvent _event(String id) => CalendarEvent(
  id: id,
  title: 'Synthetic $id · Praha · Календула',
  start: DateTime.utc(2026, 10, 5, 10),
  end: DateTime.utc(2026, 10, 5, 11),
);
CalendarEvent _edit(CalendarEvent event, Map<String, dynamic> fields) =>
    CalendarEvent.fromJson({...event.toJson(), ...fields});
void _require(bool value, String stage) {
  if (!value) throw StateError(stage);
}

/// Hidden Windows process. The control listener handles only synthetic data and
/// requires a random capability; it never loads the owner's calendar/profile.
Future<void> windowsSyncDeviceCheck(List<String> args) async {
  runApp(const SizedBox.shrink());
  final path = args
      .firstWhere((v) => v.startsWith('--check-directory='))
      .substring(18);
  final output = Directory(path);
  await output.create(recursive: true);
  final probe = _Probe(
    await Directory.systemTemp.createTemp('calendula-sync-device-'),
  );
  final repo = probe.repository();
  final checks = <String, dynamic>{
    'personalCalendarRead': false,
    'personalProfileRead': false,
  };
  final done = Completer<bool>();
  HttpServer? control;
  final token = randomSyncId();
  try {
    await repo.load();
    await repo.configure(
      pairing: SyncProfile.create(),
      transport: 'disabled',
      endpoint: '',
    );
    await repo.save([_event('windows')]);
    final addresses = await repo.listenLocal();
    _require(addresses.isNotEmpty, 'No IPv4 interface for diagnostic listener');
    final syncPort = Uri.parse(addresses.first).port;
    control = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final controlUrl = 'http://127.0.0.1:${control.port}/$token';
    await File('${output.path}/ready.json').writeAsString(
      jsonEncode({
        'control': controlUrl,
        'endpoint': 'http://127.0.0.1:$syncPort/calendula/v1/sync',
        'pairing': repo.profile!.pairingCode,
        'syncPort': syncPort,
        'controlPort': control.port,
      }),
      flush: true,
    );
    control.listen((request) async {
      var finish = false;
      try {
        if (request.method != 'POST' ||
            !request.uri.path.startsWith('/$token/')) {
          request.response.statusCode = 404;
          return;
        }
        final action = request.uri.path.substring(token.length + 2);
        final events = await repo.load();
        switch (action) {
          case 'edit':
            _require(events.length == 2, 'bidirectional additions');
            checks['bidirectionalAdd'] = true;
            await repo.save(
              events
                  .map(
                    (e) => e.id == 'windows'
                        ? _edit(e, {'room': 'Windows room'})
                        : e,
                  )
                  .toList(),
            );
          case 'merged':
            final event = events.singleWhere((e) => e.id == 'windows');
            _require(
              event.room == 'Windows room' && event.notes == 'Android notes',
              'independent edits',
            );
            checks['independentEdits'] = true;
          case 'deleted':
            _require(
              events.length == 1 && events.single.id == 'windows',
              'deletion',
            );
            checks['delete'] = true;
          case 'restored':
            _require(events.length == 2, 'Undo');
            checks['undo'] = true;
          case 'conflict':
            await repo.save(
              events
                  .map(
                    (e) => e.id == 'windows'
                        ? _edit(e, {'room': 'Concurrent Windows'})
                        : e,
                  )
                  .toList(),
            );
          case 'conflicted':
            _require(
              repo.document.conflicts.any(
                (c) => c.event == 'windows' && c.field == 'room',
              ),
              'same-field conflict',
            );
            checks['conflictVisible'] = true;
          case 'resolved':
            _require(
              repo.document.conflicts.isEmpty &&
                  events.singleWhere((e) => e.id == 'windows').room ==
                      'Resolved room',
              'conflict resolution',
            );
            checks['conflictResolved'] = true;
          case 'reload':
            final other = probe.repository();
            try {
              final loaded = await other.load();
              _require(
                jsonEncode(loaded.map((e) => e.toJson()).toList()) ==
                        jsonEncode(events.map((e) => e.toJson()).toList()) &&
                    other.profile!.key == repo.profile!.key,
                'Windows vault/profile reload',
              );
              checks['windowsReload'] = true;
            } finally {
              other.dispose();
            }
          case 'finish':
            final body = await utf8.decoder
                .bind(request)
                .join()
                .timeout(const Duration(seconds: 10));
            _require(body.length < 4096, 'report too large');
            checks['android'] = jsonDecode(body);
            checks['passed'] = true;
            finish = true;
          default:
            throw StateError('Unknown check stage');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true}');
      } catch (error) {
        request.response.statusCode = 500;
        checks['errorType'] = error.runtimeType.toString();
        checks['passed'] = false;
        finish = true;
      } finally {
        await request.response.close();
        if (finish && !done.isCompleted) {
          done.complete(checks['passed'] == true);
        }
      }
    });
    await done.future.timeout(const Duration(minutes: 8));
  } catch (error) {
    checks['passed'] = false;
    checks['errorType'] = error.runtimeType.toString();
  } finally {
    await control?.close(force: true);
    await repo.stopListening();
    repo.dispose();
    await probe.clean();
    await File('${output.path}/ready.json')
        .delete()
        .catchError((_) => File(''));
    await File('${output.path}/windows-report.json')
        .writeAsString(jsonEncode(checks), flush: true);
  }
  exit(checks['passed'] == true ? 0 : 1);
}

Future<void> androidSyncDeviceCheck() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const channel = MethodChannel('app.calendula/sync-check');
  final report = <String, dynamic>{
    'personalCalendarRead': false,
    'personalProfileRead': false,
  };
  final probe = _Probe(
    await Directory.systemTemp.createTemp('calendula-sync-device-'),
  );
  var repo = probe.repository();
  final client = http.Client();
  try {
    final encoded = await channel.invokeMethod<String>('config');
    final config =
        jsonDecode(utf8.decode(base64Decode(encoded!))) as Map<String, dynamic>;
    Future<void> control(String action, {String body = ''}) async {
      final response = await client
          .post(Uri.parse('${config['control']}/$action'), body: body)
          .timeout(const Duration(seconds: 15));
      _require(response.statusCode == 200, 'Windows check $action');
    }

    Future<void> exchange() async {
      await repo.synchronize();
      _require(repo.syncError == null && repo.lastSync != null, 'LAN exchange');
    }

    await repo.load();
    await repo.configure(
      pairing: SyncProfile.parse(config['pairing']),
      transport: 'lan',
      endpoint: config['endpoint'],
    );
    await repo.save([_event('android')]);
    await exchange();
    var events = await repo.load();
    _require(events.length == 2, 'Android sees Windows event');
    await control('edit');
    await repo.save(
      events
          .map(
            (e) => e.id == 'windows' ? _edit(e, {'notes': 'Android notes'}) : e,
          )
          .toList(),
    );
    await exchange();
    await control('merged');
    events = await repo.load();
    _require(
      events.singleWhere((e) => e.id == 'windows').room == 'Windows room',
      'Android sees merged room',
    );
    final beforeDelete = [...events];
    await repo.save(events.where((e) => e.id != 'android').toList());
    await exchange();
    await control('deleted');
    await repo.load();
    await repo.save(beforeDelete);
    await exchange();
    await control('restored');
    events = await repo.load();
    await control('conflict');
    await repo.save(
      events
          .map(
            (e) => e.id == 'windows'
                ? _edit(e, {'room': 'Concurrent Android'})
                : e,
          )
          .toList(),
    );
    await exchange();
    await control('conflicted');
    final conflict = repo.document.conflicts.singleWhere(
      (c) => c.event == 'windows' && c.field == 'room',
    );
    await repo.resolve(conflict, 'Resolved room');
    await exchange();
    await control('resolved');
    final packet = await repo.exportPacket();
    _require(
      !packet.contains('Synthetic') && !packet.contains('Android notes'),
      'wire encryption',
    );
    report['encryptedPayload'] = true;
    final corrupt = jsonDecode(packet) as Map<String, dynamic>;
    final mac = base64Decode(corrupt['mac']);
    mac[0] ^= 1;
    corrupt['mac'] = base64Encode(mac);
    final response = await client
        .post(Uri.parse(config['endpoint']), body: jsonEncode(corrupt))
        .timeout(const Duration(seconds: 15));
    _require(response.statusCode == 400, 'corrupt packet rejection');
    report['corruptPacketRejected'] = true;
    final before = jsonEncode(
      repo.document.events().map((e) => e.toJson()).toList(),
    );
    repo.dispose();
    repo = probe.repository();
    final loaded = await repo.load();
    _require(
      jsonEncode(loaded.map((e) => e.toJson()).toList()) == before &&
          repo.mode == 'lan',
      'Android vault/profile reload',
    );
    report['androidReload'] = true;
    await exchange();
    _require(
      jsonEncode(repo.document.events().map((e) => e.toJson()).toList()) ==
          before,
      'repeat exchange after corrupt packet',
    );
    report['repeatExchange'] = true;
    await control('reload');
    report['passed'] = true;
    await control('finish', body: jsonEncode(report));
  } catch (error) {
    report['passed'] = false;
    report['errorType'] = error.runtimeType.toString();
    report['stage'] = error is StateError ? error.message : 'native check';
  } finally {
    client.close();
    repo.dispose();
    await probe.clean();
  }
  await channel.invokeMethod(
    'complete',
    '${report['passed'] == true ? 'PASS' : 'FAIL'}: ${jsonEncode(report)}',
  );
}
