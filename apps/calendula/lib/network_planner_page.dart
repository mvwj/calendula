import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'editor.dart';
import 'main.dart';
import 'network_router.dart';
import 'transit.dart';
import 'google_planner_page.dart';
import 'journey_preferences.dart';
import 'address_index.dart';
import 'place_search.dart';
import 'place_field.dart';
import 'journey_endpoint.dart';
import 'planner_runtime.dart';

import 'package:flutter/services.dart';

import 'dart:io';

class NetworkPlannerPage extends StatefulWidget {
  final DateTime? initialArrival;
  final LiveFeed? Function() live;
  final String initialFrom, initialTo;
  final bool requireEndpoints;
  final Future<bool> Function(String, String, int, int)? saveStops;
  final NetworkEngine? engine;
  final AddressIndex? addresses;
  final int initialOriginWalk, initialDestinationWalk;
  final DateTime Function()? now;
  const NetworkPlannerPage({
    super.key,
    this.initialArrival,
    required this.live,
    this.initialFrom = '',
    this.initialTo = '',
    this.requireEndpoints = false,
    this.saveStops,
    this.engine,
    this.addresses,
    this.initialOriginWalk = 0,
    this.initialDestinationWalk = 0,
    this.now,
  });
  @override
  State<NetworkPlannerPage> createState() => _NetworkPlannerPageState();
}

class _NetworkPlannerPageState extends State<NetworkPlannerPage> {
  NetworkEngine? _engine;
  NetworkEngine get engine => _engine!;
  PlannerLease? lease;
  final from = TextEditingController(), to = TextEditingController();
  StopSearch stops = StopSearch([]);
  AddressIndex? addresses;
  JourneyPreferences preferences = const JourneyPreferences();
  (double, double)? currentPoint;
  JourneyEndpoint? chosenFrom, chosenTo;
  int calculation = 0;
  late DateTime target;
  bool loading = true, searching = false, arriveBy = true;
  NetworkJourney? journey;
  String? error;
  Timer? timer;
  DateTime? lastPrediction;
  DateTime currentTime() => widget.now?.call() ?? localNow();
  @override
  void initState() {
    super.initState();
    target = widget.initialArrival ?? localNow().add(const Duration(hours: 1));
    if (widget.initialFrom.isNotEmpty) from.text = widget.initialFrom;
    if (widget.initialTo.isNotEmpty) to.text = widget.initialTo;
    if (widget.requireEndpoints) {
      from.text = widget.initialFrom;
      to.text = widget.initialTo;
    }
    load();
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      final feed = widget.live();
      final freshStamp = feed?.fresh(DateTime.now()) == true
          ? feed?.generated
          : null;
      if (mounted &&
          journey != null &&
          !searching &&
          lastPrediction != freshStamp) {
        calculate();
      }
    });
  }

  Future<void> load() async {
    try {
      final addressLoading = widget.addresses != null
          ? Future<AddressIndex?>.value(widget.addresses)
          : AddressIndex.load()
                .then<AddressIndex?>((value) => value)
                .catchError((Object _) => null);
      if (widget.engine != null) {
        _engine = widget.engine;
        await engine.load(null);
      } else {
        final loaded = await PlannerRuntime.shared.acquire(
          await plannerCachePath(),
        );
        if (!mounted) {
          loaded.release();
          return;
        }
        lease = loaded;
        _engine = loaded.engine;
      }
      stops = StopSearch(engine.stations);
      try {
        addresses = await addressLoading;
      } catch (_) {}
      preferences = await const JourneyPreferenceStore().load();
      if (widget.initialFrom.isEmpty) {
        from.text = preferences.address;
        if (preferences.mode == OriginMode.current && !Platform.isAndroid) {
          from.text = preferences.home;
        }
      }
      if (mounted) {
        setState(() => loading = false);
        if (widget.initialFrom.isEmpty &&
            preferences.mode == OriginMode.current &&
            Platform.isAndroid) {
          await useLocation();
        } else if (widget.requireEndpoints) {
          await calculate();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'Network timetable could not be loaded. Update the timetable and reopen this planner.';
        });
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    lease?.release();
    from.dispose();
    to.dispose();
    fromFocus.dispose();
    toFocus.dispose();
    super.dispose();
  }

  Future<void> calculate() async {
    if (loading || _engine == null) return;
    if (arriveBy && !target.isAfter(currentTime())) {
      setState(() {
        calculation++;
        searching = false;
        journey = null;
        error = 'This arrival time has passed. Choose a future time or use Depart now.';
      });
      return;
    }
    final origins = currentPoint == null
        ? resolveEndpoint(engine, stops, addresses, from.text)
        : nearbyEndpoints(
            engine,
            currentPoint!.$1,
            currentPoint!.$2,
            'Current location',
          );
    final destinations = resolveEndpoint(engine, stops, addresses, to.text);
    if (from.text == widget.initialFrom &&
        widget.initialOriginWalk > 0 &&
        currentPoint == null) {
      for (var i = 0; i < origins.length; i++) {
        if (origins[i].walkMinutes == 0) {
          origins[i] = JourneyEndpoint(
            origins[i].stop,
            'Walk to ${origins[i].stop}',
            widget.initialOriginWalk,
          );
        }
      }
    }
    if (to.text == widget.initialTo && widget.initialDestinationWalk > 0) {
      for (var i = 0; i < destinations.length; i++) {
        if (destinations[i].walkMinutes == 0) {
          destinations[i] = JourneyEndpoint(
            destinations[i].stop,
            'Walk from ${destinations[i].stop}',
            widget.initialDestinationWalk,
          );
        }
      }
    }
    if (origins.isEmpty || destinations.isEmpty) {
      setState(
        () => error = origins.isEmpty
            ? 'Set home, use GPS or choose a departure from the suggestions.'
            : 'Destination is filled from the event. Choose its exact Prague address or nearby stop if it is not recognised.',
      );
      return;
    }
    final request = ++calculation;
    setState(() {
      searching = true;
      error = null;
      journey = null;
    });
    try {
      final result = await findEndpointJourney(
        engine,
        origins,
        destinations,
        target,
        arriveBy: arriveBy,
        live: widget.live(),
        now: currentTime(),
        cancelled: () => !mounted || request != calculation,
      );
      final j = preferDirectWalk(
        result?.journey,
        directWalkJourney(
          engine,
          addresses,
          from.text,
          to.text,
          target,
          arriveBy: arriveBy,
          now: currentTime(),
          currentPoint: currentPoint,
        ),
        arriveBy: arriveBy,
      );
      final feed = widget.live();
      lastPrediction = feed?.fresh(DateTime.now()) == true
          ? feed?.generated
          : null;
      if (mounted && request == calculation) {
        setState(() {
          journey = j;
          chosenFrom = result?.from;
          chosenTo = result?.to;
          error = j == null
              ? 'No connection in the supported transfer graph. Try another stop or time.'
              : null;
        });
      }
    } catch (e) {
      if (mounted && request == calculation) {
        setState(
          () => error = e is StateError
              ? e.message
              : 'The journey could not be calculated.',
        );
      }
    } finally {
      if (mounted && request == calculation) setState(() => searching = false);
    }
  }

  void example(String origin, String destination) {
    final now = localNow();
    var day = target;
    var departure = wallTime(day, const TimeOfDay(hour: 8, minute: 0));
    if (departure.isBefore(now)) {
      day = DateTime(now.year, now.month, now.day + 1);
      departure = wallTime(day, const TimeOfDay(hour: 8, minute: 0));
    }
    FocusScope.of(context).unfocus();
    setState(() {
      from.text = origin;
      to.text = destination;
      target = departure;
      arriveBy = false;
      currentPoint = null;
    });
    calculate();
  }

  Future<void> useLocation() async {
    try {
      final point = await locationChannel.invokeMapMethod<String, dynamic>(
        'current',
      );
      if (point == null || !mounted) return;
      final lat = (point['latitude'] as num).toDouble(),
          lon = (point['longitude'] as num).toDouble();
      final nearby = nearbyEndpoints(engine, lat, lon, 'Current location');
      if (nearby.isEmpty) {
        setState(
          () => error =
              'No nearby PID stop found within 1.5 km. Choose a stop manually.',
        );
        return;
      }
      setState(() {
        currentPoint = (lat, lon);
        from.text = 'Current location';
        journey = null;
      });
      await const JourneyPreferenceStore().rememberLocation(
        OriginFix(
          lat,
          lon,
          (point['accuracy'] as num?)?.toDouble() ?? 1000,
          currentTime(),
        ),
      );
      if (to.text.isNotEmpty) await calculate();
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Location unavailable.');
    }
  }

  Widget stopField(String label, TextEditingController controller) =>
      PlaceField(
        label: label,
        controller: controller,
        focus: controller == from ? fromFocus : toFocus,
        stops: stops,
        addresses: addresses,
        onChanged: () => setState(() {
          calculation++;
          searching = false;
          journey = null;
          error = null;
          if (controller == from) currentPoint = null;
        }),
        onSelected: () {
          if (controller == from) currentPoint = null;
          FocusScope.of(context).unfocus();
          if (from.text.isNotEmpty && to.text.isNotEmpty) calculate();
        },
      );
  Future<void> startingPoint({bool home = false}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => JourneySettingsPage(
          startHome: home,
          stops: stops,
          addresses: addresses,
        ),
      ),
    );
    if (!mounted) return;
    preferences = await const JourneyPreferenceStore().load();
    if (!mounted) return;
    setState(() {
      currentPoint = null;
      from.text = preferences.address;
      if (preferences.mode == OriginMode.current && !Platform.isAndroid) {
        from.text = preferences.home;
      }
      journey = null;
    });
    if (preferences.mode == OriginMode.current && Platform.isAndroid) {
      await useLocation();
    } else if (from.text.isNotEmpty && to.text.isNotEmpty) {
      await calculate();
    }
  }

  final fromFocus = FocusNode(), toFocus = FocusNode();
  String clock(DateTime d) =>
      DateFormat('HH:mm').format(tz.TZDateTime.from(d, prague));
  String mode(JourneyLeg l) => switch (l.mode) {
    -1 => 'Walk',
    0 => 'Tram',
    1 => 'Metro',
    2 => 'Train',
    3 => 'Bus',
    4 => 'Ferry',
    6 => 'Cable car',
    7 => 'Funicular',
    11 => 'Trolleybus',
    _ => 'Transit',
  };
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Route with connections')),
    body: centered(
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          eyebrow('ALL PID MODES · ON YOUR DEVICE'),
          title('The whole connection'),
          const SizedBox(height: 12),
          const Text(
            'Prague addresses and stops are found on this device. Connections include available delay predictions and estimated walks to nearby stops.',
            style: TextStyle(color: muted, height: 1.5),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GooglePlannerPage(initialArrival: target),
              ),
            ),
            child: const Text('Compare with Google Maps (optional)'),
          ),
          if (loading)
            const LinearProgressIndicator()
          else ...[
            stopField('From', from),
            if (!Platform.isAndroid &&
                preferences.mode == OriginMode.current &&
                preferences.home.isNotEmpty)
              const Text(
                'Using saved home. GPS is available on Android.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.home_outlined),
                  label: const Text('Set home'),
                  onPressed: searching ? null : () => startingPoint(home: true),
                ),
                if (preferences.home.isNotEmpty)
                  ActionChip(
                    label: const Text('Use home'),
                    onPressed: searching
                        ? null
                        : () {
                            setState(() {
                              currentPoint = null;
                              from.text = preferences.home;
                            });
                            if (to.text.isNotEmpty) calculate();
                          },
                  ),
                ActionChip(
                  label: const Text('Starting point settings'),
                  onPressed: searching ? null : startingPoint,
                ),
              ],
            ),
            if (Platform.isAndroid)
              TextButton.icon(
                onPressed: useLocation,
                icon: const Icon(Icons.my_location),
                label: const Text('Use current location'),
              ),
            const SizedBox(height: 16),
            stopField('To', to),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Arrive by')),
                ButtonSegment(value: false, label: Text('Depart at')),
              ],
              selected: {arriveBy},
              onSelectionChanged: (v) => setState(() {
                calculation++;
                searching = false;
                arriveBy = v.first;
                journey = null;
              }),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: searching
                  ? null
                  : () {
                      setState(() {
                        arriveBy = false;
                        target = currentTime();
                        journey = null;
                      });
                      calculate();
                    },
              icon: const Icon(Icons.schedule),
              label: const Text('Depart now'),
            ),
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
                        setState(() {
                          calculation++;
                          searching = false;
                          target = wallTime(d, TimeOfDay.fromDateTime(target));
                          journey = null;
                        });
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
                        setState(() {
                          calculation++;
                          searching = false;
                          target = wallTime(target, t);
                          journey = null;
                        });
                      }
                    },
                    child: Text(
                      '${arriveBy ? 'Arrive' : 'Depart'} ${clock(target)}',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: searching || (_engine?.stations.isEmpty ?? true)
                  ? null
                  : calculate,
              icon: const Icon(Icons.route),
              label: Text(
                searching ? 'Finding connections…' : 'Calculate on this device',
              ),
            ),
            const SizedBox(height: 16),
            const Text('Try a public route', style: TextStyle(color: muted)),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: const Text('Airport to Háje'),
                  onPressed: searching
                      ? null
                      : () => example('Terminál 1', 'Háje'),
                ),
                ActionChip(
                  label: const Text('Barrandov to Černý Most'),
                  onPressed: searching
                      ? null
                      : () => example('Sídliště Barrandov', 'Černý Most'),
                ),
                ActionChip(
                  label: const Text('Zoo to Motol'),
                  onPressed: searching
                      ? null
                      : () => example('Zoo Praha - Troja', 'Nemocnice Motol'),
                ),
              ],
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(
                error!,
                style: const TextStyle(color: Color(0xFFA13C31)),
              ),
            ),
          if (journey != null) ...[
            if (widget.saveStops != null &&
                journey!.legs.any((l) => l.mode >= 0)) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: searching
                    ? null
                    : () async {
                        setState(() => searching = true);
                        final saved = await widget.saveStops!(
                          chosenFrom!.stop,
                          chosenTo!.stop,
                          chosenFrom!.walkMinutes,
                          chosenTo!.walkMinutes,
                        );
                        if (mounted) {
                          setState(() => searching = false);
                          if (saved) {
                            Navigator.pop(this.context);
                          } else {
                            setState(
                              () => error = 'These stops could not be saved. The event may have changed.',
                            );
                          }
                        }
                      },
                icon: const Icon(Icons.event_available),
                label: const Text('Use these stops for this event'),
              ),
              const Text(
                'The departure card will replan for the event’s own time.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: forest,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${clock(journey!.departure)} → ${clock(journey!.arrival)}',
                    style: const TextStyle(color: Colors.white, fontSize: 25),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${journey!.arrival.difference(journey!.departure).inMinutes} min · ${journey!.changes} ${journey!.changes == 1 ? 'change' : 'changes'}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (journey!.estimatedWalking)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Contains estimated transfer walks. Street paths and barriers have not been verified.',
                        style: TextStyle(
                          color: Color(0xFFFFD8AC),
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            for (final leg in journey!.legs)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: panel(
                  leg.mode < 0
                      ? Icons.directions_walk
                      : Icons.directions_transit,
                  '${mode(leg)} ${leg.line} · ${clock(leg.departure)}–${clock(leg.arrival)}',
                  '${leg.from} → ${leg.to}${leg.headsign.isEmpty ? '' : '\nTowards ${leg.headsign}'}\n${leg.mode < 0
                      ? leg.estimated
                            ? 'Estimated transfer time'
                            : 'Published transfer time'
                      : leg.predicted
                      ? 'Updated prediction'
                      : 'Scheduled · live prediction unavailable'}${leg.requestStop ? '\nRequest stop · signal the driver' : ''}',
                ),
              ),
          ],
          const SizedBox(height: 24),
          Text(
            'Timetable ${_engine?.start ?? 'loading'} — ${_engine?.end ?? ''}\nPID / ROPID · CC BY 4.0\nUp to 5 changes. Timed vehicle holds and stay-seated connections are not assumed. Full route quality is still being checked.',
            style: const TextStyle(color: muted, fontSize: 12, height: 1.5),
          ),
          if (addresses != null)
            Text(
              'Address points: ČÚZK / RÚIAN · ${addresses!.date} · CC BY 4.0',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
        ],
      ),
    ),
  );
}
