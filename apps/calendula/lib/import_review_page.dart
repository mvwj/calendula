import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdfrx/pdfrx.dart';

import 'calendar.dart';
import 'editor.dart';
import 'main.dart';
import 'schedule_import.dart';

Future<ImportBatch> importDocument(
  String name,
  Uint8List bytes,
  DateTime from,
  DateTime through,
) async {
  if (bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('Choose a file smaller than 20 MB.');
  }
  final ext = name.split('.').last.toLowerCase();
  if (ext == 'xlsx') {
    return parseScheduleRows(readXlsx(bytes), source: 'spreadsheet');
  }
  if (ext == 'xls') {
    throw const FormatException(
      'Save this legacy Excel file as .xlsx or CSV, then import it.',
    );
  }
  if (ext == 'pdf') {
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openData(bytes);
    try {
      if (document.pages.length > 100) {
        throw const FormatException('Choose a PDF with up to 100 pages.');
      }
      final buffer = StringBuffer();
      for (final page in document.pages) {
        final text = await page.loadText();
        buffer.writeln(text?.fullText ?? '');
        if (buffer.length > 500000) {
          throw const FormatException('PDF text exceeds the supported size.');
        }
      }
      if (buffer.toString().trim().isEmpty) {
        throw const FormatException(
          'This PDF is a scan with no text layer. OCR is not available yet; paste its text or add events manually.',
        );
      }
      return recognizeText(buffer.toString(), source: 'pdf');
    } finally {
      await document.dispose();
    }
  }
  final text = utf8
      .decode(bytes, allowMalformed: false)
      .replaceFirst(RegExp(r'^\uFEFF'), '');
  if (ext == 'ics' || text.contains('BEGIN:VEVENT')) {
    return parseIcs(text, from: from, through: through);
  }
  if (ext == 'csv' || ext == 'tsv') {
    final separator = ext == 'tsv'
        ? '\t'
        : text.split('\n').first.contains(';')
        ? ';'
        : ',';
    return parseScheduleRows(parseDelimited(text, separator));
  }
  return recognizeText(text);
}

List<List<String>> parseDelimited(String text, String delimiter) {
  final rows = <List<String>>[], row = <String>[];
  var field = StringBuffer(), quote = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"') {
      if (quote && i + 1 < text.length && text[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        quote = !quote;
      }
    } else if (c == delimiter && !quote) {
      row.add(field.toString());
      field = StringBuffer();
    } else if (c == '\n' && !quote) {
      row.add(field.toString().replaceAll(RegExp(r'\r$'), ''));
      rows.add([...row]);
      row.clear();
      field = StringBuffer();
    } else {
      field.write(c);
    }
  }
  if (quote) throw const FormatException('CSV has an unclosed quoted cell.');
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

class ImportReviewPage extends StatefulWidget {
  final List<CalendarEvent> existing;
  final Future<bool> Function(List<CalendarEvent>) commit;
  final ImportBatch? initial;
  final String heading;
  const ImportReviewPage({
    super.key,
    required this.existing,
    required this.commit,
    this.initial,
    this.heading = 'Import a schedule',
  });
  @override
  State<ImportReviewPage> createState() => _ImportReviewPageState();
}

class _ImportReviewPageState extends State<ImportReviewPage> {
  ImportBatch? batch;
  final paste = TextEditingController();
  Set<String> selected = {};
  bool busy = false;
  String? error;
  late DateTime from, through;
  @override
  void initState() {
    super.initState();
    from = localNow();
    through = DateTime(from.year, from.month, from.day + 90);
    if (widget.initial != null) setBatch(widget.initial!);
  }

  @override
  void dispose() {
    paste.dispose();
    super.dispose();
  }

  void setBatch(ImportBatch value) {
    batch = value;
    selected = value.events
        .take(250)
        .where((e) => !widget.existing.any((old) => old.id == e.id))
        .map((e) => e.id)
        .toSet();
    if (value.sourceText.isNotEmpty) paste.text = value.sourceText;
  }

  Future<void> execute(Future<ImportBatch> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await action();
      if (mounted) setState(() => setBatch(value));
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : 'File could not be read. Check its format and encoding.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pick() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Schedules',
          extensions: ['pdf', 'xlsx', 'xls', 'ics', 'csv', 'tsv', 'txt'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    await execute(() async {
      if (await file.length() > 20 * 1024 * 1024) {
        throw const FormatException('File exceeds 20 MB.');
      }
      return importDocument(file.name, await file.readAsBytes(), from, through);
    });
  }

  Future<void> inspect(CalendarEvent event) async {
    final edit = await Navigator.push<CalendarEvent>(
      context,
      MaterialPageRoute(
        builder: (_) => EventEditor(event: event, day: event.localStart),
      ),
    );
    if (edit != null && mounted) {
      setState(
        () => batch = ImportBatch(
          batch!.events.map((e) => e.id == event.id ? edit : e).toList(),
          warnings: batch!.warnings,
          sourceText: batch!.sourceText,
        ),
      );
    }
  }

  Future<void> commit() async {
    final next = batch!.events
        .where(
          (e) =>
              selected.contains(e.id) &&
              !widget.existing.any((old) => old.id == e.id),
        )
        .toList();
    setState(() => busy = true);
    final saved = await widget.commit([...widget.existing, ...next]);
    if (mounted) {
      setState(() => busy = false);
      if (saved) {
        Navigator.pop(context, next);
      } else {
        setState(
          () => error = 'Could not save the import. Existing events were kept.',
        );
      }
    }
  }

  Future<void> changeWindow(bool first) async {
    final date = await showDatePicker(
      context: context,
      initialDate: first ? from : through,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date != null && mounted) {
      setState(() {
        if (first) {
          from = date;
        } else {
          through = date;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.heading)),
    body: centered(
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          eyebrow('READ LOCALLY · REVIEW BEFORE SAVING'),
          title('Make room for your plans'),
          const SizedBox(height: 12),
          const Text(
            'ICS, XLSX, text PDF and text schedules. Each result stays editable; unsupported records are listed below.',
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => changeWindow(true),
                child: Text('From ${DateFormat('d MMM y').format(from)}'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => changeWindow(false),
                child: Text('Through ${DateFormat('d MMM y').format(through)}'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: busy ? null : pick,
            icon: const Icon(Icons.upload_file),
            label: const Text('Choose schedule file'),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: paste,
            minLines: 4,
            maxLines: 9,
            maxLength: 500000,
            decoration: const InputDecoration(
              labelText: 'Paste or correct source text',
            ),
          ),
          OutlinedButton(
            onPressed: busy
                ? null
                : () => execute(
                    () async => paste.text.contains('BEGIN:VEVENT')
                        ? parseIcs(paste.text, from: from, through: through)
                        : recognizeText(paste.text),
                  ),
            child: const Text('Recognize text'),
          ),
          const Text(
            'Example: Cinema 2026-10-05 18:30–20:30 | Kino Světozor\nTables: Title, Date, Start, End, Venue, Address, Room, Floor',
            style: TextStyle(fontSize: 12, color: muted),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(18),
              child: LinearProgressIndicator(),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          if (batch != null) ...[
            const SizedBox(height: 24),
            Text(
              '${batch!.events.length} events found · ${selected.length} selected',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final warning in batch!.warnings.take(30))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  warning,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ),
            if (batch!.events.length > 250)
              const Text(
                'Only the first 250 records can be selected in this review. Shorten the date window to import another batch.',
              ),
            for (final e in batch!.events.take(250))
              Card(
                color: Colors.white,
                child: CheckboxListTile(
                  value: selected.contains(e.id),
                  onChanged: widget.existing.any((old) => old.id == e.id)
                      ? null
                      : (v) => setState(() {
                          if (v == true) {
                            selected.add(e.id);
                          } else {
                            selected.remove(e.id);
                          }
                        }),
                  title: Text(e.title),
                  subtitle: Text(
                    '${DateFormat('EEE d MMM').format(e.localStart)} · ${e.allDay ? 'All day' : '${clock(e.localStart)}–${clock(e.localEnd)}'}\n${e.venue}${e.room.isEmpty ? '' : ' · Room ${e.room}'}${widget.existing.any((old) => old.id == e.id) ? '\nAlready imported' : ''}',
                  ),
                  secondary: IconButton(
                    onPressed: () => inspect(e),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy || selected.isEmpty ? null : commit,
              child: Text('Add ${selected.length} reviewed events'),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    ),
  );
}
