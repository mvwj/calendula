import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'mail.dart';

class GmailDesktopConfig {
  final String clientId, clientSecret;
  GmailDesktopConfig(this.clientId, this.clientSecret) {
    if (!RegExp(r'^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$')
            .hasMatch(clientId) ||
        clientSecret.isEmpty ||
        clientSecret.length > 512 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(clientSecret)) {
      throw const MailFailure(
        'Enter the issued Google Desktop client ID and secret.',
      );
    }
  }
  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'clientSecret': clientSecret,
  };
  factory GmailDesktopConfig.fromJson(Map<String, dynamic> j) =>
      GmailDesktopConfig(j['clientId'] as String, j['clientSecret'] as String);
  factory GmailDesktopConfig.fromDownload(String text) {
    try {
      if (text.length > 65536) throw const FormatException();
      final j = jsonDecode(text) as Map;
      final installed = j['installed'] as Map;
      return GmailDesktopConfig(
        installed['client_id'] as String,
        installed['client_secret'] as String,
      );
    } catch (_) {
      throw const MailFailure(
        'Choose the downloaded Desktop app OAuth JSON, not an Android, Web or service-account file.',
      );
    }
  }
}

class GmailDesktopSession {
  final String clientId, clientSecret, accessToken, refreshToken;
  final DateTime expires;
  GmailDesktopSession(
    this.clientId,
    this.clientSecret,
    this.accessToken,
    this.refreshToken,
    this.expires,
  );
  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'clientSecret': clientSecret,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expires': expires.toIso8601String(),
  };
  factory GmailDesktopSession.fromJson(Map<String, dynamic> j) =>
      GmailDesktopSession(
        j['clientId'],
        j['clientSecret'],
        j['accessToken'],
        j['refreshToken'],
        DateTime.parse(j['expires']),
      );
}

class GmailDesktopAuth {
  final http.Client client;
  GmailDesktopAuth(this.client);
  String random() => base64Url
      .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  Future<GmailDesktopSession> connect(
    String clientId,
    String secret, {
    String? email,
  }) async {
    GmailDesktopConfig(clientId, secret);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        state = random(),
        verifier = random();
    final redirect = 'http://127.0.0.1:${server.port}/oauth/callback',
        challenge = base64Url
            .encode((await Sha256().hash(utf8.encode(verifier))).bytes)
            .replaceAll('=', '');
    final result = Completer<String>();
    server.listen((request) async {
      if (request.uri.path != '/oauth/callback' ||
          request.uri.queryParameters['state'] != state) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final code = request.uri.queryParameters['code'];
      if (code == null) {
        if (!result.isCompleted) {
          result.completeError(
            const MailFailure('Google sign-in was cancelled.'),
          );
        }
      } else if (!result.isCompleted) {
        result.complete(code);
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><title>Calendula</title><p>Return to Calendula. You can close this page.</p>',
      );
      await request.response.close();
    });
    try {
      final opened = await launchUrl(
        Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
          'client_id': clientId,
          'redirect_uri': redirect,
          'response_type': 'code',
          'scope': 'https://www.googleapis.com/auth/gmail.readonly',
          'state': state,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'access_type': 'offline',
          'prompt': 'select_account consent',
          if (email != null && email.isNotEmpty) 'login_hint': email,
        }),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const MailFailure(
          'Google sign-in could not open in your browser.',
        );
      }
      final code = await result.future.timeout(const Duration(minutes: 5));
      final response = await client
          .post(
            Uri.https('oauth2.googleapis.com', '/token'),
            body: {
              'client_id': clientId,
              'client_secret': secret,
              'code': code,
              'redirect_uri': redirect,
              'code_verifier': verifier,
              'grant_type': 'authorization_code',
            },
          )
          .timeout(const Duration(seconds: 110));
      if (response.statusCode != 200) {
        throw const MailFailure(
          'Google did not grant access. Check the Desktop OAuth client and Gmail test user.',
        );
      }
      return session(clientId, secret, jsonDecode(response.body));
    } finally {
      await server.close(force: true);
    }
  }

  Future<GmailDesktopSession> renew(GmailDesktopSession old) async {
    if (old.expires.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
      return old;
    }
    final response = await client
        .post(
          Uri.https('oauth2.googleapis.com', '/token'),
          body: {
            'client_id': old.clientId,
            'client_secret': old.clientSecret,
            'refresh_token': old.refreshToken,
            'grant_type': 'refresh_token',
          },
        )
        .timeout(const Duration(seconds: 110));
    if (response.statusCode != 200) {
      throw const MailFailure(
        'Reconnect Gmail. Testing projects may expire refresh permission after seven days.',
      );
    }
    return session(
      old.clientId,
      old.clientSecret,
      jsonDecode(response.body),
      previousRefresh: old.refreshToken,
    );
  }

  GmailDesktopSession session(
    String id,
    String secret,
    Map<String, dynamic> j, {
    String previousRefresh = '',
  }) {
    final access = j['access_token'] as String?,
        refresh = j['refresh_token'] as String? ?? previousRefresh;
    if (access == null || refresh.isEmpty) {
      throw const MailFailure('Google did not grant renewable read access.');
    }
    return GmailDesktopSession(
      id,
      secret,
      access,
      refresh,
      DateTime.now().add(
        Duration(seconds: (j['expires_in'] as int? ?? 3600).clamp(30, 86400)),
      ),
    );
  }
}
