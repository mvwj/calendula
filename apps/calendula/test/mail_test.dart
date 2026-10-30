import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:calendula/mail.dart';

void main() {
  test(
    'Gmail reads inbox and calendar parts without altering messages',
    () async {
      final paths = <String>[];
      final api = MailApi(
        client: MockClient((r) async {
          expect(r.method, 'GET');
          expect(r.headers['Authorization'], 'Bearer test-token');
          paths.add(r.url.path);
          if (r.url.path.endsWith('/messages')) {
            return http.Response(
              jsonEncode({
                'messages': [
                  {'id': '123'},
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'id': '123',
              'internalDate': '1791187200000',
              'payload': {
                'headers': [
                  {'name': 'Subject', 'value': 'Cinema'},
                ],
                'mimeType': 'multipart/mixed',
                'parts': [
                  {
                    'mimeType': 'text/plain',
                    'body': {
                      'data': base64Url.encode(
                        utf8.encode('Cinema 2026-10-05 18:00–20:00 | Kino'),
                      ),
                    },
                  },
                  {
                    'mimeType': 'text/calendar',
                    'body': {
                      'data': base64Url.encode(
                        utf8.encode('BEGIN:VCALENDAR\nEND:VCALENDAR'),
                      ),
                    },
                  },
                  {
                    'mimeType': 'text/html',
                    'body': {
                      'data': base64Url.encode(
                        utf8.encode(
                          '<img src="https://tracker.invalid/pixel">hello',
                        ),
                      ),
                    },
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
      final messages = await api.recent(MailProvider.gmail, 'test-token');
      expect(paths.length, 2);
      expect(messages.single.calendarAttachments.length, 1);
      expect(messages.single.text, contains('2026-10-05'));
      expect(messages.single.text, isNot(contains('tracker')));
    },
  );
  test('Graph inbox remains read-only and HTML is never fetched', () async {
    var calls = 0;
    final api = MailApi(
      client: MockClient((r) async {
        calls++;
        expect(r.method, 'GET');
        expect(r.url.host, 'graph.microsoft.com');
        expect(r.url.queryParameters[r'$top'], '10');
        return http.Response(
          jsonEncode({
            'value': [
              {
                'id': 'm',
                'subject': 'Ticket',
                'receivedDateTime': '2026-10-04T10:00:00Z',
                'body': {
                  'contentType': 'html',
                  'content': '<style>secret</style><p>Cinema</p><img src="https://pixel.invalid">',
                },
                'hasAttachments': false,
              },
            ],
          }),
          200,
        );
      }),
    );
    final message = (await api.recent(MailProvider.outlook, 'token')).single;
    expect(calls, 1);
    expect(message.text, 'Cinema');
  });
  test(
    'Provider backoff honors Retry-After and error does not leak response',
    () {
      try {
        MailApi.decode(
          http.Response('token-secret', 429, headers: {'retry-after': '3600'}),
        );
        fail('must reject');
      } on MailFailure catch (e) {
        expect(e.message, isNot(contains('token-secret')));
        expect(
          e.retryAt!.difference(DateTime.now()).inMinutes,
          greaterThanOrEqualTo(59),
        );
      }
    },
  );
  test(
    'Graph lists attachment metadata and downloads only small ICS files',
    () async {
      final paths = <String>[];
      final api = MailApi(
        client: MockClient((r) async {
          paths.add(r.url.path);
          if (r.url.path.endsWith('/messages')) {
            return http.Response(
              jsonEncode({
                'value': [
                  {
                    'id': 'm',
                    'subject': 'Ticket',
                    'receivedDateTime': '2026-10-04T10:00:00Z',
                    'body': {'contentType': 'text', 'content': 'hello'},
                    'hasAttachments': true,
                  },
                ],
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/attachments')) {
            expect(
              r.url.queryParameters[r'$select'],
              'id,name,size,contentType',
            );
            return http.Response(
              jsonEncode({
                'value': [
                  {'id': 'large', 'name': 'video.mp4', 'size': 50000000},
                  {'id': 'ics', 'name': 'ticket.ics', 'size': 100},
                ],
              }),
              200,
            );
          }
          expect(r.url.path, endsWith('/attachments/ics'));
          return http.Response(
            jsonEncode({
              'contentBytes': base64Encode(utf8.encode('BEGIN:VCALENDAR')),
            }),
            200,
          );
        }),
      );
      final messages = await api.recent(MailProvider.outlook, 'token');
      expect(paths.length, 3);
      expect(messages.single.calendarAttachments.single, 'BEGIN:VCALENDAR');
      expect(paths.any((p) => p.endsWith('/large')), isFalse);
    },
  );
  test(
    'OAuth begin requests only read scope and rejects unofficial sign-in pages',
    () async {
      final auth = OutlookAuth(
        MockClient((r) async {
          expect(r.body, contains('Mail.Read'));
          expect(r.body, isNot(contains('Mail.Send')));
          return http.Response(
            jsonEncode({
              'device_code': 'private',
              'user_code': 'ABCD',
              'verification_uri': 'https://phish.invalid',
              'interval': 5,
              'expires_in': 900,
            }),
            200,
          );
        }),
      );
      await expectLater(
        auth.begin('11111111-2222-3333-4444-555555555555'),
        throwsA(isA<MailFailure>()),
      );
    },
  );
}
