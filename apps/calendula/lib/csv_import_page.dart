import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'calendar.dart';
import 'main.dart';
import 'schedule_csv.dart';
import 'event_place.dart';

import 'package:file_selector/file_selector.dart';

const importChannel = MethodChannel('app.calendula/import');

class CsvImportPage extends StatefulWidget {
  final List<CalendarEvent> existing;
  final Future<bool> Function(List<CalendarEvent>) commit;
  final Future<Map<String, dynamic>?> Function()? pickFile;
  const CsvImportPage({
    super.key,
    required this.existing,
    required this.commit,
    this.pickFile,
  });
  @override
  State<CsvImportPage> createState() => _CsvImportPageState();
}

class _CsvImportPageState extends State<CsvImportPage> {
  CsvSchedule? schedule;
  String filename = '', error = '';
  bool busy = false;
  late DateTime anchor, from, through;
  Set<String> selected = {};
  final types = <String, String>{};
  bool mffPlaces = true;
  Map<String, CalendarEvent> get learned =>
      reusableMeetingDetails(widget.existing);
  @override
  void initState() {
    super.initState();
    final today = localNow();
    final septemberEnd = DateTime.utc(
      today.month < 7 ? today.year - 1 : today.year,
      9,
      30,
    );
    anchor = septemberEnd.subtract(Duration(days: septemberEnd.weekday - 1));
    from = DateTime.utc(today.year, today.month, today.day);
    if (today.weekday > 5) {
      from = from.add(Duration(days: 8 - today.weekday));
    }
    through = from.add(const Duration(days: 13));
  }

  Future<void> pick() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final file = widget.pickFile != null
          ? await widget.pickFile!()
          : Platform.isAndroid
          ? await importChannel.invokeMapMethod<String, dynamic>('pickCsv')
          : await desktopCsv();
      if (file == null) {
        return;
      }
      final parsed = CsvSchedule.decode(file['bytes'] as Uint8List);
      if (mounted) {
        setState(() {
          schedule = parsed;
          filename = file['name'] as String;
          selected = parsed.rules.map((r) => r.key).toSet();
          types.clear();
          for (final rule in parsed.rules) {
            final value =
                learned['sis:${Uri.encodeComponent(rule.parentId)}:${Uri.encodeComponent(rule.id)}']
                    ?.sessionType;
            if (rule.sessionType.isEmpty && value != null && value.isNotEmpty) {
              types[rule.key] = value;
            }
          }
        });
      }
    } on FormatException catch (e) {
      if (mounted) {
        setState(() => error = e.message);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => error = e.message ?? 'File could not be opened.');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> date(String which) async {
    final initial = which == 'Week 1 starts'
        ? anchor
        : which == 'Import from'
        ? from
        : through;
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
    );
    if (d != null && mounted) {
      setState(() {
        final value = DateTime.utc(d.year, d.month, d.day);
        if (which == 'Week 1 starts') {
          anchor = value;
        } else if (which == 'Import from') {
          from = value;
        } else {
          through = value;
        }
      });
    }
  }

  Future<void> commit(List<CalendarEvent> fresh) async {
    setState(() {
      busy = true;
      error = '';
    });
    final saved = await widget.commit([...widget.existing, ...fresh]);
    if (!mounted) {
      return;
    }
    if (saved) {
      Navigator.pop(context, fresh);
    } else {
      setState(() {
        busy = false;
        error = 'Could not save the import. Your calendar has been preserved. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    List<CalendarEvent> expanded = [];
    String validation = '';
    try {
      expanded =
          schedule?.expand(
            weekOneMonday: anchor,
            from: from,
            through: through,
            selected: selected,
            types: types,
            mffPlaces: mffPlaces,
            meetingDetails: learned,
          ) ??
          [];
    } on FormatException catch (e) {
      validation = e.message;
    }
    final existingIds = widget.existing.map((e) => e.id).toSet();
    final fresh = expanded.where((e) => !existingIds.contains(e.id)).toList();
    final duplicates = expanded.length - fresh.length;
    final conflicts = conflictIds([...widget.existing, ...fresh]);
    final conflictCount = fresh.where((e) => conflicts.contains(e.id)).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Import schedule')),
      bottomNavigationBar: schedule == null
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: FilledButton.icon(
                onPressed: busy || validation.isNotEmpty || fresh.isEmpty
                    ? null
                    : () => commit(fresh),
                icon: const Icon(Icons.check_rounded),
                label: Text(busy ? 'Saving…' : 'Import ${fresh.length} events'),
              ),
            ),
      body: centered(
        ListView(
          padding: const EdgeInsets.all(24),
          children: [
            eyebrow('A SCHEDULE, MADE YOURS'),
            title('A little order.'),
            const SizedBox(height: 12),
            const Text(
              'Open a SIS CSV, check its weeks, then add the dates you choose. Everything is read on this device.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: busy ? null : pick,
              icon: const Icon(Icons.folder_open_rounded),
              label: Text(
                busy
                    ? 'Opening…'
                    : schedule == null
                    ? 'Choose CSV file'
                    : 'Choose another CSV',
              ),
            ),
            if (error.isNotEmpty || validation.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error.isNotEmpty ? error : validation,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (schedule != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: categoryColor('Study'),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      filename,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${schedule!.rules.length} meeting rules · ${schedule!.encoding}',
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                    const SizedBox(height: 15),
                    const Text(
                      'Check semester weeks and places. Missing class types need a choice below; they cannot be inferred from a room. Holidays and cancellations need review.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Charles University · MFF room directory'),
                subtitle: const Text(
                  'Known Malá Strana rooms get an official building address and available floor. Turn off for other faculties.',
                ),
                value: mffPlaces,
                onChanged: busy
                    ? null
                    : (value) => setState(() => mffPlaces = value),
              ),
              for (final name in [
                'Week 1 starts',
                'Import from',
                'Import through',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton(
                    onPressed: busy ? null : () => date(name),
                    child: Row(
                      children: [
                        Expanded(child: Text(name)),
                        Text(
                          DateFormat('EEE, d MMM yyyy').format(
                            name == 'Week 1 starts'
                                ? anchor
                                : name == 'Import from'
                                ? from
                                : through,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                '${fresh.length} new events${duplicates > 0 ? ' · $duplicates already imported' : ''}',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$conflictCount new events overlap another event. ${fresh.where((e) => e.address.isEmpty).length} need an address; ${fresh.where((e) => e.sessionType.isEmpty).length} have no class type. Review before import.',
                style: const TextStyle(fontSize: 13, color: muted),
              ),
              const SizedBox(height: 20),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Check dates & times'),
                initiallyExpanded: true,
                children: [
                  for (final e in expanded)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        conflicts.contains(e.id)
                            ? Icons.warning_amber_rounded
                            : Icons.event_outlined,
                        color: conflicts.contains(e.id)
                            ? const Color(0xFFAC612A)
                            : forest,
                      ),
                      title: Text(
                        '${e.courseCode} · ${e.title}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '${DateFormat('EEE, d MMM').format(e.localStart)} · ${clock(e.localStart)}–${clock(e.localEnd)}${e.sessionType.isEmpty ? ' · type not specified' : ' · ${e.sessionType}'}${e.room.isEmpty ? '' : ' · Room ${e.room}'}\n${e.address.isEmpty ? 'Address needs review' : e.address}${e.floor.isEmpty ? '' : ' · Floor ${e.floor}'}${existingIds.contains(e.id) ? ' · already imported' : ''}',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Choose meeting rules (${selected.length}/${schedule!.rules.length})',
                ),
                children: [
                  for (final r in schedule!.rules)
                    Column(
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: selected.contains(r.key),
                          onChanged: busy
                              ? null
                              : (checked) => setState(() {
                                  checked == true
                                      ? selected.add(r.key)
                                      : selected.remove(r.key);
                                }),
                          title: Text(
                            '${r.code} · ${r.title}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][r.weekday - 1]} ${r.timing}${r.room.isEmpty ? '' : ' · Room ${r.room}'}\n${r.recurrence}',
                          ),
                        ),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: types[r.key] ?? r.sessionType,
                          decoration: const InputDecoration(
                            labelText: 'Class type',
                          ),
                          items: [
                            for (final type in sessionTypes)
                              DropdownMenuItem(
                                value: type,
                                child: Text(
                                  type.isEmpty ? 'Not specified' : type,
                                ),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (value) =>
                                    setState(() => types[r.key] = value!),
                        ),
                        const SizedBox(height: 14),
                      ],
                    ),
                ],
              ),
            ],
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

Future<Map<String, dynamic>?> desktopCsv() async {
  final file = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(label: 'CSV schedule', extensions: ['csv']),
    ],
  );
  if (file == null) return null;
  if (await file.length() > 2 * 1024 * 1024) {
    throw const FormatException('Choose a CSV smaller than 2 MB.');
  }
  return {'name': file.name, 'bytes': await file.readAsBytes()};
}
