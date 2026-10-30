import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/services.dart';

import 'desktop_tor.dart';
import 'mail.dart';
import 'schedule_import.dart';

class ImapAccount {
  final String host, username, password;
  const ImapAccount(this.host, this.username, this.password);
  String get id => importId('$host\n$username');
  Map<String, dynamic> toJson() => {
    'host': host,
    'username': username,
    'password': password,
  };
  factory ImapAccount.fromJson(Map<String, dynamic> j) =>
      ImapAccount(j['host'], j['username'], j['password']);
  void validate() {
    if (host.length > 253 ||
        !RegExp(
          r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$',
        ).hasMatch(host) ||
        host.endsWith('.local') ||
        host.endsWith('.localhost')) {
      throw const MailFailure(
        'Enter the public IMAP server name, without a URL or port.',
      );
    }
    for (final v in [username, password]) {
      if (v.isEmpty ||
          v.length > 512 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(v)) {
        throw const MailFailure(
          'Enter a username and an app password without line breaks.',
        );
      }
    }
    if (host.toLowerCase() == 'outlook.office365.com') {
      throw const MailFailure(
        'Microsoft 365 requires OAuth. Use Microsoft sign-in below, or share an invitation from Outlook. A university password cannot replace OAuth.',
      );
    }
  }
}

/// CONNECT goes only to the app's loopback Tor tunnel. DNS and the connection to
/// the remote host are made by Tor; TLS still validates the actual server name.
Future<SecureSocket> privateImapSocket(String host) async {
  final port = Platform.isWindows
      ? await DesktopTor.instance.imapProxyPort()
      : await const MethodChannel('app.calendula/private-transit')
            .invokeMethod<int>('imapProxy')
            .timeout(const Duration(seconds: 140));
  if (port == null) {
    throw const MailFailure('Private mail connection is unavailable.');
  }
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
    timeout: const Duration(seconds: 10),
  );
  final ready = Completer<void>();
  final header = <int>[];
  late StreamSubscription<Uint8List> subscription;
  subscription = socket.listen(
    (chunk) {
      header.addAll(chunk);
      if (header.length > 8192) {
        if (!ready.isCompleted) {
          ready.completeError(
            const MailFailure('Private tunnel response exceeded its limit.'),
          );
        }
        socket.destroy();
        return;
      }
      final text = latin1.decode(header);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      subscription.pause();
      if (end + 4 != header.length ||
          !RegExp(r'^HTTP/1\.[01] 200(?: |\r)').hasMatch(text)) {
        ready.completeError(
          const MailFailure('Tor could not open a private IMAP connection.'),
        );
      } else {
        ready.complete();
      }
    },
    onError: (Object e) {
      if (!ready.isCompleted) ready.completeError(e);
    },
    onDone: () {
      if (!ready.isCompleted) {
        ready.completeError(const MailFailure('Private mail tunnel closed.'));
      }
    },
  );
  try {
    socket.write('CONNECT $host:993 HTTP/1.1\r\nHost: $host:993\r\n\r\n');
    await socket.flush();
    await ready.future.timeout(const Duration(seconds: 90));
    return await SecureSocket.secure(
      socket,
      host: host,
    ).timeout(const Duration(seconds: 30));
  } catch (_) {
    socket.destroy();
    rethrow;
  }
}

class ImapReadResult {
  final List<MailMessage> messages;
  final int skipped;
  const ImapReadResult(this.messages, this.skipped);
}

/// Deliberately small read-only IMAP surface. Commands never SELECT, STORE,
/// EXPUNGE or send mail. Literals/lines/session time are bounded before MIME.
class ReadOnlyImap {
  final Socket socket;
  late final StreamIterator<Uint8List> input = StreamIterator(socket);
  Uint8List chunk = Uint8List(0);
  int position = 0, serial = 0;
  static const maxMessage = 1024 * 1024;
  ReadOnlyImap(this.socket);
  Future<int> byte() async {
    if (position == chunk.length) {
      if (!await input.moveNext()) {
        throw const MailFailure('Mail server closed the connection.');
      }
      chunk = input.current;
      position = 0;
    }
    return chunk[position++];
  }

  Future<String> line() async {
    final bytes = <int>[];
    while (true) {
      final b = await byte();
      bytes.add(b);
      if (bytes.length > 32768) {
        throw const MailFailure('Mail server response exceeded its limit.');
      }
      if (b == 10 && bytes.length > 1 && bytes[bytes.length - 2] == 13) {
        return latin1.decode(bytes.sublist(0, bytes.length - 2));
      }
    }
  }

  Future<({List<String> lines, List<Uint8List> literals})> command(
    String command, {
    bool authenticating = false,
  }) async {
    final tag = 'C${++serial}';
    socket.write('$tag $command\r\n');
    await socket.flush();
    final lines = <String>[], literals = <Uint8List>[];
    var total = 0;
    while (true) {
      final value = await line();
      total += value.length;
      if (total > maxMessage + 65536 || lines.length > 100) {
        throw const MailFailure('Mail response exceeded its limit.');
      }
      if (value.startsWith('$tag ')) {
        if (!value.startsWith('$tag OK')) {
          throw MailFailure(
            authenticating
                ? 'IMAP sign-in was rejected. Check the app password and server. Microsoft 365 needs OAuth; university policy may also disable IMAP.'
                : 'The server did not accept a read-only mail request.',
          );
        }
        return (lines: lines, literals: literals);
      }
      if (value.startsWith('* BYE')) {
        throw const MailFailure('The mail server ended this session.');
      }
      if (value.startsWith('+')) {
        throw const MailFailure(
          'The mail server requested an unsupported authentication method.',
        );
      }
      lines.add(value);
      final literal = RegExp(r'\{(\d+)\}$').firstMatch(value);
      if (literal != null) {
        final count = int.parse(literal[1]!);
        if (count > maxMessage || total + count > maxMessage + 65536) {
          throw const MailFailure(
            'Mail attachment exceeds the 1 MB read limit.',
          );
        }
        final bytes = Uint8List(count);
        for (var n = 0; n < count; n++) {
          bytes[n] = await byte();
        }
        total += count;
        literals.add(bytes);
      }
    }
  }

  static String quote(String v) =>
      '"${v.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
  Future<ImapReadResult> recent(ImapAccount account) async {
    final greeting = await line();
    if (!greeting.startsWith('* OK')) {
      throw const MailFailure(
        'Mail server did not offer a normal sign-in session.',
      );
    }
    await command(
      'LOGIN ${quote(account.username)} ${quote(account.password)}',
      authenticating: true,
    );
    final inbox = await command('EXAMINE "INBOX"');
    var exists = 0, validity = '';
    for (final line in inbox.lines) {
      final count = RegExp(r'^\* (\d+) EXISTS$').firstMatch(line);
      if (count != null) exists = int.parse(count[1]!);
      final uid = RegExp(r'\[UIDVALIDITY (\d+)\]').firstMatch(line);
      if (uid != null) validity = uid[1]!;
    }
    if (validity.isEmpty) {
      throw const MailFailure('The server did not identify this inbox safely.');
    }
    if (exists == 0) return const ImapReadResult([], 0);
    final metadata = await command(
      'FETCH ${exists > 10 ? exists - 9 : 1}:$exists (UID RFC822.SIZE)',
    );
    final entries = <({int uid, int size})>[];
    for (final line in metadata.lines) {
      if (!RegExp(r'^\* \d+ FETCH \(', caseSensitive: false).hasMatch(line)) {
        continue;
      }
      final uid = RegExp(
        r'\bUID (\d+)\b',
        caseSensitive: false,
      ).firstMatch(line);
      final size = RegExp(
        r'\bRFC822\.SIZE (\d+)\b',
        caseSensitive: false,
      ).firstMatch(line);
      if (uid != null && size != null) {
        entries.add((uid: int.parse(uid[1]!), size: int.parse(size[1]!)));
      }
    }
    final result = <MailMessage>[];
    var skipped = 0, budget = 5 * maxMessage;
    for (final entry in entries.reversed.take(10)) {
      if (entry.size > maxMessage || entry.size > budget) {
        skipped++;
        continue;
      }
      final body = await command('UID FETCH ${entry.uid} (UID BODY.PEEK[])');
      if (body.literals.length != 1 ||
          !body.lines.any(
            (l) => RegExp('\\bUID ${entry.uid}\\b').hasMatch(l),
          )) {
        continue;
      }
      budget -= body.literals.single.length;
      result.add(
        parseImapMessage(body.literals.single, account, validity, entry.uid),
      );
    }
    return ImapReadResult(result, skipped);
  }

  Future<void> close() async {
    socket.destroy();
    await input.cancel();
  }
}

MailMessage parseImapMessage(
  Uint8List bytes,
  ImapAccount account,
  String validity,
  int uid,
) {
  final mime = MimeMessage.parseFromData(bytes);
  final calendars = <String>[];
  for (final part in mime.allPartsFlat.take(50)) {
    if (part.mediaType.text == 'text/calendar' ||
        (part.decodeFileName() ?? '').toLowerCase().endsWith('.ics')) {
      final calendar = part.decodeContentText();
      if (calendar != null && calendar.length <= 200000) {
        calendars.add(calendar);
      }
    }
  }
  return MailMessage(
    provider: MailProvider.imap,
    accountId: account.id,
    id: '${account.id}:$validity:$uid',
    subject: mime.decodeSubject() ?? '',
    sender: mime.fromEmail ?? '',
    received:
        mime.decodeDate() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    text:
        mime.decodeTextPlainPart() ??
        localMailText(mime.decodeTextHtmlPart() ?? ''),
    calendarAttachments: calendars,
  );
}

Future<ImapReadResult> readImap(
  ImapAccount account, {
  Future<Socket> Function(String)? connect,
}) async {
  account.validate();
  final socket = await (connect ?? privateImapSocket)(account.host);
  final session = ReadOnlyImap(socket);
  try {
    return await session.recent(account).timeout(const Duration(seconds: 120));
  } finally {
    await session.close();
  }
}
