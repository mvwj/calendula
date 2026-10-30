import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'calendar.dart';
import 'secure_json_store.dart';

String randomSyncId() => base64Url
    .encode(List.generate(18, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

class SyncOperation {
  final String actor, event;
  final int counter;
  final Map<String, int> dependencies;
  final Map<String, dynamic> fields;
  String get id => '$actor:$counter';
  SyncOperation(
    this.actor,
    this.counter,
    this.event,
    this.dependencies,
    this.fields,
  );
  Map<String, dynamic> toJson() => {
    'actor': actor,
    'counter': counter,
    'event': event,
    'dependencies': dependencies,
    'fields': fields,
  };
  factory SyncOperation.fromJson(Map<String, dynamic> j) {
    final o = SyncOperation(
      j['actor'],
      j['counter'],
      j['event'],
      Map<String, int>.from(j['dependencies']),
      Map<String, dynamic>.from(j['fields']),
    );
    const allowed = {
      '_alive',
      'title',
      'start',
      'end',
      'venue',
      'address',
      'room',
      'floor',
      'category',
      'sessionType',
      'locationSource',
      'placeProfile',
      'notes',
      'courseCode',
      'travelMinutes',
      'bufferMinutes',
      'sample',
      'allDay',
      'originStop',
      'destinationStop',
      'originWalkMinutes',
      'destinationWalkMinutes',
    };
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(o.actor) ||
        o.counter < 1 ||
        o.counter > 1000000 ||
        o.event.isEmpty ||
        o.event.length > 256 ||
        o.dependencies.length > 30 ||
        o.fields.isEmpty ||
        o.fields.keys.any((k) => !allowed.contains(k)) ||
        jsonEncode(j).length > 32000 ||
        o.dependencies.values.any((v) => v < 0 || v > 1000000)) {
      throw const FormatException('Invalid synchronization operation.');
    }
    return o;
  }
  bool follows(SyncOperation old) =>
      dependencies[old.actor] != null &&
      dependencies[old.actor]! >= old.counter;
}

class SyncConflict {
  final String event, field;
  final List<SyncOperation> versions;
  SyncConflict(this.event, this.field, this.versions);
}

class SyncDocument {
  final List<SyncOperation> operations;
  final Map<String, int> vector = {};
  final Map<String, Map<String, List<SyncOperation>>> registers = {};
  final List<SyncConflict> conflicts = [];
  SyncDocument(this.operations) {
    if (operations.length > 20000) {
      throw const FormatException(
        'Synchronization history exceeds 20,000 changes.',
      );
    }
    final pending = {for (final o in operations) o.id: o};
    if (pending.length != operations.length) {
      throw const FormatException('Duplicate synchronization operation.');
    }
    final degree = <String, int>{}, followers = <String, List<String>>{};
    for (final o in operations) {
      final parents = <String>{
        if (o.counter > 1) '${o.actor}:${o.counter - 1}',
        for (final e in o.dependencies.entries)
          if (e.value > 0) '${e.key}:${e.value}',
      };
      if (parents.any((id) => !pending.containsKey(id) || id == o.id)) {
        throw const FormatException(
          'Synchronization changes are missing dependencies.',
        );
      }
      degree[o.id] = parents.length;
      for (final id in parents) {
        followers.putIfAbsent(id, () => []).add(o.id);
      }
    }
    final ready = operations.where((o) => degree[o.id] == 0).toList();
    for (var index = 0; index < ready.length; index++) {
      final o = ready[index];
      final event = registers.putIfAbsent(o.event, () => {});
      for (final field in o.fields.keys) {
        final versions = event.putIfAbsent(field, () => []);
        versions.removeWhere(o.follows);
        versions.add(o);
        versions.sort((a, b) => a.id.compareTo(b.id));
      }
      vector[o.actor] = o.counter;
      pending.remove(o.id);
      for (final id in followers[o.id] ?? <String>[]) {
        degree[id] = degree[id]! - 1;
        if (degree[id] == 0) ready.add(pending[id]!);
      }
    }
    if (pending.isNotEmpty) {
      throw const FormatException(
        'Synchronization changes are missing dependencies. No partial calendar was applied.',
      );
    }
    for (final e in registers.entries) {
      for (final f in e.value.entries) {
        if (f.value.length > 1 &&
            f.value.map((o) => jsonEncode(o.fields[f.key])).toSet().length >
                1) {
          conflicts.add(SyncConflict(e.key, f.key, f.value));
        }
      }
    }
  }
  List<CalendarEvent> events() {
    final result = <CalendarEvent>[];
    for (final e in registers.entries) {
      final alive = e.value['_alive'];
      // Concurrent edit/delete stays visible until the user resolves the conflict.
      if (alive == null || !alive.any((o) => o.fields['_alive'] == true)) {
        continue;
      }
      final j = <String, dynamic>{'id': e.key};
      for (final f in e.value.entries) {
        if (f.key != '_alive') j[f.key] = f.value.first.fields[f.key];
      }
      result.add(CalendarEvent.fromJson(j));
    }
    return result..sort((a, b) => a.start.compareTo(b.start));
  }
}

class SyncProfile {
  final String calendarId, key;
  SyncProfile(this.calendarId, this.key) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(calendarId) ||
        base64Url.decode(base64Url.normalize(key)).length != 32) {
      throw const FormatException('Invalid pairing code.');
    }
  }
  static SyncProfile create() => SyncProfile(
    randomSyncId(),
    base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256))),
  );
  String get pairingCode =>
      'calendula1.${base64Url.encode(utf8.encode(jsonEncode({'calendarId': calendarId, 'key': key}))).replaceAll('=', '')}';
  factory SyncProfile.parse(String code) {
    if (!code.startsWith('calendula1.') || code.length > 500) {
      throw const FormatException('Invalid pairing code.');
    }
    final j = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(code.substring(11)))),
    );
    return SyncProfile(j['calendarId'], j['key']);
  }
  Map<String, dynamic> toJson() => {'calendarId': calendarId, 'key': key};
}

class SyncEnvelope {
  final SyncProfile profile;
  SyncEnvelope(this.profile);
  Future<String> seal(Map<String, dynamic> data) async {
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(data)),
      secretKey: SecretKey(base64Url.decode(base64Url.normalize(profile.key))),
      aad: utf8.encode('calendula-sync:1:${profile.calendarId}'),
    );
    return jsonEncode({
      'version': 1,
      'calendarId': profile.calendarId,
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText),
    });
  }

  Future<Map<String, dynamic>> open(String packet) async {
    if (packet.length > 8 * 1024 * 1024) {
      throw const FormatException('Synchronization packet is too large.');
    }
    final j = jsonDecode(packet);
    if (j['version'] != 1 || j['calendarId'] != profile.calendarId) {
      throw const FormatException(
        'Synchronization belongs to another calendar.',
      );
    }
    final bytes = await AesGcm.with256bits().decrypt(
      SecretBox(
        base64Decode(j['ciphertext']),
        nonce: base64Decode(j['nonce']),
        mac: Mac(base64Decode(j['mac'])),
      ),
      secretKey: SecretKey(base64Url.decode(base64Url.normalize(profile.key))),
      aad: utf8.encode('calendula-sync:1:${profile.calendarId}'),
    );
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }
}

abstract class SyncTransport {
  Future<Map<String, String>> download(Set<String> seen);
  Future<void> upload(String name, String packet);
  void close();
}

class FolderSyncTransport implements SyncTransport {
  final Directory folder;
  FolderSyncTransport(String path) : folder = Directory(path);
  @override
  Future<Map<String, String>> download(Set<String> seen) async {
    await folder.create(recursive: true);
    final result = <String, String>{};
    var count = 0;
    await for (final file in folder.list(followLinks: false)) {
      final name = file.uri.pathSegments.last;
      if (file is! File ||
          !RegExp(r'^[A-Za-z0-9_-]{24}\.calsync$').hasMatch(name)) {
        continue;
      }
      if (++count > 5000) {
        throw const FormatException('Sync folder exceeds 5,000 packets.');
      }
      if (seen.contains(name)) continue;
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('Sync packet exceeds its bound.');
      }
      result[name] = await file.readAsString();
    }
    return result;
  }

  @override
  Future<void> upload(String name, String packet) async {
    await folder.create(recursive: true);
    final file = File('${folder.path}/$name');
    if (await file.exists()) {
      throw const FormatException('Sync packet already exists.');
    }
    final pending = File('${file.path}.pending');
    await pending.writeAsString(packet, flush: true);
    await pending.rename(file.path);
  }

  @override
  void close() {}
}

class SyncRetry implements Exception {
  final Duration delay;
  const SyncRetry(this.delay);
}

class WebDavSyncTransport implements SyncTransport {
  final Uri folder;
  final String username, password;
  final http.Client client;
  WebDavSyncTransport(
    String url,
    this.username,
    this.password, {
    http.Client? client,
  }) : folder = Uri.parse(url.endsWith('/') ? url : '$url/'),
       client = client ?? http.Client() {
    if (folder.scheme != 'https' ||
        folder.host.isEmpty ||
        folder.userInfo.isNotEmpty ||
        folder.hasQuery ||
        folder.hasFragment) {
      throw const FormatException(
        'WebDAV requires an HTTPS folder URL without embedded credentials.',
      );
    }
  }
  Future<http.Response> _request(
    String verb,
    Uri uri, {
    String body = '',
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request(verb, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        ...headers,
      })
      ..body = body;
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 45));
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 45),
    )) {
      if (bytes.length + chunk.length > 8 * 1024 * 1024) {
        throw const FormatException('WebDAV response exceeds its bound.');
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode == 429 || response.statusCode >= 500) {
      final value = response.headers['retry-after'];
      var seconds = int.tryParse(value ?? '');
      if (seconds == null && value != null) {
        try {
          seconds = HttpDate.parse(value).difference(DateTime.now()).inSeconds;
        } catch (_) {}
      }
      throw SyncRetry(Duration(seconds: (seconds ?? 300).clamp(60, 86400)));
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const SyncRetry(Duration(hours: 24));
    }
    return http.Response.bytes(
      bytes,
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  Future<Map<String, String>> download(Set<String> seen) async {
    final list = await _request(
      'PROPFIND',
      folder,
      headers: {'Depth': '1', 'Content-Type': 'application/xml'},
      body: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
    );
    if (list.statusCode == 404) {
      final create = await _request('MKCOL', folder);
      if (![201, 405].contains(create.statusCode)) {
        throw const FormatException('Create the parent cloud folder first.');
      }
      return {};
    }
    if (list.statusCode != 207) {
      throw FormatException(
        'WebDAV returned HTTP ${list.statusCode}. Check folder URL and app password.',
      );
    }
    final text = utf8.decode(list.bodyBytes);
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      throw const FormatException('WebDAV XML entities are rejected.');
    }
    final hrefs = XmlDocument.parse(text).descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'href')
        .map((e) => e.innerText)
        .toList();
    if (hrefs.length > 5001) {
      throw const FormatException('Cloud folder exceeds 5,000 packets.');
    }
    final result = <String, String>{};
    for (final href in hrefs) {
      final uri = folder.resolve(href), name = uri.pathSegments.last;
      if (uri.origin != folder.origin ||
          !uri.path.startsWith(folder.path) ||
          !RegExp(r'^[A-Za-z0-9_-]{24}\.calsync$').hasMatch(name) ||
          seen.contains(name)) {
        continue;
      }
      final r = await _request('GET', uri);
      if (r.statusCode != 200) {
        throw const FormatException('Cloud packet could not be read.');
      }
      result[name] = utf8.decode(r.bodyBytes);
    }
    return result;
  }

  @override
  Future<void> upload(String name, String packet) async {
    final r = await _request(
      'PUT',
      folder.resolve(name),
      headers: {
        'Content-Type': 'application/octet-stream',
        'If-None-Match': '*',
      },
      body: packet,
    );
    if (![200, 201, 204].contains(r.statusCode)) {
      throw FormatException('Cloud upload returned HTTP ${r.statusCode}.');
    }
  }

  @override
  void close() => client.close();
}

class SyncRepository extends ChangeNotifier implements EventRepository {
  final EventRepository legacy;
  final SecureJsonStore store;
  final FlutterSecureStorage secure;
  final String profileStorageKey;
  final bool manageBackground;
  SyncRepository({
    required this.legacy,
    SecureJsonStore? store,
    this.secure = const FlutterSecureStorage(),
    this.profileStorageKey = 'calendula.sync.profile.v1',
    this.manageBackground = true,
  }) : store = store ?? SecureJsonStore('sync');
  String actor = randomSyncId();
  List<SyncOperation> operations = [];
  List<CalendarEvent>? _viewed;
  Map<String, int> _viewedVector = {};
  Set<String> published = {}, seen = {};
  SyncProfile? profile;
  String mode = 'disabled', url = '', username = '', password = '';
  bool initialized = false, syncing = false;
  DateTime? lastSync, retryAt, lastAttempt;
  String? syncError;
  Future<void> _tail = Future.value();
  HttpServer? _listener;
  Future<T> _serial<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      RandomAccessFile? lock;
      int? lease;
      late T value;
      Object? failure;
      StackTrace? failureTrace;
      try {
        if (Platform.isAndroid) {
          lease = await const MethodChannel('app.calendula/sync-guard')
              .invokeMethod<int>('acquire');
        } else {
          final dir = await store.directory();
          await dir.create(recursive: true);
          lock = await File('${dir.path}/${store.name}.transaction.lock')
              .open(mode: FileMode.append);
          await lock.lock(FileLock.blockingExclusive);
        }
        if (initialized) {
          final disk = await store.read();
          if (disk != null) {
            actor = disk['actor'];
            operations = (disk['operations'] as List)
                .map(
                  (o) => SyncOperation.fromJson(Map<String, dynamic>.from(o)),
                )
                .toList();
            published = Set<String>.from(disk['published']);
            seen = Set<String>.from(disk['seen']);
            lastSync = DateTime.tryParse(disk['lastSync'] ?? '');
            retryAt = DateTime.tryParse(disk['retryAt'] ?? '');
            lastAttempt = DateTime.tryParse(disk['lastAttempt'] ?? '');
          }
        }
        value = await action();
      } catch (e, s) {
        failure = e;
        failureTrace = s;
      } finally {
        try {
          if (lease != null) {
            await const MethodChannel('app.calendula/sync-guard')
                .invokeMethod('release', lease);
          }
          if (lock != null) {
            try {
              await lock.unlock();
            } finally {
              await lock.close();
            }
          }
        } catch (e, s) {
          failure ??= e;
          failureTrace ??= s;
        }
      }
      if (failure != null) {
        done.completeError(failure, failureTrace);
      } else {
        done.complete(value);
      }
    });
    return done.future;
  }

  SyncDocument get document => SyncDocument(operations);
  Future<void> _persist() => store.write({
    'version': 1,
    'actor': actor,
    'operations': operations.map((o) => o.toJson()).toList(),
    'published': published.toList(),
    'seen': seen.toList(),
    'lastSync': lastSync?.toIso8601String(),
    'retryAt': retryAt?.toIso8601String(),
    'lastAttempt': lastAttempt?.toIso8601String(),
  });
  @override
  Future<List<CalendarEvent>> load() => _serial(() async {
    if (!initialized) {
      final j = await store.read();
      if (j != null) {
        actor = j['actor'];
        operations = (j['operations'] as List)
            .map((o) => SyncOperation.fromJson(Map<String, dynamic>.from(o)))
            .toList();
        published = Set<String>.from(j['published']);
        seen = Set<String>.from(j['seen']);
        lastSync = DateTime.tryParse(j['lastSync'] ?? '');
        retryAt = DateTime.tryParse(j['retryAt'] ?? '');
        lastAttempt = DateTime.tryParse(j['lastAttempt'] ?? '');
        document.events();
      } else {
        final old = await legacy.load();
        var n = 0;
        for (final e in old) {
          operations.add(
            SyncOperation(
              actor,
              ++n,
              e.id,
              {actor: n - 1},
              {'_alive': true, ...e.toJson()..remove('id')},
            ),
          );
        }
        await _persist();
      }
      final config = await secure.read(key: profileStorageKey);
      if (config != null) {
        final p = jsonDecode(config);
        profile = SyncProfile(p['calendarId'], p['key']);
        mode = p['mode'] ?? 'disabled';
        url = p['url'] ?? '';
        username = p['username'] ?? '';
        password = p['password'] ?? '';
      }
      initialized = true;
    }
    final current = document;
    _viewed = current.events();
    _viewedVector = {...current.vector};
    return [..._viewed!];
  });
  @override
  Future<void> save(List<CalendarEvent> events) => _serial(() async {
    if (!initialized) throw StateError('Calendar is not loaded.');
    // Compare user edits with the version they actually saw. A headless/other
    // process may have added or edited records since that view was loaded.
    final old = {for (final e in _viewed ?? document.events()) e.id: e},
        next = {for (final e in events) e.id: e};
    var vector = Map<String, int>.from(_viewedVector),
        counter = document.vector[actor] ?? 0;
    vector[actor] = counter;
    final added = <SyncOperation>[];
    void add(String id, Map<String, dynamic> fields) {
      if (fields.isEmpty) return;
      added.add(SyncOperation(actor, ++counter, id, {...vector}, fields));
      vector[actor] = counter;
    }

    for (final e in next.values) {
      CalendarEvent.fromJson(e.toJson());
      final before = old[e.id]?.toJson(), after = e.toJson()..remove('id');
      final fields = <String, dynamic>{};
      for (final f in after.entries) {
        if (before == null ||
            jsonEncode(before[f.key]) != jsonEncode(f.value)) {
          fields[f.key] = f.value;
        }
      }
      if (fields.isNotEmpty) {
        if (fields.containsKey('start') || fields.containsKey('end')) {
          fields['start'] = after['start'];
          fields['end'] = after['end'];
        }
        fields['_alive'] = true;
        add(e.id, fields);
      }
    }
    for (final id in old.keys.where((id) => !next.containsKey(id))) {
      add(id, {'_alive': false});
    }
    final previous = operations;
    operations = [...operations, ...added];
    try {
      document.events();
      await _persist();
      _viewed = document.events();
      _viewedVector = {...document.vector};
    } catch (_) {
      operations = previous;
      rethrow;
    }
    notifyListeners();
  });
  Future<List<CalendarEvent>> reloadFromDisk() => _serial(() async {
    final value = await store.read();
    if (value == null) return document.events();
    final next = (value['operations'] as List)
        .map((o) => SyncOperation.fromJson(Map<String, dynamic>.from(o)))
        .toList();
    final events = SyncDocument(next).events();
    actor = value['actor'];
    operations = next;
    published = Set<String>.from(value['published']);
    seen = Set<String>.from(value['seen']);
    return events;
  });
  Future<void> configure({
    required SyncProfile pairing,
    required String transport,
    required String endpoint,
    String user = '',
    String secret = '',
  }) => _serial(() async {
    if (!{'disabled', 'folder', 'webdav', 'lan'}.contains(transport)) {
      throw const FormatException('Unknown synchronization transport.');
    }
    if (profile != null &&
        profile!.calendarId != pairing.calendarId &&
        mode != 'disabled') {
      throw const FormatException(
        'Disconnect current sync before pairing another calendar.',
      );
    }
    if (transport == 'webdav') {
      final t = WebDavSyncTransport(endpoint, user, secret);
      t.close();
    }
    if (transport == 'lan') {
      final u = Uri.parse(endpoint);
      final ip = InternetAddress.tryParse(u.host), bytes = ip?.rawAddress;
      final private =
          bytes != null &&
          bytes.length == 4 &&
          (bytes[0] == 10 ||
              bytes[0] == 127 ||
              (bytes[0] == 192 && bytes[1] == 168) ||
              (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31));
      if (u.scheme != 'http' ||
          !private ||
          u.userInfo.isNotEmpty ||
          u.path != '/calendula/v1/sync' ||
          u.hasQuery ||
          u.hasFragment) {
        throw const FormatException(
          'Use the local device URL shown by Calendula.',
        );
      }
    }
    await secure.write(
      key: profileStorageKey,
      value: jsonEncode({
        ...pairing.toJson(),
        'mode': transport,
        'url': endpoint,
        'username': user,
        'password': secret,
      }),
    );
    if (profile?.calendarId != pairing.calendarId ||
        mode != transport ||
        url != endpoint) {
      published = {};
      seen = {};
    }
    profile = pairing;
    mode = transport;
    url = endpoint;
    username = user;
    password = secret;
    syncError = null;
    retryAt = null;
    lastAttempt = null;
    await _persist();
    notifyListeners();
    if (Platform.isAndroid && manageBackground) {
      await const MethodChannel('app.calendula/sync-guard')
          .invokeMethod('configureBackground', transport == 'webdav');
    }
  });
  Future<void> mergePackets(Map<String, String> packets) => _serial(() async {
    if (profile == null) throw StateError('Pair devices first.');
    final all = {for (final o in operations) o.id: o};
    for (final p in packets.entries) {
      final j = await SyncEnvelope(profile!).open(p.value);
      for (final raw in j['operations'] as List) {
        final o = SyncOperation.fromJson(Map<String, dynamic>.from(raw));
        if (all.containsKey(o.id) &&
            jsonEncode(all[o.id]!.toJson()) != jsonEncode(o.toJson())) {
          throw const FormatException('Conflicting operation identity.');
        }
        all[o.id] = o;
      }
    }
    final next = all.values.toList();
    SyncDocument(next).events();
    final previous = operations, previousSeen = seen;
    operations = next;
    seen = {...seen, ...packets.keys};
    try {
      await _persist();
    } catch (_) {
      operations = previous;
      seen = previousSeen;
      rethrow;
    }
    notifyListeners();
  });
  Future<void> resolve(SyncConflict conflict, Object? value) =>
      _serial(() async {
        final d = document, counter = (d.vector[actor] ?? 0) + 1;
        final op = SyncOperation(
          actor,
          counter,
          conflict.event,
          {...d.vector},
          {conflict.field: value},
        );
        final previous = operations;
        operations = [...operations, op];
        try {
          document.events();
          await _persist();
        } catch (_) {
          operations = previous;
          rethrow;
        }
        notifyListeners();
      });
  Future<String> exportPacket() => _serial(() async {
    if (profile == null) throw StateError('Create a pairing code first.');
    return SyncEnvelope(profile!)
        .seal({'operations': operations.map((o) => o.toJson()).toList()});
  });

  Future<void> synchronize() async {
    if (syncing || mode == 'disabled' || profile == null) return;
    final now = DateTime.now();
    if (retryAt?.isAfter(now) == true) return;
    syncing = true;
    notifyListeners();
    SyncTransport? transport;
    try {
      final allowed = await _serial(() async {
        final current = DateTime.now();
        if (retryAt?.isAfter(current) == true ||
            (mode == 'webdav' &&
                lastAttempt != null &&
                current.difference(lastAttempt!).inSeconds < 60)) {
          return false;
        }
        lastAttempt = current;
        await _persist();
        return true;
      });
      if (!allowed) return;
      syncError = null;
      if (mode == 'lan') {
        await _lanExchange();
      } else {
        transport = mode == 'folder'
            ? FolderSyncTransport(url)
            : WebDavSyncTransport(url, username, password);
        final packets = await transport.download(seen);
        if (packets.isNotEmpty) await mergePackets(packets);
        final unpublished = operations
            .where((o) => !published.contains(o.id))
            .toList();
        // Each immutable packet includes its causal history, so receiving it alone is safe.
        if (unpublished.isNotEmpty) {
          final name = '${randomSyncId()}.calsync',
              packet = await exportPacket();
          await transport.upload(name, packet);
          await _serial(() async {
            published.addAll(unpublished.map((o) => o.id));
            seen.add(name);
            await _persist();
          });
        }
      }
      await _serial(() async {
        lastSync = DateTime.now();
        retryAt = null;
        await _persist();
      });
    } catch (e) {
      syncError = 'Sync could not complete. Local changes are preserved. Check the connection, pairing code or cloud credentials.';
      final delay = e is SyncRetry ? e.delay : const Duration(minutes: 2);
      try {
        await _serial(() async {
          retryAt = DateTime.now().add(delay);
          await _persist();
        });
      } catch (_) {
        /* A locked/unavailable local vault must not lose edits. */
      }
    } finally {
      transport?.close();
      syncing = false;
      notifyListeners();
    }
  }

  Future<List<String>> listenLocal() async {
    if (profile == null) {
      throw const FormatException('Create or enter a pairing code first.');
    }
    _listener ??= await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final server = _listener!;
    if (!_listening) {
      _listening = true;
      server.listen(_serve);
    }
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return [
      for (final i in interfaces)
        for (final a in i.addresses)
          'http://${a.address}:${server.port}/calendula/v1/sync',
    ];
  }

  bool _listening = false;
  final List<DateTime> _requests = [];
  Future<void> _serve(HttpRequest request) async {
    try {
      final now = DateTime.now();
      _requests.removeWhere((d) => now.difference(d).inMinutes >= 1);
      if (_requests.length >= 20) {
        request.response.statusCode = 429;
        return;
      }
      _requests.add(now);
      if (request.method != 'POST' ||
          request.uri.path != '/calendula/v1/sync' ||
          profile == null) {
        request.response.statusCode = 404;
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 20))) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024) {
          throw const FormatException('Packet is too large.');
        }
        bytes.addAll(chunk);
      }
      final j = await SyncEnvelope(profile!).open(utf8.decode(bytes));
      await mergePackets({
        randomSyncId(): await SyncEnvelope(profile!)
            .seal({'operations': j['operations']}),
      });
      request.response.headers.contentType = ContentType.binary;
      request.response.write(
        await _serial(
          () => SyncEnvelope(profile!).seal({
            'responseTo': j['challenge'],
            'operations': operations.map((o) => o.toJson()).toList(),
          }),
        ),
      );
    } catch (_) {
      request.response.statusCode = 400;
    } finally {
      await request.response.close();
    }
  }

  Future<void> _lanExchange() async {
    final challenge = randomSyncId(), client = http.Client();
    try {
      final request = http.Request('POST', Uri.parse(url))
        ..followRedirects = false
        ..body = await _serial(
          () => SyncEnvelope(profile!).seal({
            'challenge': challenge,
            'operations': operations.map((o) => o.toJson()).toList(),
          }),
        );
      final stream = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (stream.statusCode != 200) {
        throw const FormatException('Local peer rejected synchronization.');
      }
      final bytes = <int>[];
      await for (final chunk in stream.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024) {
          throw const FormatException('Packet is too large.');
        }
        bytes.addAll(chunk);
      }
      final packet = utf8.decode(bytes),
          j = await SyncEnvelope(profile!).open(packet);
      if (j['responseTo'] != challenge) {
        throw const FormatException(
          'Local peer response failed authentication.',
        );
      }
      await mergePackets({randomSyncId(): packet});
    } finally {
      client.close();
    }
  }

  Future<void> stopListening() async {
    await _listener?.close(force: true);
    _listener = null;
    _listening = false;
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }
}
