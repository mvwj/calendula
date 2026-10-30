import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

class SecureJsonStore {
  final String name;
  final FlutterSecureStorage storage;
  final Future<Directory> Function() directory;
  SecureJsonStore(
    this.name, {
    this.storage = const FlutterSecureStorage(),
    Future<Directory> Function()? directory,
  }) : directory = directory ?? getApplicationSupportDirectory;
  final cipher = AesGcm.with256bits();
  SecretKey? _key;
  File? _file;
  Future<void> _open() async {
    if (_file != null) return;
    final dir = await directory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name.vault');
    final raw = await storage.read(key: 'calendula.$name.key.v1');
    if (raw == null &&
        (await file.exists() || await File('${file.path}.previous').exists())) {
      throw StateError(
        'Encrypted data key is unavailable. Existing files have been preserved.',
      );
    }
    _key = raw == null
        ? await cipher.newSecretKey()
        : SecretKey(base64Decode(raw));
    if (raw == null) {
      await storage.write(
        key: 'calendula.$name.key.v1',
        value: base64Encode(await _key!.extractBytes()),
      );
    }
    _file = file;
  }

  Future<Map<String, dynamic>?> read() async {
    await _open();
    var file = _file!;
    if (!await file.exists()) {
      file = File('${file.path}.previous');
      if (!await file.exists()) return null;
    }
    if (await file.length() > 24 * 1024 * 1024) {
      throw const FormatException('Encrypted data exceeds its size limit.');
    }
    final j = jsonDecode(await file.readAsString());
    if (j['version'] != 1) {
      throw const FormatException('Unsupported encrypted data version.');
    }
    final bytes = await cipher.decrypt(
      SecretBox(
        base64Decode(j['ciphertext']),
        nonce: base64Decode(j['nonce']),
        mac: Mac(base64Decode(j['mac'])),
      ),
      secretKey: _key!,
      aad: utf8.encode('calendula:$name:v1'),
    );
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<void> write(Map<String, dynamic> value) async {
    await _open();
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > 16 * 1024 * 1024) {
      throw const FormatException('Encrypted data exceeds its size limit.');
    }
    final box = await cipher.encrypt(
      bytes,
      secretKey: _key!,
      aad: utf8.encode('calendula:$name:v1'),
    );
    final pending = File('${_file!.path}.pending');
    await pending.writeAsString(
      jsonEncode({
        'version': 1,
        'nonce': base64Encode(box.nonce),
        'mac': base64Encode(box.mac.bytes),
        'ciphertext': base64Encode(box.cipherText),
      }),
      flush: true,
    );
    final previous = File('${_file!.path}.previous');
    if (await _file!.exists()) {
      if (await previous.exists()) await previous.delete();
      await _file!.rename(previous.path);
    }
    await pending.rename(_file!.path);
  }
}
