import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gmail_desktop_auth.dart';
import 'journey_preferences.dart';
import 'sync.dart';

/// Explicit one-time connection export. Normal calendar packets never contain
/// cloud credentials, pairing keys, mailbox tokens or device configuration.
class SetupTransfer {
  static const maximum = 12 * 1024 * 1024;
  static const projectKey = 'calendula.mail.gmail.config.v1';
  final SyncProfile profile;
  SetupTransfer(this.profile);
  Future<String> export(
    SyncRepository repository, {
    JourneyPreferenceStore preferences = const JourneyPreferenceStore(),
    FlutterSecureStorage secure = const FlutterSecureStorage(),
  }) async {
    if (repository.mode != 'webdav' ||
        repository.profile?.key != profile.key ||
        repository.profile?.calendarId != profile.calendarId) {
      throw const FormatException(
        'Save a cloud connection before exporting its setup.',
      );
    }
    final google = await secure.read(key: projectKey);
    final data = {
      'version': 1,
      'connection': {
        'url': repository.url,
        'username': repository.username,
        'password': repository.password,
      },
      'journey': (await preferences.load()).toJson(),
      if (google != null)
        'googleProject': GmailDesktopConfig.fromJson(jsonDecode(google))
            .toJson(),
      'calendar': await repository.exportPacket(),
    };
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(data)),
      secretKey: SecretKey(base64Url.decode(base64Url.normalize(profile.key))),
      aad: utf8.encode('calendula-setup:1:${profile.calendarId}'),
    );
    final text = jsonEncode({
      'kind': 'calendula-setup',
      'version': 1,
      'calendarId': profile.calendarId,
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText),
    });
    if (utf8.encode(text).length > maximum) {
      throw const FormatException('Connection file exceeds its size limit.');
    }
    return text;
  }

  Future<SetupContents> open(String text) async {
    try {
      if (text.length > maximum || utf8.encode(text).length > maximum) {
        throw const FormatException();
      }
      final j = jsonDecode(text) as Map;
      if (j['kind'] != 'calendula-setup' ||
          j['version'] != 1 ||
          j['calendarId'] != profile.calendarId) {
        throw const FormatException();
      }
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(j['ciphertext']),
          nonce: base64Decode(j['nonce']),
          mac: Mac(base64Decode(j['mac'])),
        ),
        secretKey: SecretKey(
          base64Url.decode(base64Url.normalize(profile.key)),
        ),
        aad: utf8.encode('calendula-setup:1:${profile.calendarId}'),
      );
      if (clear.length > 9 * 1024 * 1024) throw const FormatException();
      final data = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      if (data['version'] != 1) throw const FormatException();
      final c = data['connection'] as Map;
      final url = c['url'] as String,
          user = c['username'] as String,
          secret = c['password'] as String;
      if (url.length > 2048 || user.length > 512 || secret.length > 2048) {
        throw const FormatException();
      }
      final validation = WebDavSyncTransport(url, user, secret);
      validation.close();
      final p = data['journey'] as Map<String, dynamic>;
      if (!OriginMode.values.any((v) => v.name == p['mode']) ||
          p['home'] is! String ||
          p['other'] is! String ||
          (p['home'] as String).length > 300 ||
          (p['other'] as String).length > 300) {
        throw const FormatException();
      }
      final packet = data['calendar'] as String;
      final calendar = await SyncEnvelope(profile).open(packet);
      final operations = (calendar['operations'] as List)
          .map((o) => SyncOperation.fromJson(Map<String, dynamic>.from(o)))
          .toList();
      SyncDocument(operations)
          .events(); // Validate before changing any setting.
      final google = data['googleProject'] == null
          ? null
          : GmailDesktopConfig.fromJson(data['googleProject']);
      return SetupContents(
        profile,
        url,
        user,
        secret,
        JourneyPreferences.fromJson(p),
        packet,
        operations.length,
        google,
      );
    } catch (_) {
      throw const FormatException(
        'Connection file could not be unlocked or is invalid. Use its original pairing code. Nothing has been changed.',
      );
    }
  }
}

class SetupContents {
  final SyncProfile profile;
  final String url, username, password, packet;
  final JourneyPreferences journey;
  final int operationCount;
  final GmailDesktopConfig? googleProject;
  const SetupContents(
    this.profile,
    this.url,
    this.username,
    this.password,
    this.journey,
    this.packet,
    this.operationCount,
    this.googleProject,
  );
  Future<void> apply(
    SyncRepository repository, {
    JourneyPreferenceStore preferences = const JourneyPreferenceStore(),
    FlutterSecureStorage secure = const FlutterSecureStorage(),
  }) async {
    if (repository.profile?.calendarId != profile.calendarId ||
        repository.profile?.key != profile.key ||
        repository.mode != 'webdav' ||
        repository.url != url ||
        repository.username != username ||
        repository.password != password) {
      await repository.configure(
        pairing: profile,
        transport: 'webdav',
        endpoint: url,
        user: username,
        secret: password,
      );
    }
    final digest = await Sha256().hash(utf8.encode(packet));
    await repository.mergePackets({
      'setup-${base64Url.encode(digest.bytes).substring(0, 24)}': packet,
    });
    await preferences.save(journey);
    if (googleProject != null) {
      await secure.write(
        key: SetupTransfer.projectKey,
        value: jsonEncode(googleProject!.toJson()),
      );
    }
  }
}
