import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:calendula/imap_mail.dart';
import 'package:calendula/mail.dart';

const account = ImapAccount(
  'imap.example.org',
  'reader@example.org',
  'synthetic-password',
);
const message =
    'From: Sender <sender@example.org>\r\nSubject: =?UTF-8?B?UG/FmMOtbcOt?=\r\nDate: Mon, 5 Oct 2026 12:00:00 +0200\r\nContent-Type: multipart/mixed; boundary="test"\r\n\r\n--test\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nCinema 2026-10-06 18:00=E2=80=9320:00 | Praha\r\n--test\r\nContent-Type: text/calendar; charset=utf-8\r\nContent-Disposition: attachment; filename="invite.ics"\r\nContent-Transfer-Encoding: base64\r\n\r\nQkVHSU46VkNBTEVOREFSCkJFR0lOOlZFVkVOVApVSUQ6dGVzdApTVU1NQVJZOktpbm8KRFRTVEFSVDoyMDI2MTAwNlQxNjAwMDBaCkRURU5EOjIwMjYxMDA2VDE4MDAwMFoKRU5EOlZFVkVOVApFTkQ6VkNBTEVOREFS\r\n--test--\r\n';

Future<ImapReadResult> withServer(
  Future<void> Function(Socket, String) respond,
  List<String> commands,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  Socket? accepted;
  final serving = Completer<void>();
  final subscription = server.listen((socket) async {
    accepted = socket;
    socket.write('* OK synthetic IMAP ready\r\n');
    try {
      await for (final line
          in socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        commands.add(line);
        await respond(socket, line);
      }
    } catch (_) {
    } finally {
      if (!serving.isCompleted) serving.complete();
    }
  });
  try {
    return await readImap(
      account,
      connect: (_) => Socket.connect(InternetAddress.loopbackIPv4, server.port),
    );
  } finally {
    accepted?.destroy();
    await subscription.cancel();
    await server.close();
    await serving.future.timeout(const Duration(seconds: 3));
  }
}

void main() {
  test('read-only inbox reads new UID, skips large mail and handles fragmented MIME', () async {
    final commands = <String>[];
    final result = await withServer((socket, line) async {
      final tag = line.split(' ').first;
      if (line.contains('LOGIN')) {
        socket.write('$tag OK authenticated\r\n');
      } else if (line.contains('EXAMINE')) {
        socket.write(
          '* 12 EXISTS\r\n* OK [UIDVALIDITY 77] valid\r\n$tag OK [READ-ONLY] examined\r\n',
        );
      } else if (line.contains('RFC822.SIZE')) {
        socket.write(
          '* 11 FETCH (UID 301 RFC822.SIZE ${utf8.encode(message).length})\r\n* 12 FETCH (RFC822.SIZE 2000000 UID 302)\r\n$tag OK metadata\r\n',
        );
      } else if (line.contains('BODY.PEEK[]')) {
        final bytes = utf8.encode(message);
        socket.write('* 11 FETCH (UID 301 BODY[] {${bytes.length}}\r\n');
        await socket.flush();
        for (var n = 0; n < bytes.length; n += 13) {
          socket.add(bytes.sublist(n, (n + 13).clamp(0, bytes.length)));
        }
        socket.write(')\r\n$tag OK fetched\r\n');
      } else {
        fail('unexpected command');
      }
      await socket.flush();
    }, commands);
    expect(result.skipped, 1);
    final mail = result.messages.single;
    expect(mail.id, '${account.id}:77:301');
    expect(mail.text, contains('18:00–20:00'));
    expect(mail.calendarAttachments.single, contains('SUMMARY:Kino'));
    expect(
      commands.map((l) => l.split(' ').skip(1).join(' ')),
      contains('FETCH 3:12 (UID RFC822.SIZE)'),
    );
    expect(commands.where((l) => l.contains('BODY.PEEK[]')).length, 1);
    expect(
      commands.join('\n'),
      isNot(matches(r'\b(SELECT|STORE|EXPUNGE|SMTP|IDLE)\b')),
    );
  });
  test('oversized literal is rejected before body allocation', () async {
    final commands = <String>[];
    await expectLater(
      withServer((s, line) async {
        final tag = line.split(' ').first;
        if (line.contains('LOGIN')) {
          s.write('$tag OK yes\r\n');
        } else if (line.contains('EXAMINE')) {
          s.write(
            '* 1 EXISTS\r\n* OK [UIDVALIDITY 3] valid\r\n$tag OK examined\r\n',
          );
        } else if (line.contains('RFC822.SIZE')) {
          s.write('* 1 FETCH (UID 1 RFC822.SIZE 100)\r\n$tag OK fetched\r\n');
        } else {
          s.write('* 1 FETCH (UID 1 BODY[] {90000000}\r\n');
        }
        await s.flush();
      }, commands),
      throwsA(isA<MailFailure>()),
    );
  });
  test('auth rejection does not expose credentials or provider response', () async {
    try {
      await withServer((s, line) async {
        s.write(
          '${line.split(' ').first} NO synthetic-password private-account-details\r\n',
        );
        await s.flush();
      }, []);
      fail('must reject');
    } on MailFailure catch (e) {
      expect(e.message, isNot(contains('synthetic-password')));
      expect(e.message, isNot(contains('private-account-details')));
    }
  });
  test(
    'host validation and Exchange Online prevent unsafe password attempts',
    () {
      for (final host in [
        'http://mail.example.org',
        '127.0.0.1',
        'mail.local',
        'imap.example.org\r\nHost: bad',
        'outlook.office365.com',
      ]) {
        expect(
          () =>
              ImapAccount(host, account.username, account.password).validate(),
          throwsA(isA<MailFailure>()),
        );
      }
      expect(() => account.validate(), returnsNormally);
      expect(ReadOnlyImap.quote('a"b\\c'), '"a\\"b\\\\c"');
    },
  );
  test('HTML mail is reduced to local text without loading remote images', () {
    final bytes = Uint8List.fromList(
      utf8.encode(
        'Subject: Ticket\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Praha</p><img src="https://tracker.invalid/pixel">',
      ),
    );
    final mail = parseImapMessage(bytes, account, '1', 3);
    expect(mail.text, 'Praha');
  });
}
