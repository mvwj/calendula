import 'dart:async';
import 'dart:convert';

import 'package:calendula/gmail_desktop_auth.dart';
import 'package:calendula/mail.dart';
import 'package:calendula/mail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const oauthId = 'synthetic.apps.googleusercontent.com';
const oauthSecret = 'synthetic-issued-secret';
const channel = MethodChannel('app.calendula/mail');

class FakeDesktopAuth extends GmailDesktopAuth {
  final List<String> tokens;
  final calls = <String>[];
  FakeDesktopAuth(this.tokens)
    : super(MockClient((_) async => http.Response('', 500)));
  @override
  Future<GmailDesktopSession> connect(
    String clientId,
    String secret, {
    String? email,
  }) async {
    calls.add('$clientId:${email ?? 'choose'}');
    return GmailDesktopSession(
      clientId,
      secret,
      tokens.removeAt(0),
      'synthetic-refresh',
      DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<GmailDesktopSession> renew(GmailDesktopSession old) async => old;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final authorizations = <MethodCall>[];
  var selected = 0;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    authorizations.clear();
    selected = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          authorizations.add(call);
          final args = Map<String, dynamic>.from(call.arguments);
          if (args['chooseAccount'] == true) return 'token-${++selected}';
          return args['email'] == 'two@example.test' ? 'token-2' : 'token-1';
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  http.Client inbox({
    Future<http.Response> Function(http.Request)? intercept,
  }) => MockClient((r) async {
    if (intercept != null) return intercept(r);
    expect(r.method, 'GET');
    expect(r.url.host, 'gmail.googleapis.com');
    final second = r.headers['Authorization'] == 'Bearer token-2';
    if (r.url.path.endsWith('/profile')) {
      return http.Response(
        jsonEncode({
          'emailAddress': second ? 'two@example.test' : 'one@example.test',
        }),
        200,
      );
    }
    if (r.url.path.endsWith('/messages')) {
      expect(r.url.queryParameters['labelIds'], 'INBOX');
      expect(r.url.queryParameters['maxResults'], '10');
      return http.Response('{"messages":[{"id":"same-id"}]}', 200);
    }
    return http.Response(
      jsonEncode({
        'internalDate': '1791187200000',
        'payload': {
          'headers': [
            {
              'name': 'Subject',
              'value': second ? 'Second invitation' : 'First invitation',
            },
          ],
          'mimeType': 'text/plain',
          'body': {
            'data': base64Url.encode(
              utf8.encode('2026-10-06 18:00–20:00 | Praha'),
            ),
          },
        },
      }),
      200,
    );
  });

  test('Downloaded Desktop configuration is bounded and excludes other client types', () {
    final config = GmailDesktopConfig.fromDownload(
      jsonEncode({
        'installed': {'client_id': oauthId, 'client_secret': oauthSecret},
      }),
    );
    expect(config.clientId, oauthId);
    for (final text in [
      jsonEncode({
        'web': {'client_id': oauthId, 'client_secret': oauthSecret},
      }),
      jsonEncode({
        'installed': {'client_id': oauthId},
      }),
      'private-invalid-json',
      'x' * 65537,
    ]) {
      expect(
        () => GmailDesktopConfig.fromDownload(text),
        throwsA(isA<MailFailure>()),
      );
    }
    expect(
      () => GmailDesktopConfig('bad', oauthSecret),
      throwsA(isA<MailFailure>()),
    );
  });

  test('Two native Google accounts remain separate, reload without passwords, and refresh exact mailboxes', () async {
    final c = MailController(client: inbox(), googleDesktop: false);
    await c.load();
    await c.connectGmail();
    await c.connectGmail();
    expect(c.gmailAccounts.map((a) => a.email), [
      'one@example.test',
      'two@example.test',
    ]);
    expect(c.messages.map((m) => m.accountId).toSet().length, 2);
    expect(c.messages.map((m) => m.id).toSet(), {'same-id'});
    expect(
      authorizations.take(2).every((a) => a.arguments['chooseAccount'] == true),
      isTrue,
    );
    final saved = (await c.storage.read(key: MailController.gmailKey))!;
    expect(saved, isNot(contains('token-')));
    expect(saved, isNot(contains('password')));
    final loaded = MailController(client: inbox(), googleDesktop: false);
    await loaded.load();
    await loaded.refresh();
    expect(loaded.messages.length, 2);
    final silent = authorizations
        .where((a) => a.arguments['interactive'] == false)
        .toList();
    expect(silent.map((a) => a.arguments['email']), [
      'one@example.test',
      'two@example.test',
    ]);
    await loaded.disconnectGmail('gmail:one@example.test');
    expect(loaded.gmailAccounts.single.email, 'two@example.test');
    expect(loaded.messages.single.accountId, 'gmail:two@example.test');
    c.dispose();
    loaded.dispose();
  });

  test('Failed addition and wrong-account reconnect preserve existing accounts and mail', () async {
    var failProfile = false, wrongProfile = false;
    final ordinary = inbox();
    final c = MailController(
      googleDesktop: false,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/profile') && failProfile) {
          return http.Response('synthetic-secret', 401);
        }
        if (r.url.path.endsWith('/profile') && wrongProfile) {
          return http.Response('{"emailAddress":"two@example.test"}', 200);
        }
        return ordinary.get(r.url, headers: r.headers);
      }),
    );
    await c.load();
    await c.connectGmail();
    failProfile = true;
    await expectLater(c.connectGmail(), throwsA(isA<MailFailure>()));
    expect(c.gmailAccounts.single.email, 'one@example.test');
    expect(c.messages.single.subject, 'First invitation');
    failProfile = false;
    wrongProfile = true;
    await expectLater(
      c.connectGmail(reconnect: c.gmailAccounts.single),
      throwsA(isA<MailFailure>()),
    );
    expect(authorizations.last.arguments['chooseAccount'], false);
    expect(authorizations.last.arguments['email'], 'one@example.test');
    expect(c.gmailAccounts.single.email, 'one@example.test');
    expect(c.busy, false);
    c.dispose();
    ordinary.close();
  });

  test('Disconnect during a delayed refresh cannot restore the account or messages', () async {
    final gate = Completer<void>(), entered = Completer<void>();
    var delay = false;
    final ordinary = inbox();
    final c = MailController(
      googleDesktop: false,
      client: MockClient((r) async {
        if (delay && r.url.path.endsWith('/messages')) {
          entered.complete();
          await gate.future;
        }
        return ordinary.get(r.url, headers: r.headers);
      }),
    );
    await c.load();
    await c.connectGmail();
    c.lastCheck = DateTime.now().subtract(const Duration(minutes: 2));
    delay = true;
    final refresh = c.refresh();
    await entered.future;
    await c.disconnectGmail(c.gmailAccounts.single.id);
    gate.complete();
    await refresh;
    expect(c.gmailAccounts, isEmpty);
    expect(c.messages, isEmpty);
    expect(await c.storage.read(key: MailController.gmailKey), '[]');
    c.dispose();
    ordinary.close();
  });

  test('Legacy Android connection resolves identity and migrates without extra login', () async {
    FlutterSecureStorage.setMockInitialValues({
      MailController.prefsKey: '{"gmail":true}',
    });
    final c = MailController(googleDesktop: false, client: inbox());
    await c.load();
    expect(c.gmailAccounts.single.email, '');
    await c.refresh();
    expect(c.gmailAccounts.single.email, 'one@example.test');
    expect(authorizations.single.arguments['interactive'], false);
    expect(
      await c.storage.read(key: MailController.gmailKey),
      contains('one@example.test'),
    );
    c.dispose();
  });

  test('Desktop accounts reuse one configuration; legacy sessions migrate with settings retained', () async {
    final auth = FakeDesktopAuth(['token-1', 'token-2']);
    final c = MailController(
      googleDesktop: true,
      googleAuth: auth,
      client: inbox(),
    );
    await c.load();
    await c.configureGmail(GmailDesktopConfig(oauthId, oauthSecret));
    await c.connectGmail();
    await c.connectGmail();
    expect(auth.calls, ['$oauthId:choose', '$oauthId:choose']);
    expect(c.gmailAccounts.length, 2);
    final legacy = c.gmailAccounts.first.desktopSession!;
    c.dispose();
    FlutterSecureStorage.setMockInitialValues({
      MailController.legacyGmailKey: jsonEncode(legacy.toJson()),
      MailController.prefsKey: '{"gmail":true}',
    });
    final migrated = MailController(
      googleDesktop: true,
      googleAuth: auth,
      client: inbox(),
    );
    await migrated.load();
    await migrated.refresh();
    expect(migrated.gmailAccounts.single.email, 'one@example.test');
    expect(
      await migrated.storage.read(key: MailController.legacyGmailKey),
      isNull,
    );
    final reloaded = MailController(googleDesktop: true, client: inbox());
    await reloaded.load();
    expect(reloaded.gmailConfig!.clientId, oauthId);
    expect(
      reloaded.gmailAccounts.single.desktopSession!.refreshToken,
      'synthetic-refresh',
    );
    migrated.dispose();
    reloaded.dispose();
  });

  test('Automatic refresh respects the toggle and persisted-in-session provider pause', () async {
    var calls = 0;
    final c = MailController(
      googleDesktop: false,
      client: inbox(
        intercept: (r) async {
          calls++;
          return http.Response(
            'no-personal-response',
            429,
            headers: {'retry-after': '3600'},
          );
        },
      ),
    );
    await c.load();
    c.gmailAccounts = [const GmailAccount('one@example.test')];
    c.refreshOnOpen = false;
    await c.refresh(automatic: true);
    expect(calls, 0);
    await c.refresh();
    expect(calls, 1);
    await c.refresh();
    await expectLater(c.connectGmail(), throwsA(isA<MailFailure>()));
    expect(calls, 1);
    expect(
      c.retryAt!.difference(DateTime.now()).inMinutes,
      greaterThanOrEqualTo(59),
    );
    c.dispose();
  });

  testWidgets(
    'Narrow mail UI offers Google accounts and keeps the app-password method',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = MailController(googleDesktop: false, client: inbox());
      await c.load();
      await c.connectGmail();
      await c.connectGmail();
      await c.configureGmail(GmailDesktopConfig(oauthId, oauthSecret));
      await tester.pumpWidget(
        MaterialApp(
          home: MailPage(
            controller: c,
            events: () => [],
            commit: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Add Google account'), 200);
      expect(find.text('one@example.test'), findsOneWidget);
      expect(find.text('two@example.test'), findsOneWidget);
      expect(find.text('Reconnect'), findsNWidgets(2));
      await tester.scrollUntilVisible(find.text('Read with IMAP'), 200);
      expect(find.text('Read with IMAP'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
