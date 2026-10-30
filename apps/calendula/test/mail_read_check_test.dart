import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calendula/mail.dart';
import 'package:calendula/mail_message_page.dart';
import 'package:calendula/mail_read_check.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final message = MailMessage(
    provider: MailProvider.gmail,
    id: 'synthetic-private-id',
    subject: 'Synthetic subject',
    sender: 'private@example.invalid',
    text: 'Synthetic body with private details',
    received: DateTime.utc(2026, 10, 5),
    accountId: 'private@example.invalid',
  );
  test('Actual-mail diagnostics only export aggregate evidence, including failures', () {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = MailController();
    addTearDown(controller.dispose);
    controller.messages = [message];
    controller.error =
        'private@example.invalid: sensitive provider error token-123';
    controller.lastCheck = DateTime.utc(2026, 10, 5);
    final report = mailboxReadSummary(controller);
    expect(report['messages'], 1);
    expect(report['textBodies'], 1);
    expect(report['providerFailure'], true);
    final encoded = jsonEncode(report);
    for (final private in [
      message.id,
      message.subject,
      message.sender,
      message.text,
      'token-123',
      'sensitive provider error',
    ]) {
      expect(encoded, isNot(contains(private)));
    }
    expect(report['calendarModified'], false);
    expect(report['mailModified'], false);
  });
  testWidgets(
    'Reading a decoded message does not invoke invitation parsing or commit',
    (tester) async {
      var reviews = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MailMessagePage(message: message, review: () => reviews++),
        ),
      );
      expect(find.text(message.text), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(reviews, 0);
      await tester.tap(find.text('Review invitation'));
      expect(reviews, 1);
    },
  );
}
