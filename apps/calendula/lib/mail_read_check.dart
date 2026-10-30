import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mail.dart';

/// A fixed allowlist of aggregate results. Never serializes a provider error,
/// account, subject, sender, identifier, body, attachment or credential.
Map<String, dynamic> mailboxReadSummary(MailController controller) => {
  'gmailAccounts': controller.gmailAccounts.length,
  'outlookAccounts': controller.outlook == null ? 0 : 1,
  'imapAccounts': controller.imapAccounts.length,
  'checkAttempted': controller.lastCheck != null,
  'providerFailure': controller.error != null,
  'providerPause': controller.retryAt != null,
  'messages': controller.messages.length,
  'textBodies': controller.messages
      .where((m) => m.text.trim().isNotEmpty)
      .length,
  'calendarAttachments': controller.messages.fold<int>(
    0,
    (n, m) => n + m.calendarAttachments.length,
  ),
  'mailModified': false,
  'calendarRead': false,
  'calendarModified': false,
  'contentExported': false,
};

/// Explicit owner-authorized device check, not scheduled mailbox polling.
Future<void> androidMailboxReadCheck() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = MailController();
  Map<String, dynamic> report;
  try {
    await controller.load();
    if (controller.error == null) await controller.refresh();
    report = mailboxReadSummary(controller);
  } catch (_) {
    report = {'checkFailed': true, 'contentExported': false};
  } finally {
    controller.dispose();
  }
  final passed =
      report['checkAttempted'] == true &&
      report['providerFailure'] == false &&
      (report['textBodies'] as int? ?? 0) > 0;
  await const MethodChannel('app.calendula/sync-check').invokeMethod(
    'complete',
    '${passed ? 'PASS' : 'FAIL'}: ${jsonEncode(report)}',
  );
}
