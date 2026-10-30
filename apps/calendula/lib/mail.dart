import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'desktop_tor.dart';
import 'gmail_desktop_auth.dart';
import 'imap_mail.dart';

enum MailProvider { gmail, outlook, imap }

class MailFailure implements Exception {
  final String message;
  final DateTime? retryAt;
  const MailFailure(this.message, [this.retryAt]);
  @override
  String toString() => message;
}

class MailMessage {
  final MailProvider provider;
  final String id, subject, sender, text;
  final DateTime received;
  final List<String> calendarAttachments;
  final String accountId;
  const MailMessage({
    required this.provider,
    required this.id,
    required this.subject,
    required this.sender,
    required this.text,
    required this.received,
    this.calendarAttachments = const [],
    this.accountId = '',
  });
}

String localMailText(String html) {
  // Never renders HTML or requests its links, CSS, tracking pixels or images.
  return html
      .replaceAll(
        RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(r'<(?:br\s*/?|/p|/div|/tr)>', caseSensitive: false),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();
}

String _base64Text(String value) => utf8.decode(
  base64Url.decode(base64Url.normalize(value)),
  allowMalformed: true,
);

class MailApi {
  final http.Client client;
  MailApi({required this.client});
  Future<Map<String, dynamic>> jsonGet(Uri url, String token) async {
    final response = await client
        .get(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Prefer': 'outlook.body-content-type="text"',
          },
        )
        .timeout(const Duration(seconds: 110));
    return decode(response);
  }

  static Map<String, dynamic> decode(http.Response r) {
    if (r.bodyBytes.length > 5 * 1024 * 1024) {
      throw const MailFailure('Mail response is too large.');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw const MailFailure(
        'Mail permission expired or was denied. Reconnect this account.',
      );
    }
    if (r.statusCode == 429 || r.statusCode >= 500) {
      final raw = r.headers['retry-after'];
      final seconds = int.tryParse(raw ?? '');
      DateTime? retry;
      if (seconds != null) {
        retry = DateTime.now().add(Duration(seconds: seconds.clamp(60, 86400)));
      } else if (raw != null) {
        try {
          retry = HttpDate.parse(raw);
        } catch (_) {}
      }
      throw MailFailure(
        'Mail refresh is paused by the provider. Try later.',
        retry ?? DateTime.now().add(const Duration(minutes: 5)),
      );
    }
    if (r.statusCode != 200) {
      throw MailFailure('Mail provider returned HTTP ${r.statusCode}.');
    }
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<MailMessage>> recent(
    MailProvider provider,
    String token, {
    int limit = 10,
    String accountId = '',
  }) async {
    limit = limit.clamp(1, 20);
    if (provider == MailProvider.outlook) {
      final j = await jsonGet(
        Uri.https(
          'graph.microsoft.com',
          '/v1.0/me/mailFolders/inbox/messages',
          {
            r'$top': '$limit',
            r'$orderby': 'receivedDateTime desc',
            r'$select': 'id,subject,from,receivedDateTime,body,hasAttachments',
          },
        ),
        token,
      );
      final result = <MailMessage>[];
      for (final m in (j['value'] as List? ?? []).take(limit)) {
        final body = m['body'] as Map? ?? {};
        final content = (body['content'] ?? '') as String;
        final attachments = <String>[];
        if (m['hasAttachments'] == true) {
          final files = await jsonGet(
            Uri.https('graph.microsoft.com', '/', {
              r'$top': '10',
              r'$select': 'id,name,size,contentType',
            }).replace(
              pathSegments: ['v1.0', 'me', 'messages', m['id'], 'attachments'],
            ),
            token,
          );
          for (final a in (files['value'] as List? ?? []).take(10)) {
            if ((a['name'] as String? ?? '').toLowerCase().endsWith('.ics') &&
                (a['size'] as num? ?? 9999999) <= 200000) {
              final file = await jsonGet(
                Uri.https('graph.microsoft.com', '/').replace(
                  pathSegments: [
                    'v1.0',
                    'me',
                    'messages',
                    m['id'],
                    'attachments',
                    a['id'],
                  ],
                ),
                token,
              );
              if (file['contentBytes'] is! String) continue;
              attachments.add(
                utf8.decode(
                  base64Decode(file['contentBytes']),
                  allowMalformed: true,
                ),
              );
            }
          }
        }
        result.add(
          MailMessage(
            provider: provider,
            accountId: accountId,
            id: m['id'],
            subject: m['subject'] ?? '(No subject)',
            sender: m['from']?['emailAddress']?['address'] ?? '',
            text: (body['contentType'] as String? ?? '').toLowerCase() == 'html'
                ? localMailText(content)
                : content,
            received: DateTime.parse(m['receivedDateTime']),
            calendarAttachments: attachments,
          ),
        );
      }
      return result;
    }
    final j = await jsonGet(
      Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/messages', {
        'maxResults': '$limit',
        'labelIds': 'INBOX',
      }),
      token,
    );
    final result = <MailMessage>[];
    for (final stub in (j['messages'] as List? ?? []).take(limit)) {
      final id = stub['id'] as String;
      final m = await jsonGet(
        Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/messages/$id', {
          'format': 'full',
        }),
        token,
      );
      final payload = m['payload'] as Map? ?? {};
      String header(String name) =>
          (payload['headers'] as List? ?? [])
              .where((h) => (h['name'] as String).toLowerCase() == name)
              .map((h) => h['value'] as String)
              .firstOrNull ??
          '';
      final plain = <String>[], html = <String>[], calendars = <String>[];
      Future<void> read(Map part, int depth) async {
        if (depth > 12) return;
        final mime = part['mimeType'] ?? '', body = part['body'] as Map? ?? {};
        final isCalendar =
            mime == 'text/calendar' ||
            (part['filename'] as String? ?? '').toLowerCase().endsWith('.ics');
        String data = body['data'] as String? ?? '';
        if (isCalendar &&
            data.isEmpty &&
            body['attachmentId'] is String &&
            (body['size'] as num? ?? 9999999) <= 200000) {
          final a = await jsonGet(
            Uri.https(
              'gmail.googleapis.com',
              '/gmail/v1/users/me/messages/$id/attachments/${body['attachmentId']}',
            ),
            token,
          );
          data = a['data'] as String? ?? '';
        }
        if (data.isNotEmpty && data.length <= 1000000) {
          final value = _base64Text(data);
          if (isCalendar) {
            calendars.add(value);
          } else if (mime == 'text/plain') {
            plain.add(value);
          } else if (mime == 'text/html') {
            html.add(localMailText(value));
          }
        }
        for (final child in (part['parts'] as List? ?? []).take(50)) {
          await read(child as Map, depth + 1);
        }
      }

      await read(payload, 0);
      result.add(
        MailMessage(
          provider: provider,
          accountId: accountId,
          id: id,
          subject: header('subject'),
          sender: header('from'),
          text: (plain.isNotEmpty ? plain : html).join('\n'),
          received: DateTime.fromMillisecondsSinceEpoch(
            int.parse(m['internalDate']),
            isUtc: true,
          ),
          calendarAttachments: calendars,
        ),
      );
    }
    return result;
  }

  Future<String> gmailAddress(String token) async {
    final j = await jsonGet(
      Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/profile'),
      token,
    );
    final email = (j['emailAddress'] as String? ?? '').trim().toLowerCase();
    if (email.length > 254 ||
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      throw const MailFailure(
        'Google did not return a valid Gmail mailbox address.',
      );
    }
    return email;
  }
}

class PrivateMailClient extends http.BaseClient {
  final http.Client _desktop;
  PrivateMailClient({http.Client? desktop})
    : _desktop =
          desktop ??
          (Platform.isWindows ? DesktopPrivateClient() : http.Client());
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final u = request.url;
    final desktopAuth =
        !Platform.isAndroid &&
        request.method == 'POST' &&
        u.host == 'oauth2.googleapis.com' &&
        u.path == '/token';
    final allowed =
        u.scheme == 'https' &&
        u.userInfo.isEmpty &&
        !u.hasFragment &&
        (desktopAuth ||
            (request.method == 'GET' &&
                ((u.host == 'gmail.googleapis.com' &&
                        u.path.startsWith('/gmail/v1/users/me/')) ||
                    (u.host == 'graph.microsoft.com' &&
                        u.path.startsWith('/v1.0/me/')))) ||
            (request.method == 'POST' &&
                u.host == 'login.microsoftonline.com' &&
                [
                  '/common/oauth2/v2.0/devicecode',
                  '/common/oauth2/v2.0/token',
                ].contains(u.path)));
    if (!allowed) {
      throw const MailFailure('Mail request destination was rejected.');
    }
    request.followRedirects = false;
    if (!Platform.isAndroid) return _desktop.send(request);
    final bytes = await request.finalize().toBytes();
    final result = await const MethodChannel('app.calendula/private-transit')
        .invokeMapMethod<String, dynamic>('mail', {
          'url': u.toString(),
          'verb': request.method,
          'token': (request.headers['Authorization'] ?? '').replaceFirst(
            'Bearer ',
            '',
          ),
          'body': utf8.decode(bytes),
        });
    return http.StreamedResponse(
      Stream.value(result!['body'] as Uint8List),
      result['status'] as int,
      headers: {
        if (result['retryAfter'] != null)
          'retry-after': result['retryAfter'] as String,
      },
    );
  }

  @override
  void close() {
    _desktop.close();
    super.close();
  }
}

class OutlookSession {
  final String clientId, accessToken, refreshToken;
  final DateTime expires;
  const OutlookSession(
    this.clientId,
    this.accessToken,
    this.refreshToken,
    this.expires,
  );
  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expires': expires.toIso8601String(),
  };
  factory OutlookSession.fromJson(Map<String, dynamic> j) => OutlookSession(
    j['clientId'],
    j['accessToken'],
    j['refreshToken'],
    DateTime.parse(j['expires']),
  );
}

class DeviceSignIn {
  final String deviceCode, userCode, url;
  final DateTime expires;
  final int interval;
  const DeviceSignIn(
    this.deviceCode,
    this.userCode,
    this.url,
    this.expires,
    this.interval,
  );
}

class OutlookAuth {
  final http.Client client;
  OutlookAuth(this.client);
  static const scope = 'https://graph.microsoft.com/Mail.Read offline_access';
  Uri endpoint(String kind) =>
      Uri.https('login.microsoftonline.com', '/common/oauth2/v2.0/$kind');
  Future<DeviceSignIn> begin(String clientId) async {
    if (!RegExp(r'^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$')
        .hasMatch(clientId)) {
      throw const MailFailure(
        'Enter the Microsoft Application (client) ID. No client secret is needed.',
      );
    }
    final r = await client
        .post(
          endpoint('devicecode'),
          body: {'client_id': clientId, 'scope': scope},
        )
        .timeout(const Duration(seconds: 110));
    if (r.statusCode != 200) {
      throw const MailFailure(
        'Microsoft sign-in could not start. Enable public client flows and Mail.Read in your app registration.',
      );
    }
    final j = jsonDecode(r.body);
    final url = Uri.parse(j['verification_uri']);
    if (url.scheme != 'https' ||
        ![
          'microsoft.com',
          'www.microsoft.com',
          'login.microsoftonline.com',
        ].contains(url.host)) {
      throw const MailFailure('Microsoft returned an unexpected sign-in page.');
    }
    return DeviceSignIn(
      j['device_code'],
      j['user_code'],
      url.toString(),
      DateTime.now().add(
        Duration(seconds: (j['expires_in'] as int).clamp(60, 1200)),
      ),
      (j['interval'] as int? ?? 5).clamp(5, 30),
    );
  }

  Future<OutlookSession> complete(
    String clientId,
    DeviceSignIn signIn, {
    required bool Function() cancelled,
  }) async {
    var interval = signIn.interval;
    while (!cancelled() && DateTime.now().isBefore(signIn.expires)) {
      await Future<void>.delayed(Duration(seconds: interval));
      if (cancelled()) break;
      final r = await client
          .post(
            endpoint('token'),
            body: {
              'client_id': clientId,
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
              'device_code': signIn.deviceCode,
            },
          )
          .timeout(const Duration(seconds: 110));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200) return _session(clientId, j);
      if (j['error'] == 'authorization_pending') continue;
      if (j['error'] == 'slow_down' || r.statusCode == 429) {
        interval = (interval + 5).clamp(5, 60);
        continue;
      }
      throw const MailFailure(
        'Microsoft sign-in expired or was declined. Try connecting again.',
      );
    }
    throw const MailFailure('Microsoft sign-in was cancelled or expired.');
  }

  Future<OutlookSession> renew(OutlookSession old) async {
    if (old.expires.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
      return old;
    }
    final r = await client
        .post(
          endpoint('token'),
          body: {
            'client_id': old.clientId,
            'grant_type': 'refresh_token',
            'refresh_token': old.refreshToken,
            'scope': scope,
          },
        )
        .timeout(const Duration(seconds: 110));
    if (r.statusCode != 200) {
      throw const MailFailure('Reconnect Outlook to renew read permission.');
    }
    return _session(
      old.clientId,
      jsonDecode(r.body),
      previousRefresh: old.refreshToken,
    );
  }

  OutlookSession _session(
    String id,
    Map<String, dynamic> j, {
    String previousRefresh = '',
  }) {
    final token = j['access_token'] as String?,
        refresh = j['refresh_token'] as String? ?? previousRefresh;
    if (token == null || refresh.isEmpty) {
      throw const MailFailure(
        'Microsoft did not return renewable read permission.',
      );
    }
    return OutlookSession(
      id,
      token,
      refresh,
      DateTime.now().add(
        Duration(seconds: (j['expires_in'] as int? ?? 3600).clamp(30, 86400)),
      ),
    );
  }
}

class GmailAccount {
  final String email;
  final GmailDesktopSession? desktopSession;
  const GmailAccount(this.email, {this.desktopSession});
  String get id =>
      email.isEmpty ? 'gmail:legacy' : 'gmail:${email.toLowerCase()}';
  String get label => email.isEmpty ? 'Previously connected Gmail' : email;
  Map<String, dynamic> toJson() => {
    'email': email,
    if (desktopSession != null) 'desktopSession': desktopSession!.toJson(),
  };
  factory GmailAccount.fromJson(Map<String, dynamic> j) {
    final email = (j['email'] as String).trim().toLowerCase();
    if (email.length > 254 ||
        (email.isNotEmpty &&
            !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email))) {
      throw const FormatException('Invalid saved Google mailbox.');
    }
    return GmailAccount(
      email,
      desktopSession: j['desktopSession'] == null
          ? null
          : GmailDesktopSession.fromJson(
              Map<String, dynamic>.from(j['desktopSession']),
            ),
    );
  }
}

class MailController extends ChangeNotifier {
  final FlutterSecureStorage storage;
  final http.Client client;
  final bool googleDesktop;
  final GmailDesktopAuth? googleAuth;
  MailController({
    this.storage = const FlutterSecureStorage(),
    http.Client? client,
    bool? googleDesktop,
    this.googleAuth,
  }) : client = client ?? PrivateMailClient(),
       googleDesktop = googleDesktop ?? Platform.isWindows;
  bool refreshOnOpen = true, busy = false, ready = false, _closed = false;
  OutlookSession? outlook;
  List<GmailAccount> gmailAccounts = [];
  GmailDesktopConfig? gmailConfig;
  bool get gmail => gmailAccounts.isNotEmpty;
  GmailDesktopAuth get _desktopGoogleAuth =>
      googleAuth ?? GmailDesktopAuth(client);
  Future<void> _googleWrites = Future.value();
  List<ImapAccount> imapAccounts = [];
  String? notice;
  String? error;
  DateTime? lastCheck, retryAt;
  List<MailMessage> messages = [];
  static const prefsKey = 'calendula.mail.preferences.v1',
      outlookKey = 'calendula.mail.outlook.v1',
      imapKey = 'calendula.mail.imap.v1',
      gmailKey = 'calendula.mail.gmail.accounts.v2',
      gmailConfigKey = 'calendula.mail.gmail.config.v1',
      legacyGmailKey = 'calendula.mail.gmail.desktop.v1';
  static const maxGoogleAccounts = 8;
  Future<void> load() async {
    try {
      final raw = await storage.read(key: prefsKey);
      var legacyAndroid = false;
      if (raw != null) {
        final j = jsonDecode(raw);
        legacyAndroid = j['gmail'] == true;
        refreshOnOpen = j['refreshOnOpen'] != false;
      }
      final token = await storage.read(key: outlookKey);
      if (token != null) outlook = OutlookSession.fromJson(jsonDecode(token));
      final googleRaw = await storage.read(key: gmailKey);
      if (googleRaw != null) {
        final records = jsonDecode(googleRaw) as List;
        if (records.length > maxGoogleAccounts) throw const FormatException();
        gmailAccounts = records
            .map((j) => GmailAccount.fromJson(Map<String, dynamic>.from(j)))
            .toList();
      } else {
        final legacy = await storage.read(key: legacyGmailKey);
        if (googleDesktop && legacy != null) {
          final session = GmailDesktopSession.fromJson(jsonDecode(legacy));
          gmailAccounts = [GmailAccount('', desktopSession: session)];
          gmailConfig = GmailDesktopConfig(
            session.clientId,
            session.clientSecret,
          );
        } else if (!googleDesktop && legacyAndroid) {
          gmailAccounts = [const GmailAccount('')];
        }
      }
      final config = await storage.read(key: gmailConfigKey);
      if (config != null) {
        gmailConfig = GmailDesktopConfig.fromJson(jsonDecode(config));
      }
      final imap = await storage.read(key: imapKey);
      if (imap != null) {
        imapAccounts = (jsonDecode(imap) as List)
            .map((j) => ImapAccount.fromJson(Map<String, dynamic>.from(j)))
            .toList();
      }
    } catch (_) {
      error = 'Mail settings could not be unlocked.';
    }
    ready = true;
    _notify();
  }

  Future<void> preferences() => storage.write(
    key: prefsKey,
    value: jsonEncode({'gmail': gmail, 'refreshOnOpen': refreshOnOpen}),
  );

  Future<void> configureGmail(GmailDesktopConfig config) async {
    await storage.write(
      key: gmailConfigKey,
      value: jsonEncode(config.toJson()),
    );
    gmailConfig = config;
    _notify();
  }

  Future<void> _updateGmail(
    List<GmailAccount> Function(List<GmailAccount>) change,
  ) {
    final operation = _googleWrites.then((_) async {
      final next = change(gmailAccounts.toList());
      await storage.write(
        key: gmailKey,
        value: jsonEncode(next.map((a) => a.toJson()).toList()),
      );
      gmailAccounts = next;
      if (gmailConfig != null) {
        await storage.write(
          key: gmailConfigKey,
          value: jsonEncode(gmailConfig!.toJson()),
        );
      }
      await storage.delete(key: legacyGmailKey);
      await preferences();
    });
    _googleWrites = operation.catchError((_) {});
    return operation;
  }

  Future<String> _nativeGoogleToken({
    required bool interactive,
    String? email,
    bool chooseAccount = false,
  }) async {
    final token = await const MethodChannel('app.calendula/mail')
        .invokeMethod<String>('gmailToken', {
          'interactive': interactive,
          'chooseAccount': chooseAccount,
          if (email != null && email.isNotEmpty) 'email': email,
        });
    if (token == null || token.isEmpty) {
      throw const MailFailure('Google did not grant read access.');
    }
    return token;
  }

  Future<void> connectGmail({
    String desktopClientId = '',
    String desktopSecret = '',
    GmailAccount? reconnect,
  }) async {
    if (busy) {
      throw const MailFailure('Wait for the current mail check to finish.');
    }
    if (retryAt?.isAfter(DateTime.now()) ?? false) {
      throw MailFailure(
        'Mail is waiting for a provider retry. Try again later.',
        retryAt,
      );
    }
    if (reconnect == null && gmailAccounts.length >= maxGoogleAccounts) {
      throw const MailFailure(
        'Up to eight Google accounts can be connected. Disconnect one first.',
      );
    }
    busy = true;
    error = null;
    _notify();
    try {
      GmailDesktopSession? session;
      String token;
      if (googleDesktop) {
        if (desktopClientId.isNotEmpty || desktopSecret.isNotEmpty) {
          await configureGmail(
            GmailDesktopConfig(desktopClientId, desktopSecret),
          );
        }
        final config = gmailConfig;
        if (config == null) {
          throw const MailFailure(
            'Import your Google Desktop OAuth JSON once in Google project settings.',
          );
        }
        session = await _desktopGoogleAuth.connect(
          config.clientId,
          config.clientSecret,
          email: reconnect?.email,
        );
        token = session.accessToken;
      } else {
        token = await _nativeGoogleToken(
          interactive: true,
          email: reconnect?.email,
          chooseAccount: reconnect == null || reconnect.email.isEmpty,
        );
      }
      final api = MailApi(client: client),
          email = await api.gmailAddress(token);
      if (reconnect != null &&
          reconnect.email.isNotEmpty &&
          reconnect.email != email) {
        throw const MailFailure(
          'A different Google account was selected. Use Add Google account to connect it.',
        );
      }
      final account = GmailAccount(email, desktopSession: session);
      final read = await api.recent(
        MailProvider.gmail,
        token,
        accountId: account.id,
      );
      if (_closed) return;
      await _updateGmail(
        (accounts) => [
          ...accounts.where((a) => a.id != account.id && a.id != reconnect?.id),
          account,
        ],
      );
      messages = [
        ...messages.where(
          (m) =>
              m.accountId != account.id &&
              (reconnect == null || m.accountId != reconnect.id),
        ),
        ...read,
      ]..sort((a, b) => b.received.compareTo(a.received));
      lastCheck = DateTime.now();
      retryAt = null;
    } on MailFailure catch (e) {
      if (e.retryAt != null) retryAt = e.retryAt;
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> disconnectGmail(String id) async {
    await _updateGmail(
      (accounts) => accounts.where((a) => a.id != id).toList(),
    );
    messages.removeWhere((m) => m.accountId == id);
    _notify();
  }

  Future<void> saveOutlook(OutlookSession session) async {
    outlook = session;
    await storage.write(key: outlookKey, value: jsonEncode(session.toJson()));
    _notify();
    await refresh();
  }

  Future<void> connectImap(ImapAccount account) async {
    if (busy) {
      throw const MailFailure('Wait for the current mail check to finish.');
    }
    if (imapAccounts.length >= 4 &&
        !imapAccounts.any((a) => a.id == account.id)) {
      throw const MailFailure(
        'Up to four IMAP accounts can be connected. Disconnect one first.',
      );
    }
    busy = true;
    error = null;
    _notify();
    try {
      final read = await readImap(account);
      final accounts = [
        ...imapAccounts.where((a) => a.id != account.id),
        account,
      ];
      await storage.write(
        key: imapKey,
        value: jsonEncode(accounts.map((a) => a.toJson()).toList()),
      );
      imapAccounts = accounts;
      messages = [
        ...messages.where((m) => m.accountId != account.id),
        ...read.messages,
      ]..sort((a, b) => b.received.compareTo(a.received));
      notice = read.skipped == 0
          ? null
          : '${read.skipped} large messages skipped (1 MB per message, 5 MB per check). Share an attachment to import it.';
      lastCheck = DateTime.now();
      retryAt = null;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> disconnectImap(String id) async {
    final accounts = imapAccounts.where((a) => a.id != id).toList();
    await storage.write(
      key: imapKey,
      value: jsonEncode(accounts.map((a) => a.toJson()).toList()),
    );
    imapAccounts = accounts;
    messages.removeWhere((m) => m.accountId == id);
    _notify();
  }

  Future<void> disconnect(MailProvider provider) async {
    if (provider == MailProvider.gmail) {
      await _updateGmail((_) => []);
    } else {
      outlook = null;
      await storage.delete(key: outlookKey);
    }
    messages.removeWhere((m) => m.provider == provider);
    await preferences();
    _notify();
  }

  Future<void> refresh({bool automatic = false}) async {
    if (!ready ||
        busy ||
        _closed ||
        (automatic && !refreshOnOpen) ||
        (!gmail && outlook == null && imapAccounts.isEmpty)) {
      return;
    }
    final now = DateTime.now();
    if ((retryAt?.isAfter(now) ?? false) ||
        (lastCheck != null && now.difference(lastCheck!).inSeconds < 60)) {
      if (!automatic) {
        error = 'Mail was recently checked or is waiting for a provider retry.';
        _notify();
      }
      return;
    }
    busy = true;
    error = null;
    lastCheck = now;
    _notify();
    final next = <MailMessage>[];
    final failures = <String>[];
    retryAt = null;
    final googleUpdates = <String, GmailAccount>{};
    for (final account in gmailAccounts.toList()) {
      try {
        String token;
        GmailDesktopSession? session;
        if (googleDesktop) {
          if (account.desktopSession == null) {
            throw const MailFailure('Reconnect this Windows Google account.');
          }
          session = await _desktopGoogleAuth.renew(account.desktopSession!);
          token = session.accessToken;
        } else {
          token = await _nativeGoogleToken(
            interactive: false,
            email: account.email,
          );
        }
        final api = MailApi(client: client),
            email = await api.gmailAddress(token);
        if (account.email.isNotEmpty && account.email != email) {
          throw const MailFailure(
            'Google returned a different mailbox. Reconnect this account.',
          );
        }
        final resolved = GmailAccount(email, desktopSession: session);
        final read = await api.recent(
          MailProvider.gmail,
          token,
          accountId: resolved.id,
        );
        if (gmailAccounts.any((a) => a.id == account.id)) {
          next.addAll(read);
          googleUpdates[account.id] = resolved;
        }
      } catch (e) {
        if (gmailAccounts.any((a) => a.id == account.id)) {
          next.addAll(messages.where((m) => m.accountId == account.id));
        }
        failures.add(
          '${account.label}: ${e is MailFailure ? e.message : 'Read permission or connection unavailable.'}',
        );
        final pause = e is MailFailure ? e.retryAt : null;
        final until = pause ?? DateTime.now().add(const Duration(minutes: 2));
        if (retryAt == null || until.isAfter(retryAt!)) retryAt = until;
      }
    }
    if (googleUpdates.isNotEmpty) {
      try {
        await _updateGmail(
          (accounts) => {
            for (final a in accounts)
              (googleUpdates[a.id] ?? a).id: googleUpdates[a.id] ?? a,
          }.values.toList(),
        );
      } catch (_) {
        failures.add('Updated Google permissions could not be saved securely.');
      }
    }
    // A local disconnect during a network read must not restore its messages.
    next.removeWhere(
      (m) =>
          m.provider == MailProvider.gmail &&
          !gmailAccounts.any((a) => a.id == m.accountId),
    );
    if (outlook != null) {
      try {
        outlook = await OutlookAuth(client).renew(outlook!);
        await storage.write(
          key: outlookKey,
          value: jsonEncode(outlook!.toJson()),
        );
        next.addAll(
          await MailApi(client: client)
              .recent(MailProvider.outlook, outlook!.accessToken),
        );
      } catch (e) {
        next.addAll(messages.where((m) => m.provider == MailProvider.outlook));
        failures.add(
          'outlook: ${e is MailFailure ? e.message : 'Read permission or connection unavailable.'}',
        );
        final until =
            (e is MailFailure ? e.retryAt : null) ??
            DateTime.now().add(const Duration(minutes: 2));
        if (retryAt == null || until.isAfter(retryAt!)) retryAt = until;
      }
    }
    var skipped = 0;
    for (final account in imapAccounts.toList()) {
      try {
        final read = await readImap(account);
        // Disconnect may have happened while this read was in flight.
        if (imapAccounts.any((a) => a.id == account.id)) {
          next.addAll(read.messages);
        }
        skipped += read.skipped;
      } catch (e) {
        if (imapAccounts.any((a) => a.id == account.id)) {
          next.addAll(messages.where((m) => m.accountId == account.id));
        }
        failures.add(
          'IMAP: ${e is MailFailure ? e.message : 'Private connection unavailable. Check again later.'}',
        );
        final until = DateTime.now().add(const Duration(minutes: 5));
        if (retryAt == null || until.isAfter(retryAt!)) retryAt = until;
      }
    }
    notice = skipped == 0
        ? null
        : '$skipped large messages skipped. Share the attachment to import it.';
    messages = next..sort((a, b) => b.received.compareTo(a.received));
    error = failures.isEmpty ? null : failures.join('\n');
    busy = false;
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    client.close();
    super.dispose();
  }
}
