import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'calendar.dart';
import 'main.dart';
import 'address_index.dart';
import 'place_search.dart';
import 'place_field.dart';
import 'network_router.dart';

enum OriginMode { current, home, other }

class JourneyPreferences {
  final OriginMode mode;
  final String home, other;
  const JourneyPreferences({
    this.mode = OriginMode.current,
    this.home = '',
    this.other = '',
  });
  String get label => switch (mode) {
    OriginMode.current => 'Current location (GPS)',
    OriginMode.home => 'Home address',
    OriginMode.other => 'Other address',
  };
  String get address => mode == OriginMode.home
      ? home
      : mode == OriginMode.other
      ? other
      : '';
  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'home': home,
    'other': other,
  };
  static JourneyPreferences fromJson(Map<String, dynamic> json) =>
      JourneyPreferences(
        mode: OriginMode.values.firstWhere(
          (v) => v.name == json['mode'],
          orElse: () => OriginMode.current,
        ),
        home: json['home'] ?? '',
        other: json['other'] ?? '',
      );
}

class JourneyPreferenceStore {
  final FlutterSecureStorage storage;
  const JourneyPreferenceStore({this.storage = const FlutterSecureStorage()});
  Future<JourneyPreferences> load() async {
    final raw = await storage.read(key: 'calendula.journey.preferences.v1');
    return raw == null
        ? const JourneyPreferences()
        : JourneyPreferences.fromJson(jsonDecode(raw));
  }

  Future<void> save(JourneyPreferences preferences) => storage.write(
    key: 'calendula.journey.preferences.v1',
    value: jsonEncode(preferences.toJson()),
  );

  Future<OriginFix?> lastLocation() async {
    final raw = await storage.read(key: 'calendula.journey.location.v1');
    if (raw == null) return null;
    return OriginFix.fromJson(jsonDecode(raw));
  }

  Future<void> rememberLocation(OriginFix fix) => storage.write(
    key: 'calendula.journey.location.v1',
    value: jsonEncode(fix.toJson()),
  );
}

/// One encrypted, device-local fix, never synced as an account setting/history.
class OriginFix {
  final double latitude, longitude, accuracy;
  final DateTime at;
  const OriginFix(this.latitude, this.longitude, this.accuracy, this.at);
  bool usableAt(DateTime now) =>
      accuracy <= 1000 &&
      !at.isAfter(now.add(const Duration(seconds: 30))) &&
      now.difference(at) <= const Duration(hours: 12);
  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'at': at.toUtc().toIso8601String(),
  };
  factory OriginFix.fromJson(Map<String, dynamic> json) {
    final fix = OriginFix(
      (json['latitude'] as num).toDouble(),
      (json['longitude'] as num).toDouble(),
      (json['accuracy'] as num).toDouble(),
      DateTime.parse(json['at']),
    );
    if (!fix.latitude.isFinite ||
        !fix.longitude.isFinite ||
        !fix.accuracy.isFinite ||
        fix.latitude.abs() > 90 ||
        fix.longitude.abs() > 180 ||
        fix.accuracy < 0) {
      throw const FormatException('Invalid location');
    }
    return fix;
  }
}

const locationChannel = MethodChannel('app.calendula/location');

class JourneySettingsPage extends StatefulWidget {
  final JourneyPreferenceStore store;
  final bool startHome;
  final StopSearch? stops;
  final AddressIndex? addresses;
  const JourneySettingsPage({
    super.key,
    this.store = const JourneyPreferenceStore(),
    this.startHome = false,
    this.stops,
    this.addresses,
  });
  @override
  State<JourneySettingsPage> createState() => _JourneySettingsPageState();
}

class _JourneySettingsPageState extends State<JourneySettingsPage> {
  final home = TextEditingController(), other = TextEditingController();
  final homeFocus = FocusNode(), otherFocus = FocusNode();
  StopSearch stops = StopSearch([]);
  AddressIndex? addresses;
  OriginMode mode = OriginMode.current;
  String? error;
  bool loading = true, saving = false;
  @override
  void initState() {
    super.initState();
    load();
    loadSearch();
  }

  Future<void> loadSearch() async {
    NetworkEngine? searchEngine;
    try {
      final addressData = widget.addresses ?? await AddressIndex.load();
      final StopSearch names;
      final suppliedNames = widget.stops;
      if (suppliedNames != null) {
        names = suppliedNames;
      } else {
        searchEngine = NetworkEngine();
        await searchEngine.load(null);
        names = StopSearch(searchEngine.stations);
      }
      if (mounted) {
        setState(() {
          addresses = addressData;
          stops = names;
        });
      }
    } catch (_) {
      /* Typed addresses can still be saved while local search loads. */
    } finally {
      searchEngine?.dispose();
    }
  }

  Future<void> load() async {
    try {
      final value = await widget.store.load();
      if (mounted) {
        setState(() {
          mode = widget.startHome ? OriginMode.home : value.mode;
          home.text = value.home;
          other.text = value.other;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'Could not read your journey settings.';
        });
      }
    }
  }

  @override
  void dispose() {
    home.dispose();
    other.dispose();
    homeFocus.dispose();
    otherFocus.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (mode != OriginMode.current &&
        (mode == OriginMode.home ? home : other).text.trim().isEmpty) {
      setState(() => error = 'Enter an address or choose current location.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.store.save(
        JourneyPreferences(
          mode: mode,
          home: home.text.trim(),
          other: other.text.trim(),
        ),
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = 'Could not save settings. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Journey starting point')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : centered(
            ListView(
              padding: const EdgeInsets.all(24),
              children: [
                eyebrow('START WHERE IT SUITS YOU'),
                title('Your way out.'),
                const SizedBox(height: 16),
                const Text(
                  'Save home once, then use it for event routes. Choose a Prague address or stop from the suggestions.',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 24),
                DropdownButtonFormField<OriginMode>(
                  initialValue: mode,
                  decoration: const InputDecoration(labelText: 'Start from'),
                  isExpanded: true,
                  items: [
                    for (final v in OriginMode.values)
                      DropdownMenuItem(
                        value: v,
                        child: Text(JourneyPreferences(mode: v).label),
                      ),
                  ],
                  onChanged: (v) => setState(() => mode = v!),
                ),
                const SizedBox(height: 20),
                PlaceField(
                  label: 'Home address',
                  controller: home,
                  focus: homeFocus,
                  stops: stops,
                  addresses: addresses,
                ),
                const SizedBox(height: 16),
                PlaceField(
                  label: 'Other address',
                  controller: other,
                  focus: otherFocus,
                  stops: stops,
                  addresses: addresses,
                ),
                const SizedBox(height: 16),
                const Text(
                  'GPS is read on opening/resuming the app. Background plans use the last fix for up to 12 hours, labelled with its time. Save home for plans that work without GPS. No background location tracking. Walks are estimates.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Color(0xFFA13C31)),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: saving ? null : save,
                  child: Text(saving ? 'Saving…' : 'Save starting point'),
                ),
              ],
            ),
          ),
  );
}

class EventJourneyPage extends StatefulWidget {
  final CalendarEvent event;
  final Widget Function() planner;
  const EventJourneyPage({
    super.key,
    required this.event,
    required this.planner,
  });
  @override
  State<EventJourneyPage> createState() => _EventJourneyPageState();
}

class _EventJourneyPageState extends State<EventJourneyPage> {
  JourneyPreferences preferences = const JourneyPreferences();
  String? error, position;
  bool locating = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await const JourneyPreferenceStore().load();
      if (mounted) {
        setState(() => preferences = value);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Starting point settings could not be loaded.');
      }
    }
  }

  Future<void> locate() async {
    setState(() {
      locating = true;
      error = null;
    });
    try {
      if (!Platform.isAndroid) {
        throw PlatformException(
          code: 'PLATFORM',
          message: 'GPS is currently available in the Android build.',
        );
      }
      final point = await locationChannel.invokeMapMethod<String, dynamic>(
        'current',
      );
      if (mounted && point != null) {
        setState(
          () => position =
              '${(point['latitude'] as num).toStringAsFixed(5)}, ${(point['longitude'] as num).toStringAsFixed(5)} · ±${(point['accuracy'] as num).round()} m',
        );
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => error = e.message ?? 'Location is unavailable.');
      }
    } finally {
      if (mounted) {
        setState(() => locating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    return Scaffold(
      appBar: AppBar(title: const Text('Transport for event')),
      body: centered(
        ListView(
          padding: const EdgeInsets.all(24),
          children: [
            eyebrow('A WAY TO GET THERE'),
            title(e.title),
            const SizedBox(height: 20),
            detail(
              Icons.flag_outlined,
              'Starts ${clock(e.localStart)} · arrive by ${clock(e.localStart.subtract(Duration(minutes: e.bufferMinutes)))} · ${e.bufferMinutes} min buffer',
            ),
            detail(Icons.trip_origin, preferences.label),
            if (preferences.address.isNotEmpty)
              detail(Icons.home_outlined, preferences.address),
            if (position != null) detail(Icons.my_location, position!),
            if (preferences.mode == OriginMode.current)
              OutlinedButton.icon(
                onPressed: locating ? null : locate,
                icon: const Icon(Icons.my_location),
                label: Text(
                  locating ? 'Getting location…' : 'Read current location',
                ),
              ),
            OutlinedButton(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const JourneySettingsPage(),
                  ),
                );
                await load();
              },
              child: const Text('Change starting point'),
            ),
            const SizedBox(height: 16),
            detail(
              Icons.place_outlined,
              e.address.isNotEmpty
                  ? e.address
                  : e.venue.isNotEmpty
                  ? e.venue
                  : 'Destination address has not been added.',
            ),
            if (e.room.isNotEmpty)
              detail(Icons.meeting_room_outlined, 'Room ${e.room}'),
            if (e.travelMinutes > 0)
              detail(
                Icons.schedule,
                'Leave ${clock(e.leaveAt)} · ${e.travelMinutes} min manual estimate',
              ),
            const SizedBox(height: 20),
            panel(
              Icons.route_outlined,
              'Route status',
              'The station planner currently supports direct metro journeys. Full event routes with walking, buses, trams and connections are coming next.',
              action: FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Direct metro preview')),
                      body: widget.planner(),
                    ),
                  ),
                ),
                child: const Text('Open station planner'),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  error!,
                  style: const TextStyle(color: Color(0xFFA13C31)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
