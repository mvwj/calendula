import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:calendula/calendar.dart';
import 'package:calendula/sync.dart';
import 'package:calendula/secure_json_store.dart';

class Legacy implements EventRepository {
  final List<CalendarEvent> values;
  Legacy(this.values);
  @override
  Future<List<CalendarEvent>> load() async => values;
  @override
  Future<void> save(List<CalendarEvent> events) async =>
      throw StateError('Legacy data must remain untouched.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  final event = CalendarEvent(
    id: 'sample',
    title: 'Cinema',
    start: DateTime.utc(2026, 10, 5, 16),
    end: DateTime.utc(2026, 10, 5, 18),
  );
  SyncOperation base() => SyncOperation('device_A_123456789', 1, event.id, {}, {
    '_alive': true,
    ...(event.toJson()..remove('id')),
  });
  test('Diagnostic repositories never read or replace the personal pairing profile', () async {
    const secure = FlutterSecureStorage();
    const personalKey = 'calendula.sync.profile.v1';
    await secure.write(key: personalKey, value: 'opaque personal sentinel');
    final root = await Directory.systemTemp.createTemp(
      'calendula-isolated-check-',
    );
    SyncRepository make() => SyncRepository(
      legacy: Legacy([]),
      store: SecureJsonStore('isolated', directory: () async => root),
      profileStorageKey: 'calendula.isolated.profile.v1',
      manageBackground: false,
    );
    final a = make(), b = make();
    try {
      expect(await a.load(), isEmpty);
      expect(a.profile, isNull);
      final profile = SyncProfile.create();
      await a.configure(pairing: profile, transport: 'disabled', endpoint: '');
      await a.save([event]);
      expect((await b.load()).single.title, event.title);
      expect(b.profile!.key, profile.key);
      expect(await secure.read(key: personalKey), 'opaque personal sentinel');
    } finally {
      a.dispose();
      b.dispose();
      await root.delete(recursive: true);
    }
  });
  test(
    'Concurrent independent edits merge and same-field changes stay conflicted',
    () {
      final a = base(),
          b = SyncOperation(
            'device_B_123456789',
            1,
            event.id,
            {a.actor: 1},
            {'room': '2', '_alive': true},
          ),
          c = SyncOperation(
            'device_C_123456789',
            1,
            event.id,
            {a.actor: 1},
            {'floor': '3', '_alive': true},
          );
      final d = SyncDocument([c, a, b]);
      expect(d.events().single.room, '2');
      expect(d.events().single.floor, '3');
      expect(d.conflicts, isEmpty);
      final conflicting = SyncOperation(
        c.actor,
        2,
        event.id,
        {a.actor: 1, c.actor: 1},
        {'room': '9', '_alive': true},
      );
      expect(
        SyncDocument([a, b, c, conflicting]).conflicts.single.field,
        'room',
      );
    },
  );
  test(
    'Deletion tombstone survives reordered replay; explicit undo can resurrect',
    () {
      final a = base(),
          delete = SyncOperation(
            a.actor,
            2,
            event.id,
            {a.actor: 1},
            {'_alive': false},
          );
      expect(SyncDocument([delete, a]).events(), isEmpty);
      final undo = SyncOperation(
        a.actor,
        3,
        event.id,
        {a.actor: 2},
        {'_alive': true},
      );
      expect(SyncDocument([undo, delete, a]).events().single.title, 'Cinema');
      expect(() => SyncDocument([undo, a]), throwsFormatException);
    },
  );
  test('AES packet authenticates content, calendar and pairing key', () async {
    final profile = SyncProfile.create();
    expect(SyncProfile.parse(profile.pairingCode).key, profile.key);
    final envelope = SyncEnvelope(profile),
        packet = await envelope.seal({
          'operations': [base().toJson()],
        });
    expect(packet, isNot(contains('Cinema')));
    expect((await envelope.open(packet))['operations'], hasLength(1));
    final j = jsonDecode(packet);
    j['ciphertext'] = 'AA${(j['ciphertext'] as String).substring(2)}';
    await expectLater(envelope.open(jsonEncode(j)), throwsA(anything));
    await expectLater(
      SyncEnvelope(SyncProfile.create()).open(packet),
      throwsFormatException,
    );
  });
  test('Reversed history is sorted without losing dependencies and cycles fail closed', () {
    final actor = base().actor;
    final list = [
      base(),
      for (var i = 2; i <= 2000; i++)
        SyncOperation(actor, i, event.id, {actor: i - 1}, {'notes': '$i'}),
    ];
    expect(SyncDocument(list.reversed.toList()).events().single.notes, '2000');
    expect(
      () => SyncDocument([
        SyncOperation(actor, 1, event.id, {actor: 1}, {'_alive': true}),
      ]),
      throwsFormatException,
    );
  });
  test('A rejected vault transaction does not poison later saves or expose uncommitted data', () async {
    final root = await Directory.systemTemp.createTemp('calendula-sync-lock-');
    final repository = SyncRepository(
      legacy: Legacy([event]),
      store: SecureJsonStore('lock-test', directory: () async => root),
    );
    try {
      await repository.load();
      final profile = SyncProfile.create();
      await repository.configure(
        pairing: profile,
        transport: 'disabled',
        endpoint: '',
      );
      await expectLater(
        repository.mergePackets({'invalid': 'not a packet'}),
        throwsA(anything),
      );
      await repository.save([]);
      final packet = await SyncEnvelope(profile)
          .open(await repository.exportPacket());
      final ops = (packet['operations'] as List)
          .map((j) => SyncOperation.fromJson(Map<String, dynamic>.from(j)))
          .toList();
      expect(SyncDocument(ops).events(), isEmpty);
    } finally {
      repository.dispose();
      await root.delete(recursive: true);
    }
  });
  test('Migration keeps old events and two devices exchange deletes through encrypted folder', () async {
    final root = await Directory.systemTemp.createTemp('calendula-sync-test-');
    try {
      final da = await Directory('${root.path}/a').create(),
          db = await Directory('${root.path}/b').create(),
          shared = '${root.path}/shared';
      final a = SyncRepository(
        legacy: Legacy([event]),
        store: SecureJsonStore('test-a', directory: () async => da),
      );
      final b = SyncRepository(
        legacy: Legacy([]),
        store: SecureJsonStore('test-b', directory: () async => db),
      );
      expect((await a.load()).single.title, 'Cinema');
      await b.load();
      final profile = SyncProfile.create();
      await a.configure(
        pairing: profile,
        transport: 'folder',
        endpoint: shared,
      );
      await b.configure(
        pairing: profile,
        transport: 'folder',
        endpoint: shared,
      );
      await a.synchronize();
      await b.synchronize();
      expect((await b.load()).single.id, event.id);
      await b.save([]);
      await b.synchronize();
      await a.synchronize();
      expect(await a.load(), isEmpty);
      await a.synchronize();
      expect(await a.load(), isEmpty);
      final files = await Directory(shared)
          .list()
          .where((f) => f is File)
          .toList();
      for (final f in files) {
        expect(await (f as File).readAsString(), isNot(contains('Cinema')));
      }
      a.dispose();
      b.dispose();
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('A foreground save preserves unseen headless additions and independent field edits', () async {
    final root = await Directory.systemTemp.createTemp(
      'calendula-shared-vault-',
    );
    SyncRepository instance() => SyncRepository(
      legacy: Legacy([event]),
      store: SecureJsonStore('shared-vault', directory: () async => root),
    );
    final ui = instance(), worker = instance();
    try {
      await ui.load();
      await worker.load();
      final backgroundEvent = CalendarEvent.fromJson({
        ...event.toJson(),
        'id': 'new-remote',
        'title': 'Unseen remote',
      });
      await worker.save([
        CalendarEvent.fromJson({...event.toJson(), 'room': '9'}),
        backgroundEvent,
      ]);
      // The UI still shows its old snapshot: its title edit must not delete the
      // new record or reset the remotely edited room.
      await ui.save([
        CalendarEvent.fromJson({...event.toJson(), 'title': 'Edited locally'}),
      ]);
      final merged = await ui.load();
      expect(merged, hasLength(2));
      expect(merged.firstWhere((e) => e.id == event.id).room, '9');
      expect(
        merged.firstWhere((e) => e.id == event.id).title,
        'Edited locally',
      );
      expect(merged.any((e) => e.id == 'new-remote'), isTrue);
    } finally {
      ui.dispose();
      worker.dispose();
      await root.delete(recursive: true);
    }
  });
}
