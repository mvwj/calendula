import 'dart:typed_data';

import 'calendar.dart';
import 'imap_mail.dart';
import 'import_review_page.dart';
import 'mail.dart';
import 'schedule_import.dart';

ImportBatch invitationBatch(
  MailMessage message,
  DateTime from,
  DateTime through,
) {
  final events = <CalendarEvent>[], warnings = <String>[];
  for (final attachment in message.calendarAttachments.take(10)) {
    try {
      final batch = parseIcs(attachment, from: from, through: through);
      events.addAll(batch.events);
      warnings.addAll(batch.warnings);
    } on FormatException catch (e) {
      warnings.add(e.message);
    }
  }
  final text = '${message.subject}\n${message.text}';
  if (events.isEmpty) {
    final batch = recognizeText(
      text,
      source: '${message.provider.name}:${message.id}',
    );
    events.addAll(batch.events);
    warnings.addAll(batch.warnings);
  }
  return ImportBatch(events, warnings: warnings, sourceText: text);
}

Future<ImportBatch> sharedInvitation(
  Map<dynamic, dynamic> payload,
  DateTime from,
  DateTime through,
) async {
  if (payload['error'] is String) throw FormatException(payload['error']);
  final text = payload['text'] as String? ?? '',
      subject = payload['subject'] as String? ?? '';
  if (text.length + subject.length > 200000) {
    throw const FormatException('Shared text exceeds its size limit.');
  }
  final events = <CalendarEvent>[], warnings = <String>[], sources = <String>[];
  if (text.trim().isNotEmpty) {
    final batch = text.contains('BEGIN:VEVENT')
        ? parseIcs(text, from: from, through: through)
        : recognizeText('$subject\n$text', source: 'shared-text');
    events.addAll(batch.events);
    warnings.addAll(batch.warnings);
    sources.add('$subject\n$text');
  }
  final files = payload['files'] as List? ?? [];
  if (files.length > 3) {
    throw const FormatException('Share up to three files at a time.');
  }
  var total = 0;
  for (final file in files) {
    final bytes = file['bytes'] as Uint8List;
    total += bytes.length;
    if (total > 20 * 1024 * 1024) {
      throw const FormatException('Shared files exceed 20 MB in total.');
    }
    try {
      final name = file['name'] as String;
      final batch = name.toLowerCase().endsWith('.eml')
          ? invitationBatch(
              parseImapMessage(
                bytes,
                const ImapAccount('shared.invalid', 'shared', ''),
                'shared',
                1,
              ),
              from,
              through,
            )
          : await importDocument(name, bytes, from, through);
      events.addAll(batch.events);
      warnings.addAll(batch.warnings);
      if (batch.sourceText.isNotEmpty) sources.add(batch.sourceText);
    } on FormatException catch (e) {
      warnings.add(e.message);
    }
  }
  if (events.isEmpty && warnings.isEmpty) {
    warnings.add(
      'No dated event was found. Paste the invitation text or add the event manually.',
    );
  }
  final unique = <String, CalendarEvent>{for (final e in events) e.id: e};
  return ImportBatch(
    unique.values.toList(),
    warnings: warnings,
    sourceText: sources.join('\n\n'),
  );
}
