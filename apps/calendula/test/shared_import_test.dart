import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:calendula/shared_import.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  final from = DateTime.utc(2026, 10, 4), through = DateTime.utc(2026, 11, 4);
  const ics =
      'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:shared-test\nSUMMARY:Shared cinema\nLOCATION:Praha\nDTSTART:20261006T160000Z\nDTEND:20261006T180000Z\nEND:VEVENT\nEND:VCALENDAR';
  test(
    'shared text and attachment produce reviewed candidates without saving',
    () async {
      final batch = await sharedInvitation(
        {
          'text': ics,
          'files': [
            {
              'name': 'invite.ics',
              'bytes': Uint8List.fromList(utf8.encode(ics)),
            },
          ],
        },
        from,
        through,
      );
      expect(batch.events.length, 1);
      expect(batch.events.single.title, 'Shared cinema');
      expect(batch.events.single.start, DateTime.utc(2026, 10, 6, 16));
    },
  );
  test('shared EML decodes MIME calendar locally', () async {
    final eml =
        'Subject: Invitation\r\nContent-Type: text/calendar; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${base64Encode(utf8.encode(ics))}\r\n';
    final batch = await sharedInvitation(
      {
        'files': [
          {'name': 'mail.eml', 'bytes': Uint8List.fromList(utf8.encode(eml))},
        ],
      },
      from,
      through,
    );
    expect(batch.events.single.title, 'Shared cinema');
  });
  test(
    'share bounds and temporary URI permission errors remain visible',
    () async {
      await expectLater(
        sharedInvitation({'error': 'Permission expired'}, from, through),
        throwsFormatException,
      );
      await expectLater(
        sharedInvitation({'text': 'a' * 200001}, from, through),
        throwsFormatException,
      );
      final batch = await sharedInvitation(
        {
          'files': [
            {'name': 'old.xls', 'bytes': Uint8List(2)},
          ],
        },
        from,
        through,
      );
      expect(batch.events, isEmpty);
      expect(batch.warnings.single, contains('.xlsx'));
    },
  );
}
