import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'event_place.dart';
import 'main.dart';

DateTime wallTime(DateTime date, TimeOfDay time) {
  final v = tz.TZDateTime(
    prague,
    date.year,
    date.month,
    date.day,
    time.hour,
    time.minute,
  );
  bool same(DateTime d) =>
      d.year == date.year &&
      d.month == date.month &&
      d.day == date.day &&
      d.hour == time.hour &&
      d.minute == time.minute;
  if (!same(v)) {
    throw const FormatException(
      'This time does not exist because clocks change.',
    );
  }
  if (same(v.subtract(const Duration(hours: 1))) ||
      same(v.add(const Duration(hours: 1)))) {
    throw const FormatException(
      'This time is ambiguous because clocks change. Choose another time in this preview.',
    );
  }
  return v.toUtc();
}

class EventEditor extends StatefulWidget {
  final CalendarEvent? event;
  final DateTime day;
  final void Function(bool)? applyToSeries;
  const EventEditor({
    super.key,
    this.event,
    required this.day,
    this.applyToSeries,
  });
  @override
  State<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<EventEditor> {
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  late DateTime day, endDay;
  late TimeOfDay start, end;
  late String category;
  String sessionType = '';
  bool series = false;
  bool allDay = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final e = widget.event == null ? null : effectiveEvent(widget.event!);
    sessionType = sessionTypes.contains(e?.sessionType) ? e!.sessionType : '';
    allDay = e?.allDay ?? false;
    day = e?.localStart ?? widget.day;
    endDay = e?.localEnd ?? day;
    start = e == null
        ? const TimeOfDay(hour: 10, minute: 0)
        : TimeOfDay.fromDateTime(e.localStart);
    end = e == null
        ? const TimeOfDay(hour: 11, minute: 0)
        : TimeOfDay.fromDateTime(e.localEnd);
    category = categories.contains(e?.category) ? e!.category : 'Personal';
    fields = {
      'Title': TextEditingController(text: e?.title),
      'Venue': TextEditingController(text: e?.venue),
      'Address': TextEditingController(text: e?.address),
      'Room': TextEditingController(text: e?.room),
      'Floor': TextEditingController(text: e?.floor),
      'Notes': TextEditingController(text: e?.notes),
      'From transit stop': TextEditingController(text: e?.originStop),
      'To transit stop': TextEditingController(text: e?.destinationStop),
      'Walk to first stop': TextEditingController(
        text: '${e?.originWalkMinutes ?? 0}',
      ),
      'Walk from last stop': TextEditingController(
        text: '${e?.destinationWalkMinutes ?? 0}',
      ),
      'Travel minutes': TextEditingController(text: '${e?.travelMinutes ?? 0}'),
      'Arrival buffer': TextEditingController(
        text: '${e?.bufferMinutes ?? 10}',
      ),
    };
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> date(bool finish) async {
    final d = await showDatePicker(
      context: context,
      initialDate: finish ? endDay : day,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
    );
    if (d != null) {
      setState(() {
        if (finish) {
          endDay = d;
        } else {
          final same = dayKey(day) == dayKey(endDay);
          day = d;
          if (same) {
            endDay = d;
          }
        }
      });
    }
  }

  Future<void> time(bool finish) async {
    final t = await showTimePicker(
      context: context,
      initialTime: finish ? end : start,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t != null) {
      setState(() {
        if (finish) {
          end = t;
        } else {
          start = t;
        }
      });
    }
  }

  void submit() {
    if (!form.currentState!.validate()) {
      return;
    }
    try {
      final a = wallTime(
            day,
            allDay ? const TimeOfDay(hour: 0, minute: 0) : start,
          ),
          b = wallTime(
            endDay,
            allDay ? const TimeOfDay(hour: 0, minute: 0) : end,
          );
      if (!b.isAfter(a)) {
        throw const FormatException('End must be after start.');
      }
      String val(String key) => fields[key]!.text.trim();
      final original = widget.event == null
          ? null
          : effectiveEvent(widget.event!);
      widget.applyToSeries?.call(series);
      Navigator.pop(
        context,
        CalendarEvent(
          id: widget.event?.id ?? newId(),
          title: val('Title'),
          start: a,
          end: b,
          venue: val('Venue'),
          address: val('Address'),
          room: val('Room'),
          floor: val('Floor'),
          notes: val('Notes'),
          courseCode: widget.event?.courseCode ?? '',
          allDay: allDay,
          originStop: val('From transit stop'),
          destinationStop: val('To transit stop'),
          originWalkMinutes: int.parse(val('Walk to first stop')),
          destinationWalkMinutes: int.parse(val('Walk from last stop')),
          category: category,
          sessionType: sessionType,
          placeProfile: widget.event?.placeProfile ?? '',
          locationSource: val('Address').isEmpty
              ? ''
              : val('Address') == original?.address
              ? original!.locationSource
              : 'User',
          travelMinutes: int.parse(val('Travel minutes')),
          bufferMinutes: int.parse(val('Arrival buffer')),
        ),
      );
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  Widget field(String key, {bool number = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: TextFormField(
      controller: fields[key],
      decoration: InputDecoration(labelText: key),
      maxLength: number
          ? 4
          : key == 'Notes'
          ? 3000
          : 300,
      maxLines: key == 'Notes' ? 3 : 1,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      validator: (v) {
        if (key == 'Title' && (v ?? '').trim().isEmpty) {
          return 'Give this event a title';
        }
        if (number) {
          final n = int.tryParse(v ?? '');
          final maximum = key.startsWith('Walk') ? 180 : 1440;
          if (n == null || n < 0 || n > maximum) {
            return 'Use 0–$maximum minutes';
          }
        }
        return null;
      },
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.event == null ? 'Make a little plan' : 'Edit event'),
    ),
    body: SafeArea(
      child: centered(
        Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              eyebrow('EUROPE / PRAGUE'),
              field('Title'),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Calendar'),
                items: categories
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => category = v!),
              ),
              const SizedBox(height: 22),
              if (category == 'Study') ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: sessionType,
                  decoration: const InputDecoration(labelText: 'Class type'),
                  items: [
                    for (final type in sessionTypes)
                      DropdownMenuItem(
                        value: type,
                        child: Text(
                          type.isEmpty ? 'Not specified by source' : type,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => sessionType = value!,
                ),
                const SizedBox(height: 18),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('All-day event'),
                subtitle: allDay ? const Text('End date is exclusive.') : null,
                value: allDay,
                onChanged: (v) => setState(() {
                  allDay = v;
                  if (v && dayKey(endDay).compareTo(dayKey(day)) <= 0) {
                    endDay = DateTime(day.year, day.month, day.day + 1);
                  }
                }),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => date(false),
                      child: Text(DateFormat('d MMM yyyy').format(day)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (!allDay)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => time(false),
                        child: Text(
                          'Starts ${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}',
                        ),
                      ),
                    ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => date(true),
                      child: Text(DateFormat('d MMM yyyy').format(endDay)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (!allDay)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => time(true),
                        child: Text(
                          'Ends ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}',
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              field('Venue'),
              field('Address'),
              Row(
                children: [
                  Expanded(child: field('Room')),
                  const SizedBox(width: 12),
                  Expanded(child: field('Floor')),
                ],
              ),
              if (widget.applyToSeries != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: series,
                  onChanged: (value) => setState(() => series = value!),
                  title: const Text(
                    'Apply place and class type to this meeting series',
                  ),
                  subtitle: const Text(
                    'Updates imported occurrences of this exact meeting; lecture and practice stay separate.',
                  ),
                ),
              eyebrow('MANUAL TRAVEL ESTIMATE'),
              const Padding(
                padding: EdgeInsets.only(bottom: 15),
                child: Text(
                  'Optional fallback when transit stops are not mapped below. Manual estimates do not include live delays.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
              Row(
                children: [
                  Expanded(child: field('Travel minutes', number: true)),
                  const SizedBox(width: 12),
                  Expanded(child: field('Arrival buffer', number: true)),
                ],
              ),
              field('Notes'),
              const Text(
                'Routes use the address above and your starting point settings automatically. Stop overrides below are optional. Background refresh never reads GPS.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              field('From transit stop'),
              field('To transit stop'),
              Row(
                children: [
                  Expanded(child: field('Walk to first stop', number: true)),
                  const SizedBox(width: 12),
                  Expanded(child: field('Walk from last stop', number: true)),
                ],
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 15),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              FilledButton(onPressed: submit, child: const Text('Save event')),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    ),
  );
}

class ImportPage extends StatefulWidget {
  const ImportPage({super.key});
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final text = TextEditingController();
  String? error;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void review() async {
    try {
      final e = parseInvitation(text.text);
      final result = await Navigator.of(context).push<CalendarEvent>(
        MaterialPageRoute(
          builder: (_) => EventEditor(event: e, day: e.localStart),
        ),
      );
      if (result != null && mounted) {
        Navigator.pop(context, result);
      }
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Paste & review')),
    body: centered(
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          eyebrow('RECOGNITION STAYS ON THIS DEVICE'),
          const Text(
            'Paste one ICS event, or text with these labels:',
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 15),
          const SelectableText(
            'Title: Cinema\nDate: 2026-10-04\nStart: 18:30\nEnd: 20:30\nVenue: Kino\nAddress: Prague\nRoom: 2\nFloor: 1',
          ),
          const SizedBox(height: 20),
          TextField(
            controller: text,
            minLines: 8,
            maxLines: 16,
            maxLength: 200000,
            decoration: const InputDecoration(
              labelText: 'Invitation or ICS text',
              alignLabelWithHint: true,
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 15),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          FilledButton(onPressed: review, child: const Text('Review event')),
          const SizedBox(height: 15),
          const Text(
            'Nothing is saved until you review and confirm. Recurring, all-day and multiple-event ICS imports need the full importer.',
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

CalendarEvent parseInvitation(String text) {
  if (text.length > 200000) {
    throw const FormatException('Paste a smaller invitation.');
  }
  if (text.contains('BEGIN:VEVENT')) {
    final blocks = RegExp(r'BEGIN:VEVENT\s*([\s\S]*?)END:VEVENT')
        .allMatches(text.replaceAll(RegExp(r'\r?\n[ \t]'), ''));
    if (blocks.length != 1) {
      throw const FormatException(
        'This preview accepts exactly one ICS event.',
      );
    }
    final props = <String, (String, String)>{};
    for (final line in blocks.single.group(1)!.split(RegExp(r'\r?\n'))) {
      final p = line.indexOf(':');
      if (p > 0) {
        final key = line.substring(0, p);
        props[key.split(';').first.toUpperCase()] = (
          key,
          line.substring(p + 1),
        );
      }
    }
    if (props.containsKey('RRULE') ||
        props.containsKey('RDATE') ||
        props.containsKey('EXDATE') ||
        props.containsKey('RECURRENCE-ID') ||
        props['STATUS']?.$2.toUpperCase() == 'CANCELLED') {
      throw const FormatException(
        'Recurring or cancelled ICS events need the full importer.',
      );
    }
    DateTime stamp(String key) {
      final v = props[key];
      if (v == null) {
        throw FormatException('ICS is missing $key');
      }
      final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$')
          .firstMatch(v.$2);
      final zone = RegExp(r'(?:^|;)TZID=([^;]+)').firstMatch(v.$1)?.group(1);
      if (m == null || (zone != null && zone != 'Europe/Prague')) {
        throw const FormatException(
          'Use a timed event in UTC or Europe/Prague.',
        );
      }
      final n = List.generate(6, (i) => int.parse(m.group(i + 1)!));
      final check = DateTime.utc(n[0], n[1], n[2], n[3], n[4], n[5]);
      if (check.year != n[0] ||
          check.month != n[1] ||
          check.day != n[2] ||
          n[3] > 23 ||
          n[4] > 59 ||
          n[5] > 59) {
        throw const FormatException('ICS has an invalid date or time.');
      }
      if (m.group(7) == 'Z') {
        return check;
      }
      return wallTime(
        check,
        TimeOfDay(hour: n[3], minute: n[4]),
      ).add(Duration(seconds: n[5]));
    }

    String value(String key) => (props[key]?.$2 ?? '')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\,', ',')
        .replaceAll(r'\;', ';')
        .replaceAll(r'\\', '\\');
    final title = value('SUMMARY'),
        start = stamp('DTSTART'),
        end = stamp('DTEND');
    if (title.trim().isEmpty || !end.isAfter(start)) {
      throw const FormatException('Check the ICS title and times.');
    }
    return CalendarEvent(
      id: newId(),
      title: title,
      start: start,
      end: end,
      venue: value('LOCATION'),
      notes: value('DESCRIPTION'),
    );
  }
  final values = <String, String>{};
  for (final line in text.split('\n')) {
    final p = line.indexOf(':');
    if (p > 0) {
      values[line.substring(0, p).trim().toLowerCase()] = line
          .substring(p + 1)
          .trim();
    }
  }
  final date = values['date'], start = values['start'], end = values['end'];
  if (date == null ||
      start == null ||
      end == null ||
      (values['title'] ?? '').isEmpty ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
    throw const FormatException(
      'Add Title, Date (YYYY-MM-DD), Start and End (HH:MM).',
    );
  }
  final d = DateTime.tryParse(date);
  if (d == null || dayKey(d) != date) {
    throw const FormatException('Invalid date');
  }
  DateTime at(String value) {
    final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
    if (m == null || int.parse(m[1]!) > 23 || int.parse(m[2]!) > 59) {
      throw const FormatException('Use HH:MM for the time.');
    }
    return wallTime(
      d,
      TimeOfDay(hour: int.parse(m[1]!), minute: int.parse(m[2]!)),
    );
  }

  final a = at(start), b = at(end);
  if (!b.isAfter(a)) {
    throw const FormatException('End must be after start.');
  }
  return CalendarEvent(
    id: newId(),
    title: values['title']!,
    start: a,
    end: b,
    venue: values['venue'] ?? '',
    address: values['address'] ?? '',
    room: values['room'] ?? '',
    floor: values['floor'] ?? '',
    notes: values['notes'] ?? '',
  );
}
