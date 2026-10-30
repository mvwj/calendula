import 'package:flutter/material.dart';

import 'mail.dart';

/// Decoded local text only: no HTML renderer, remote images or automatic import.
class MailMessagePage extends StatelessWidget {
  final MailMessage message;
  final VoidCallback review;
  const MailMessagePage({
    super.key,
    required this.message,
    required this.review,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Message')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          SelectableText(
            message.subject.isEmpty ? '(No subject)' : message.subject,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          SelectableText(message.sender),
          const SizedBox(height: 24),
          SelectableText(
            message.text.trim().isEmpty
                ? 'This message has no readable text body.'
                : message.text,
          ),
          if (message.calendarAttachments.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '${message.calendarAttachments.length} calendar attachment(s)',
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: review,
            icon: const Icon(Icons.event_outlined),
            label: const Text('Review invitation'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Reading keeps the mailbox unchanged. Calendar changes require your review.',
          ),
        ],
      ),
    ),
  );
}
