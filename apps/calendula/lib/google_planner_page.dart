import 'package:flutter/material.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'editor.dart';
import 'google_routes.dart';
import 'journey_preferences.dart';
import 'main.dart';
import 'network_router.dart';

class GooglePlannerPage extends StatefulWidget {
  final DateTime? initialArrival;
  const GooglePlannerPage({super.key, this.initialArrival});
  @override
  State<GooglePlannerPage> createState() => _GooglePlannerPageState();
}

class _GooglePlannerPageState extends State<GooglePlannerPage> {
  final from = TextEditingController(text: 'Terminal 1, Prague Airport'),
      to = TextEditingController(text: 'Háje, Prague'),
      secret = TextEditingController();
  late DateTime target;
  Map<String, dynamic>? originPoint;
  bool arriveBy = true, busy = false, hasKey = false;
  String? message;
  List<NetworkJourney> journeys = [];
  @override
  void initState() {
    super.initState();
    target = widget.initialArrival ?? localNow().add(const Duration(hours: 1));
    load();
  }

  Future<void> load() async {
    final key = await GoogleRoutes.key();
    if (mounted) setState(() => hasKey = key?.isNotEmpty == true);
  }

  @override
  void dispose() {
    from.dispose();
    to.dispose();
    secret.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final key = secret.text.trim();
    if (!RegExp(r'^AIza[A-Za-z0-9_-]{20,100}$').hasMatch(key)) {
      setState(
        () =>
            message = 'Enter a Google Maps key. It stays in OS secure storage.',
      );
      return;
    }
    await GoogleRoutes.saveKey(key);
    secret.clear();
    if (mounted) {
      setState(() {
        hasKey = true;
        message = 'Key saved on this device.';
      });
    }
  }

  Future<void> gps() async {
    try {
      final p = await locationChannel.invokeMapMethod<String, dynamic>(
        'current',
      );
      if (p != null && mounted) {
        setState(() {
          originPoint = {
            'location': {
              'latLng': {
                'latitude': p['latitude'],
                'longitude': p['longitude'],
              },
            },
          };
          from.text = 'Current GPS point';
        });
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => message = e.message);
    }
  }

  Future<void> calculate() async {
    if (from.text.trim().isEmpty || to.text.trim().isEmpty) {
      setState(() => message = 'Enter an origin and destination.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
      journeys = [];
    });
    try {
      final r = await GoogleRoutes.route(
        originPoint ?? {'address': from.text.trim()},
        {'address': to.text.trim()},
        target,
        arriveBy: arriveBy,
      );
      if (mounted) {
        setState(() {
          journeys = r;
          message = r.isEmpty
              ? 'No route meeting this time was returned.'
              : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is PlatformException
              ? e.message
              : e is StateError
              ? e.message
              : 'Google route could not be read.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String clock(DateTime d) =>
      DateFormat('HH:mm').format(tz.TZDateTime.from(d, prague));
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Google Maps · optional')),
    body: centered(
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          eyebrow('EXTERNAL ROUTE COMPARISON'),
          title('A second opinion'),
          const SizedBox(height: 16),
          const Text(
            'Only origin, destination and time are sent through Tor. Google can link these requests to your API key/account. Event titles, notes and mail are never included.',
            style: TextStyle(color: muted, height: 1.5),
          ),
          const SizedBox(height: 20),
          if (!hasKey) ...[
            TextField(
              controller: secret,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Google Maps API key',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : save,
              child: const Text('Save key locally'),
            ),
            const SizedBox(height: 12),
            const Text(
              'A Maps Demo Key is for development/testing only and needs no billing account. The Google service pauses at its daily quota. This device also stops at 80 route attempts per day; that is a local budget, not a promised provider quota.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.5),
            ),
          ] else
            TextButton(
              onPressed: () async {
                await GoogleRoutes.saveKey('');
                if (mounted) setState(() => hasKey = false);
              },
              child: const Text('Remove saved key'),
            ),
          const SizedBox(height: 20),
          TextField(
            controller: from,
            maxLength: 300,
            onChanged: (_) => originPoint = null,
            decoration: const InputDecoration(
              labelText: 'From address or place',
            ),
          ),
          if (Platform.isAndroid)
            OutlinedButton.icon(
              onPressed: busy ? null : gps,
              icon: const Icon(Icons.my_location),
              label: const Text('Use current GPS point'),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: to,
            maxLength: 300,
            decoration: const InputDecoration(
              labelText: 'Destination address or place',
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Arrive by')),
              ButtonSegment(value: false, label: Text('Depart at')),
            ],
            selected: {arriveBy},
            onSelectionChanged: (v) => setState(() => arriveBy = v.first),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: target,
                      firstDate: DateTime(2026),
                      lastDate: DateTime(2035),
                    );
                    if (d != null && mounted) {
                      setState(
                        () => target = wallTime(
                          d,
                          TimeOfDay.fromDateTime(target),
                        ),
                      );
                    }
                  },
                  child: Text(DateFormat('d MMM yyyy').format(target)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(target),
                    );
                    if (t != null && mounted) {
                      setState(() => target = wallTime(target, t));
                    }
                  },
                  child: Text(clock(target)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: !hasKey || busy ? null : calculate,
            icon: const Icon(Icons.route),
            label: Text(
              busy ? 'Connecting through Tor…' : 'Request Google route',
            ),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(message!),
            ),
          for (final journey in journeys) ...[
            const SizedBox(height: 24),
            title('${clock(journey.departure)} → ${clock(journey.arrival)}'),
            Text(
              '${journey.arrival.difference(journey.departure).inMinutes} min · ${journey.changes} changes',
            ),
            for (final l in journey.legs)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: panel(
                  l.mode < 0 ? Icons.directions_walk : Icons.directions_transit,
                  '${l.mode < 0 ? 'Walk' : l.line} · ${clock(l.departure)}–${clock(l.arrival)}',
                  '${l.from} → ${l.to}${l.headsign.isEmpty ? '' : '\nTowards ${l.headsign}'}',
                ),
              ),
          ],
          const SizedBox(height: 24),
          const Text(
            'Google Maps',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Provider travel estimates; this API response does not expose a verified live-delay flag. No automatic account/key rotation. Local PID routing remains separate.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    ),
  );
}
