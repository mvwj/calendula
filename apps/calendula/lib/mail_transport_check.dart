import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop_tor.dart';
import 'imap_mail.dart';

/// Public, unauthenticated probe. Never loads mailbox credentials or messages.
Future<Map<String, dynamic>> mailTransportCheck() async {
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'host': 'imap.gmail.com',
    'mailboxRead': false,
  };
  ReadOnlyImap? session;
  try {
    final socket = await privateImapSocket('imap.gmail.com');
    report['validatedTlsThroughTor'] = true;
    session = ReadOnlyImap(socket);
    final greeting = await session.line().timeout(const Duration(seconds: 30));
    if (!greeting.startsWith('* OK')) {
      throw StateError('Unexpected greeting');
    }
    final caps = await session
        .command('CAPABILITY')
        .timeout(const Duration(seconds: 30));
    report['imapReady'] = caps.lines.any(
      (l) => l.startsWith('* CAPABILITY') && l.contains('IMAP4rev1'),
    );
  } catch (e) {
    report['errorType'] = e.runtimeType.toString();
  } finally {
    if (session != null) {
      await session.close();
    }
    if (Platform.isWindows) {
      await DesktopTor.instance.stop();
    }
  }
  return report;
}

Future<void> windowsMailTransportCheck(List<String> args) async {
  runApp(const SizedBox.shrink());
  final report = await mailTransportCheck();
  final destination = args
      .firstWhere((s) => s.startsWith('--check-report='))
      .substring(15);
  await File(destination).writeAsString(jsonEncode(report), flush: true);
  exit(report['imapReady'] == true ? 0 : 1);
}

Future<void> androidMailTransportCheck() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.calendula/sync-check');
  final report = await mailTransportCheck();
  await channel.invokeMethod(
    'complete',
    '${report['imapReady'] == true ? 'PASS' : 'FAIL'}: ${jsonEncode(report)}',
  );
}
