import 'dart:convert';

import 'package:calendula/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Missing Yandex folder is created before publishing an encrypted packet', () async {
    final calls = <String>[];
    final profile = SyncProfile.create();
    final packet = await SyncEnvelope(profile).seal({'operations': []});
    final transport = WebDavSyncTransport(
      'https://webdav.yandex.ru/Calendula',
      'fixture-user',
      'fixture-app-password',
      client: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        expect(request.followRedirects, isFalse);
        expect(
          request.headers['Authorization'],
          'Basic ${base64Encode(utf8.encode('fixture-user:fixture-app-password'))}',
        );
        switch (request.method) {
          case 'PROPFIND':
            expect(request.headers['Depth'], '1');
            return http.Response('', 404);
          case 'MKCOL':
            return http.Response('', 201);
          case 'PUT':
            expect(request.body, packet);
            expect(request.headers['If-None-Match'], '*');
            return http.Response('', 201);
          default:
            fail('Unexpected WebDAV action');
        }
      }),
    );
    try {
      expect(await transport.download({}), isEmpty);
      await transport.upload('${randomSyncId()}.calsync', packet);
      expect(calls.take(2), ['PROPFIND /Calendula/', 'MKCOL /Calendula/']);
      expect(calls.last, startsWith('PUT /Calendula/'));
    } finally {
      transport.close();
    }
  });

  test('Existing folder is read without recreation; external and unrelated files are ignored', () async {
    final name = '${randomSyncId()}.calsync';
    final packet = await SyncEnvelope(SyncProfile.create())
        .seal({'operations': []});
    final calls = <String>[];
    final transport = WebDavSyncTransport(
      'https://webdav.yandex.ru/Calendula/',
      'fixture',
      'fixture',
      client: MockClient((request) async {
        calls.add(request.method);
        if (request.method == 'PROPFIND') {
          return http.Response('''<d:multistatus xmlns:d="DAV:">
            <d:response><d:href>/Calendula/</d:href></d:response>
            <d:response><d:href>/Calendula/$name</d:href></d:response>
            <d:response><d:href>https://unrelated.invalid/Calendula/$name</d:href></d:response>
            <d:response><d:href>/Other/$name</d:href></d:response>
            <d:response><d:href>/Calendula/notes.txt</d:href></d:response>
          </d:multistatus>''', 207);
        }
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://webdav.yandex.ru/Calendula/$name',
        );
        return http.Response(packet, 200);
      }),
    );
    try {
      expect(await transport.download({}), {name: packet});
      expect(calls, ['PROPFIND', 'GET']);
      expect(await transport.download({name}), isEmpty);
      expect(calls.last, 'PROPFIND');
      expect(calls, isNot(contains('MKCOL')));
      expect(calls, isNot(contains('DELETE')));
    } finally {
      transport.close();
    }
  });

  test(
    'Denied cloud access pauses before any folder or packet write',
    () async {
      final calls = <String>[];
      final transport = WebDavSyncTransport(
        'https://webdav.yandex.ru/Calendula/',
        'fixture',
        'fixture',
        client: MockClient((request) async {
          calls.add(request.method);
          return http.Response('', 401);
        }),
      );
      try {
        await expectLater(transport.download({}), throwsA(isA<SyncRetry>()));
        expect(calls, ['PROPFIND']);
      } finally {
        transport.close();
      }
    },
  );
}
