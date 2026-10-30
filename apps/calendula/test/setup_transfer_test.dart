import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:calendula/calendar.dart';
import 'package:calendula/journey_preferences.dart';
import 'package:calendula/secure_json_store.dart';
import 'package:calendula/setup_transfer.dart';
import 'package:calendula/sync.dart';

class Legacy implements EventRepository {
  final List<CalendarEvent> events;
  Legacy(this.events);
  @override
  Future<List<CalendarEvent>> load() async => events;
  @override
  Future<void> save(List<CalendarEvent> events) async =>
      throw StateError('No legacy writes');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  Future<(Directory, SyncRepository)> repository(
    String name,
    List<CalendarEvent> events,
  ) async {
    final dir = await Directory.systemTemp.createTemp('calendula-setup-');
    final r = SyncRepository(
      legacy: Legacy(events),
      manageBackground: false,
      profileStorageKey: '$name.profile',
      store: SecureJsonStore(name, directory: () async => dir),
    );
    await r.load();
    addTearDown(() async {
      r.dispose();
      await dir.delete(recursive: true);
    });
    return (dir, r);
  }

  CalendarEvent event(String id) => CalendarEvent(
    id: id,
    title: 'Synthetic $id',
    start: DateTime.utc(2026, 10, 5, 7),
    end: DateTime.utc(2026, 10, 5, 8),
  );
  test('One encrypted setup connects an unpaired device, merges calendar and home, and never transfers mail credentials', () async {
    const secure = FlutterSecureStorage(),
        preferences = JourneyPreferenceStore();
    final source = (await repository('source', [event('remote')])).$2;
    final target = (await repository('target', [event('local')])).$2;
    final profile = SyncProfile.create();
    await source.configure(
      pairing: profile,
      transport: 'webdav',
      endpoint: 'https://files.example.test/Calendula/',
      user: 'synthetic-user',
      secret: 'synthetic-cloud-secret',
    );
    await preferences.save(
      const JourneyPreferences(mode: OriginMode.home, home: 'Synthetic home'),
    );
    await secure.write(key: 'mail.opaque-token', value: 'synthetic-mail-token');
    await secure.write(
      key: SetupTransfer.projectKey,
      value: jsonEncode({
        'clientId': 'fixture.apps.googleusercontent.com',
        'clientSecret': 'synthetic-project-value',
      }),
    );
    final setup = await SetupTransfer(profile).export(source);
    for (final value in [
      'synthetic-cloud-secret',
      'synthetic-user',
      'Synthetic home',
      'synthetic-mail-token',
      profile.key,
    ]) {
      expect(setup.contains(value), false);
    }
    final normal = await SyncEnvelope(profile)
        .open(await source.exportPacket());
    expect(normal.keys.toSet(), {'operations'});
    await preferences.save(const JourneyPreferences());
    final contents = await SetupTransfer(SyncProfile.parse(profile.pairingCode))
        .open(setup);
    await contents.apply(target);
    expect(target.mode, 'webdav');
    expect(target.url, source.url);
    expect(target.password, source.password);
    expect(target.profile!.key, profile.key);
    expect((await target.load()).map((e) => e.id).toSet(), {'local', 'remote'});
    expect((await preferences.load()).home, 'Synthetic home');
    expect(await secure.read(key: 'mail.opaque-token'), 'synthetic-mail-token');
    expect(
      contents.googleProject!.clientId,
      'fixture.apps.googleusercontent.com',
    );
    final repeat = await SetupTransfer(target.profile!).open(setup);
    final seen = target.seen.length;
    final persisted = (await target.store.read())!;
    persisted['retryAt'] = DateTime.utc(2026, 10, 6).toIso8601String();
    await target.store.write(persisted);
    await repeat.apply(target);
    expect((await target.load()).length, 2);
    expect(target.seen.length, seen);
    expect(target.retryAt, DateTime.utc(2026, 10, 6));
  });
  test('Wrong key, tampered connection file and normal calendar packet do not change existing settings', () async {
    final source = (await repository('source', [event('remote')])).$2;
    final profile = SyncProfile.create();
    await source.configure(
      pairing: profile,
      transport: 'webdav',
      endpoint: 'https://files.example.test/Calendula/',
    );
    final setup = await SetupTransfer(profile).export(source);
    final other = SyncProfile.create();
    final wrong = SetupTransfer(SyncProfile(profile.calendarId, other.key));
    await expectLater(wrong.open(setup), throwsFormatException);
    final damaged = jsonDecode(setup) as Map<String, dynamic>;
    final bytes = base64Decode(damaged['ciphertext']);
    bytes[0] ^= 1;
    damaged['ciphertext'] = base64Encode(bytes);
    await expectLater(
      SetupTransfer(profile).open(jsonEncode(damaged)),
      throwsFormatException,
    );
    await expectLater(
      SetupTransfer(profile).open(await source.exportPacket()),
      throwsFormatException,
    );
    expect(source.url, 'https://files.example.test/Calendula/');
    expect((await source.load()).single.id, 'remote');
  });
  test(
    'Setup cannot switch an already active device to a different calendar',
    () async {
      final source = (await repository('source', [event('remote')])).$2;
      final target = (await repository('target', [event('local')])).$2;
      final a = SyncProfile.create(), b = SyncProfile.create();
      await source.configure(
        pairing: a,
        transport: 'webdav',
        endpoint: 'https://a.example.test/Calendula/',
      );
      await target.configure(
        pairing: b,
        transport: 'webdav',
        endpoint: 'https://b.example.test/Calendula/',
      );
      final contents = await SetupTransfer(a)
          .open(await SetupTransfer(a).export(source));
      await expectLater(contents.apply(target), throwsFormatException);
      expect(target.profile!.key, b.key);
      expect(target.url, 'https://b.example.test/Calendula/');
      expect((await target.load()).single.id, 'local');
    },
  );
}
