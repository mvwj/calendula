import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'transit.dart';
import 'editor.dart';
import 'csv_import_page.dart';
import 'schedule_csv.dart';
import 'journey_preferences.dart';
import 'refresh_policy.dart';
import 'timetable_store.dart';
import 'network_settings_page.dart';
import 'network_planner_page.dart';
import 'mail.dart';
import 'mail_page.dart';
import 'import_review_page.dart';
import 'sync.dart';
import 'sync_page.dart';
import 'widget_snapshot.dart';
import 'widget_background.dart';
import 'network_router.dart';
import 'desktop.dart';
import 'desktop_check.dart';
import 'sync_device_check.dart';
import 'sync_cloud_check.dart';
import 'shared_import.dart';
import 'mail_transport_check.dart';
import 'mail_read_check.dart';
import 'journey_check.dart';
import 'planner_runtime.dart';
import 'event_place.dart';
import 'event_journey.dart';
import 'day_timeline.dart';

const ink = Color(0xFF253D36),
    forest = Color(0xFF324F42),
    paper = Color(0xFFF7F7F2),
    muted = Color(0xFF748177),
    orange = Color(0xFFEDAA65);
const categories = ['Study', 'Work', 'Culture', 'Personal'];
Color categoryColor(String v) => switch (v) {
  'Study' => const Color(0xFFE9EFDC),
  'Work' => const Color(0xFFE5ECF0),
  'Culture' => const Color(0xFFF9E8D8),
  _ => const Color(0xFFEFE7F1),
};
const widgetChannel = MethodChannel('app.calendula/widget');
@pragma('vm:entry-point')
Future<void> refreshDayWidget() => widgetBackground();
@pragma('vm:entry-point')
Future<void> synchronizeCalendar() => syncBackground();
@pragma('vm:entry-point')
Future<void> verifySyncDevice() => androidSyncDeviceCheck();
@pragma('vm:entry-point')
Future<void> verifyCloudSync() => androidCloudSyncCheck();
@pragma('vm:entry-point')
Future<void> verifyMailTransport() => androidMailTransportCheck();
@pragma('vm:entry-point')
Future<void> verifyMailboxRead() => androidMailboxReadCheck();
@pragma('vm:entry-point')
Future<void> verifyJourneySpeed() => androidJourneyCheck();
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  if (Platform.isWindows && args.contains('--journey-check')) {
    await journeyCheck();
    return;
  }
  if (Platform.isWindows && args.contains('--mail-transport-check')) {
    await windowsMailTransportCheck(args);
    return;
  }
  if (Platform.isWindows && args.contains('--cloud-sync-check')) {
    await windowsCloudSyncCheck(args);
    return;
  }
  if (Platform.isWindows && args.contains('--sync-device-check')) {
    await windowsSyncDeviceCheck(args);
    return;
  }
  if (Platform.isWindows && args.contains('--self-check')) {
    await desktopCheck();
    return;
  }
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Tor, tor-android and native dependencies',
    ], await rootBundle.loadString('assets/licenses/tor.txt'));
  });
  if (Platform.isWindows) {
    await desktopController.initialize(
      widget: args.contains('--widget'),
      autostart: args.contains('--autostart'),
    );
  }
  if (Platform.isWindows && desktopWidgetMode) {
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: forest, surface: paper),
          scaffoldBackgroundColor: paper,
          textTheme: ThemeData.light().textTheme.apply(
            bodyColor: ink,
            displayColor: ink,
          ),
        ),
        home: DesktopAgenda(
          repository: SyncRepository(legacy: EncryptedEventRepository()),
        ),
      ),
    );
    return;
  }
  runApp(
    CalendulaApp(
      repository: SyncRepository(legacy: EncryptedEventRepository()),
    ),
  );
}

class CalendulaApp extends StatelessWidget {
  final EventRepository repository;
  final bool fetchLive;
  final Future<MetroIndex> Function()? loadTimetable;
  const CalendulaApp({
    super.key,
    required this.repository,
    this.fetchLive = true,
    this.loadTimetable,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Calendula',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: forest, surface: paper),
      scaffoldBackgroundColor: paper,
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: ink,
        displayColor: ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.all(16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: forest,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    ),
    home: CalendarHome(
      repository: repository,
      fetchLive: fetchLive,
      loadTimetable: loadTimetable,
    ),
  );
}

class CalendarHome extends StatefulWidget {
  final EventRepository repository;
  final bool fetchLive;
  final Future<MetroIndex> Function()? loadTimetable;
  const CalendarHome({
    super.key,
    required this.repository,
    required this.fetchLive,
    this.loadTimetable,
  });
  @override
  State<CalendarHome> createState() => _CalendarHomeState();
}

class _CalendarHomeState extends State<CalendarHome>
    with WidgetsBindingObserver {
  List<CalendarEvent> events = [];
  DateTime selected = localNow();
  bool loading = true, saving = false, samples = false, refreshing = false;
  String? vaultError, liveError;
  LiveFeed? live;
  MetroIndex? metro;
  int page = 0, view = 0;
  DateTime? lastFetch;
  final refreshPolicy = RefreshPolicy();
  final timetableStore = TimetableStore();
  final transitVersion = ValueNotifier<int>(0);
  bool timetableUpdating = false;
  String? timetableStatus;
  Timer? timer;
  bool appVisible = true;
  final mail = MailController();
  static const shareChannel = MethodChannel('app.calendula/share');
  bool reviewingShare = false;
  final sharedQueue = <Map<dynamic, dynamic>>[];
  Future<void> takeShared() async {
    if (!Platform.isAndroid || !mounted) return;
    final pending =
        await shareChannel.invokeListMethod<dynamic>('takePending') ?? [];
    sharedQueue.addAll(pending.map((v) => Map<dynamic, dynamic>.from(v)));
    await reviewShared();
  }

  Future<void> reviewShared() async {
    if (!mounted || loading || saving || reviewingShare || vaultError != null) {
      return;
    }
    reviewingShare = true;
    try {
      while (sharedQueue.isNotEmpty && mounted) {
        final payload = sharedQueue.removeAt(0);
        try {
          final from = localNow(),
              through = localNow().add(const Duration(days: 90));
          final batch = await sharedInvitation(payload, from, through);
          if (!mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ImportReviewPage(
                existing: events,
                commit: commitImport,
                heading: 'Review shared invitation',
                initial: batch,
              ),
            ),
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  e is FormatException ? e.message : 'The shared invitation could not be read. Your calendar was kept.',
                ),
              ),
            );
          }
        }
      }
    } finally {
      reviewingShare = false;
    }
  }

  SyncRepository? get syncRepository => widget.repository is SyncRepository
      ? widget.repository as SyncRepository
      : null;
  Timer? syncTimer;
  bool remoteLoading = false;
  bool widgetUpdating = false;
  bool widgetQueued = false;
  bool get canRefresh =>
      appVisible || (Platform.isWindows && desktopController.tray);
  Map<String, NetworkJourney> eventJourneys = {};
  Map<String, EventJourneyPlan> eventPlans = {};
  DateTime? plansChecked;
  DateTime? planPredictionStamp;
  bool locatingOrigin = false;
  Future<void> readOrigin() async {
    if (!widget.fetchLive ||
        !Platform.isAndroid ||
        !appVisible ||
        locatingOrigin) {
      return;
    }
    locatingOrigin = true;
    try {
      final store = const JourneyPreferenceStore();
      if ((await store.load()).mode != OriginMode.current) return;
      final point = await locationChannel.invokeMapMethod<String, dynamic>(
        'current',
      );
      if (point == null) return;
      await store.rememberLocation(
        OriginFix(
          (point['latitude'] as num).toDouble(),
          (point['longitude'] as num).toDouble(),
          (point['accuracy'] as num).toDouble(),
          DateTime.now(),
        ),
      );
      if (mounted) updateWidget();
    } catch (_) {
      // Existing saved home/fix remains intact; missing GPS has an explicit row.
    } finally {
      locatingOrigin = false;
    }
  }

  void syncChanged() async {
    if (remoteLoading || !mounted || loading || saving) return;
    remoteLoading = true;
    try {
      final next = await syncRepository!.load();
      if (mounted) {
        setState(() {
          events = next;
          eventJourneys.clear();
          eventPlans.clear();
        });
        updateWidget();
      }
    } finally {
      remoteLoading = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      shareChannel.setMethodCallHandler((call) async {
        if (call.method == 'pending') await takeShared();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => takeShared());
    }
    load();
    syncRepository?.addListener(syncChanged);
    if (widget.fetchLive) {
      unawaited(warmNetworkPlanner());
      unawaited(readOrigin());
      mail.load().then((_) => mail.refresh(automatic: true));
      syncTimer = Timer.periodic(const Duration(minutes: 2), (_) {
        if (canRefresh) syncRepository?.synchronize();
      });
    }
    (widget.loadTimetable ?? timetableStore.load)()
        .then((v) {
          if (mounted) {
            setState(() => metro = v);
            transitVersion.value++;
            if (widget.fetchLive) {
              updateTimetable(automatic: true);
            }
          }
        })
        .catchError((Object _) {
          if (mounted) {
            setState(() => liveError = 'Local timetable could not be loaded.');
            transitVersion.value++;
          }
        });
    if (widget.fetchLive) {
      refresh(automatic: true);
    }
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {});
        transitVersion.value++;
        if (canRefresh &&
            (plansChecked == null ||
                localNow().difference(plansChecked!) >=
                    (appVisible
                        ? const Duration(minutes: 2)
                        : planRefreshInterval(events, localNow())) ||
                (live?.fresh(localNow()) == true ? live?.generated : null) !=
                    planPredictionStamp)) {
          updateWidget();
        }
        if (widget.fetchLive &&
            canRefresh &&
            (lastFetch == null ||
                DateTime.now().difference(lastFetch!) >=
                    planRefreshInterval(events, localNow()))) {
          refresh(automatic: true);
        }
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    syncTimer?.cancel();
    syncRepository?.removeListener(syncChanged);
    mail.dispose();
    transitVersion.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) shareChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appVisible = state == AppLifecycleState.resumed;
    if (!appVisible) updateWidget();
    if (state == AppLifecycleState.resumed) {
      if (widget.fetchLive) {
        unawaited(warmNetworkPlanner());
        unawaited(readOrigin());
        mail.refresh(automatic: true);
        syncRepository?.synchronize();
      }
      updateWidget();
      if (widget.fetchLive) updateTimetable(automatic: true);
      if (widget.fetchLive &&
          (lastFetch == null ||
              DateTime.now().difference(lastFetch!).inSeconds > 30)) {
        refresh(automatic: true);
      }
    }
  }

  Future<void> load() async {
    try {
      final loaded = await widget.repository.load();
      if (mounted) {
        setState(() {
          events = loaded;
          loading = false;
          // An intentionally empty calendar must stay empty after restart.
          // Examples are available through the explicit Settings switch.
          samples = false;
          vaultError = null;
        });
        updateWidget();
        await reviewShared();
        if (widget.fetchLive) syncRepository?.synchronize();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          vaultError = 'Could not unlock the local calendar. Existing data has been preserved.';
        });
      }
    }
  }

  List<CalendarEvent> onDay(DateTime d) {
    final source = samples ? demoEvents(d) : events;
    return eventsOnDay(source, d).map(effectiveEvent).toList();
  }

  Future<void> refresh({bool automatic = false}) async {
    if (refreshing) {
      return;
    }
    final now = DateTime.now();
    if (!refreshPolicy.canStart(now)) {
      if (!automatic && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Refresh paused. Try again in ${refreshPolicy.waitAt(now).inSeconds + 1} seconds.',
            ),
          ),
        );
      }
      return;
    }
    refreshPolicy.start(now);
    setState(() {
      refreshing = true;
      liveError = null;
    });
    transitVersion.value++;
    lastFetch = DateTime.now();
    try {
      final f = await LiveFeed.download();
      refreshPolicy.success();
      if (mounted) {
        setState(() {
          live = f;
          refreshing = false;
        });
        transitVersion.value++;
        updateWidget();
      }
    } catch (error) {
      refreshPolicy.fail(DateTime.now(), error);
      if (mounted) {
        setState(() {
          refreshing = false;
          liveError = error is TransitRequestError
              ? error.message
              : error is PlatformException
              ? error.message
              : 'Live PID data is unavailable. Times remain scheduled.';
        });
        transitVersion.value++;
      }
    }
  }

  Future<bool> save(List<CalendarEvent> next) async {
    if (saving || vaultError != null) {
      return false;
    }
    setState(() => saving = true);
    try {
      await widget.repository.save(next);
      final committed = await widget.repository.load();
      if (mounted) {
        setState(() {
          events = committed;
          eventJourneys.clear();
          eventPlans.clear();
          samples = false;
          saving = false;
        });
        updateWidget();
        if (widget.fetchLive) syncRepository?.synchronize();
      }
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save. Your previous calendar is intact.'),
          ),
        );
      }
      return false;
    }
  }

  Future<bool> commitImport(List<CalendarEvent> imported) async {
    final currentIds = events.map((e) => e.id).toSet();
    return save([
      ...events,
      ...imported.where((e) => !currentIds.contains(e.id)),
    ]);
  }

  Future<void> updateTimetable({bool automatic = false}) async {
    final current = metro;
    if (current == null || timetableUpdating) {
      return;
    }
    final now = localNow();
    if (automatic &&
        (!await timetableStore.due(now, current) ||
            !await timetableStore.unmetered())) {
      // A headless worker can have applied a new index while the window was away.
      final cached = await timetableStore.load();
      if (mounted) {
        setState(() => metro = cached);
        transitVersion.value++;
      }
      return;
    }
    final retry = DateTime.tryParse(
      (await timetableStore.metadata())['retryAt'] ?? '',
    );
    if (retry != null && retry.isAfter(now)) {
      if (mounted) {
        setState(
          () => timetableStatus =
              'Timetable refresh paused until ${DateFormat('d MMM HH:mm').format(tz.TZDateTime.from(retry, prague))}.',
        );
      }
      return;
    }
    if (!mounted || timetableUpdating) {
      return;
    }
    setState(() {
      timetableUpdating = true;
      timetableStatus = 'Downloading the common PID timetable…';
    });
    transitVersion.value++;
    try {
      final next = await timetableStore.update(now, current);
      unawaited(warmNetworkPlanner());
      if (mounted) {
        setState(() {
          metro = next;
          timetableStatus =
              'Timetable checked ${DateFormat('d MMM HH:mm').format(now)}.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => timetableStatus =
              'Timetable update failed. The previous valid index was kept.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => timetableUpdating = false);
        transitVersion.value++;
      }
    }
  }

  Future<void> updateWidget() async {
    if (loading || vaultError != null) return;
    if (widgetUpdating) {
      widgetQueued = true;
      return;
    }
    widgetUpdating = true;
    final revision = syncRepository?.operations.length ?? 0;
    final sourceEvents = samples ? demoEvents(localNow()) : [...events];
    final fingerprint = jsonEncode(
      sourceEvents.map((e) => e.toJson()).toList(),
    );
    final preview = samples;
    try {
      final snapshot = await buildWidgetSnapshot(
        sourceEvents,
        live,
        includeDepartNow: appVisible,
        visibleDay: selected,
        onPlan: (id, plan) {
          if (mounted &&
              preview == samples &&
              (samples ||
                  jsonEncode(events.map((e) => e.toJson()).toList()) ==
                      fingerprint)) {
            setState(() {
              eventPlans[id] = plan;
              if (plan.planned == null) {
                eventJourneys.remove(id);
              } else {
                eventJourneys[id] = plan.planned!;
              }
            });
          }
        },
      );
      if (!mounted) return;
      if (preview != samples ||
          (!samples &&
              jsonEncode(events.map((e) => e.toJson()).toList()) !=
                  fingerprint)) {
        widgetQueued = true;
        return;
      }
      setState(() {
        eventJourneys = snapshot.journeys;
        eventPlans = snapshot.plans;
        plansChecked = localNow();
        planPredictionStamp = live?.fresh(localNow()) == true
            ? live?.generated
            : null;
      });
      if (Platform.isAndroid) {
        await widgetChannel.invokeMethod('update', {
          ...snapshot.data,
          'revision': revision,
        });
      }
    } on PlatformException {
      // Calendar remains available if the launcher rejects an update.
    } on MissingPluginException {
      // Headless tests have no native widget channel.
    } finally {
      widgetUpdating = false;
      if (widgetQueued && mounted) {
        widgetQueued = false;
        updateWidget();
      }
    }
  }

  Future<void> edit([CalendarEvent? e]) async {
    if (saving || vaultError != null) {
      return;
    }
    var applySeries = false;
    final series = e == null ? null : meetingSeries(e.id);
    final v = await Navigator.of(context).push<CalendarEvent>(
      MaterialPageRoute(
        builder: (_) => EventEditor(
          event: e,
          day: selected,
          applyToSeries: series == null ? null : (value) => applySeries = value,
        ),
      ),
    );
    if (v != null && mounted) {
      await save([
        for (final existing in events.where((e) => e.id != v.id))
          if (applySeries && meetingSeries(existing.id) == series)
            CalendarEvent.fromJson({
              ...existing.toJson(),
              'venue': v.venue,
              'address': v.address,
              'room': v.room,
              'floor': v.floor,
              'sessionType': v.sessionType,
              'locationSource': v.locationSource,
            })
          else
            existing,
        v,
      ]);
    }
  }

  Future<void> details(CalendarEvent e) async {
    e = effectiveEvent(e);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: paper,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 8, 26, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                eyebrow(
                  '${e.category.toUpperCase()}${e.courseCode.isEmpty ? '' : ' · ${e.courseCode}'}',
                ),
                Text(
                  e.title,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 18),
                detail(
                  Icons.schedule,
                  '${DateFormat('EEE, d MMM').format(e.localStart)} · ${clock(e.localStart)} – ${clock(e.localEnd)}',
                ),
                if (e.category == 'Study')
                  detail(
                    Icons.school_outlined,
                    e.sessionType.isEmpty
                        ? 'Class type not specified · set it in Edit event'
                        : e.sessionType,
                  ),
                if (e.venue.isNotEmpty) detail(Icons.place_outlined, e.venue),
                if (e.address.isNotEmpty) detail(Icons.map_outlined, e.address),
                if (e.room.isNotEmpty || e.floor.isNotEmpty)
                  detail(
                    Icons.meeting_room_outlined,
                    [
                      if (e.room.isNotEmpty) 'Room ${e.room}',
                      if (e.floor.isNotEmpty) 'Floor ${e.floor}',
                    ].join(' · '),
                  ),
                if (events.any((other) => overlaps(e, other)))
                  detail(
                    Icons.warning_amber_rounded,
                    'Time conflict · another event overlaps this one.',
                  ),
                if (e.travelMinutes > 0)
                  detail(
                    Icons.directions_transit,
                    'Leave ${clock(e.leaveAt)} · ${e.travelMinutes} min manual travel + ${e.bufferMinutes} min buffer',
                  ),
                if (e.notes.isNotEmpty) detail(Icons.notes, e.notes),
                if (e.locationSource.isNotEmpty)
                  detail(
                    Icons.fact_check_outlined,
                    'Place source: ${placeSourceLabel(e.locationSource)}',
                  ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openJourney(e);
                  },
                  icon: const Icon(Icons.directions_transit_rounded),
                  label: const Text('Plan transport'),
                ),
                const SizedBox(height: 22),
                if (e.sample)
                  const Text(
                    'Sample event. Add your own event to begin.',
                    style: TextStyle(color: muted),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            edit(e);
                          },
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit event'),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          delete(e);
                        },
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete event',
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> delete(CalendarEvent e) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this event?'),
        content: Text(e.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await removeEvents([e]);
    }
  }

  Future<void> openJourney(CalendarEvent e) async {
    e = effectiveEvent(e);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NetworkPlannerPage(
          initialArrival: e.localStart.subtract(
            Duration(minutes: e.bufferMinutes),
          ),
          initialFrom: e.originStop,
          initialTo: eventDestination(e),
          requireEndpoints: true,
          initialOriginWalk: e.originWalkMinutes,
          initialDestinationWalk: e.destinationWalkMinutes,
          saveStops: (from, to, originWalk, destinationWalk) async {
            final current = events
                .where((event) => event.id == e.id)
                .firstOrNull;
            if (current == null) return false;
            final bound = CalendarEvent.fromJson({
              ...current.toJson(),
              'originStop': from,
              'destinationStop': to,
              'originWalkMinutes': originWalk,
              'destinationWalkMinutes': destinationWalk,
            });
            return save([...events.where((event) => event.id != e.id), bound]);
          },
          live: () => live,
        ),
      ),
    );
    if (mounted) updateWidget();
  }

  Future<void> removeEvents(List<CalendarEvent> removed) async {
    final ids = removed.map((e) => e.id).toSet();
    if (!await save(events.where((e) => !ids.contains(e.id)).toList()) ||
        !mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${removed.length} ${removed.length == 1 ? 'event' : 'events'} deleted.',
        ),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            final existing = events.map((e) => e.id).toSet();
            await save([
              ...events,
              ...removed.where((e) => !existing.contains(e.id)),
            ]);
          },
        ),
      ),
    );
  }

  Future<void> eventActions(CalendarEvent event, DateTime day) async {
    if (event.sample || saving || vaultError != null) {
      return;
    }
    final date = DateFormat('EEEE, d MMM').format(day),
        dayEvents = eventsOnDay(events, day);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: paper,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Delete this event'),
                  subtitle: const Text('Only this occurrence'),
                  onTap: () => Navigator.pop(ctx, 'one'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('Delete all events on this day'),
                  subtitle: Text('$date · ${dayEvents.length} events'),
                  onTap: () => Navigator.pop(ctx, 'day'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_repeat_outlined),
                  title: const Text('Delete similar events'),
                  subtitle: const Text(
                    'Same title · choose week, month or dates',
                  ),
                  onTap: () => Navigator.pop(ctx, 'similar'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    if (action == 'one') {
      await delete(event);
      return;
    }
    if (action == 'similar') {
      await deleteSimilarEvents(event);
      return;
    }
    if (action == 'day' && mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Clear $date?'),
          content: Text(
            'Delete ${dayEvents.length} events shown on this day? Events on other dates will stay. An event continuing across midnight is deleted as a whole.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep events'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete day'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await removeEvents(dayEvents);
      }
    }
  }

  String periodLabel(EventDatePeriod period) =>
      '${DateFormat('d MMM yyyy').format(period.firstDate)} – '
      '${DateFormat('d MMM yyyy').format(period.lastDate)}';

  Future<void> deleteSimilarEvents(CalendarEvent event) async {
    final week = EventDatePeriod.weekOf(event.localStart),
        month = EventDatePeriod.monthOf(event.localStart);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose deletion period'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_view_week_outlined),
                  title: const Text("This event's week"),
                  subtitle: Text(periodLabel(week)),
                  onTap: () => Navigator.pop(ctx, 'week'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_month_outlined),
                  title: const Text("This event's month"),
                  subtitle: Text(periodLabel(month)),
                  onTap: () => Navigator.pop(ctx, 'month'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.date_range_outlined),
                  title: const Text('Choose dates'),
                  onTap: () => Navigator.pop(ctx, 'custom'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    var period = choice == 'month' ? month : week;
    if (choice == 'custom') {
      final years = [
        ...events.map((e) => e.localStart.year),
        event.localStart.year,
      ]..sort();
      final range = await showDateRangePicker(
        context: context,
        helpText: 'Choose deletion dates',
        firstDate: DateTime(years.first - 1),
        lastDate: DateTime(years.last + 1, 12, 31),
        initialDateRange: DateTimeRange(
          start: week.firstDate,
          end: week.lastDate,
        ),
      );
      if (!mounted || range == null) return;
      period = EventDatePeriod(range.start, range.end);
    }
    final matches = similarEventsInPeriod(events, event, period);
    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No matching events in this period.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Delete ${matches.length} similar ${matches.length == 1 ? 'event' : 'events'}?',
        ),
        content: SingleChildScrollView(
          child: Text(
            '${event.title}\n\n${periodLabel(period)}\n\n'
            'Titles match ignoring letter case and extra spaces. Only events starting in this period will be deleted. You can Undo afterwards.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep events'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete matches'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await removeEvents(matches);
  }

  String get liveLabel => refreshing
      ? 'Refreshing PID…'
      : live == null
      ? 'Live data unavailable'
      : live!.fresh(DateTime.now())
      ? 'PID live · ${clock(tz.TZDateTime.from(live!.generated, prague))}'
      : 'PID data is stale';
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 880;
    final contents = loading
        ? const Center(child: CircularProgressIndicator())
        : vaultError != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 48),
                  const SizedBox(height: 20),
                  Text(vaultError!, textAlign: TextAlign.center),
                  FilledButton(onPressed: load, child: const Text('Retry')),
                ],
              ),
            ),
          )
        : switch (page) {
            0 => calendarPage(),
            1 => TransportPage(
              index: metro,
              live: live,
              label: liveLabel,
              refresh: refresh,
              error: liveError,
              updateTimetable: updateTimetable,
              timetableUpdating: timetableUpdating,
              timetableStatus: timetableStatus,
            ),
            2 => sourcesPage(),
            _ => settingsPage(),
          };
    const destinations = [
      (Icons.calendar_month_outlined, 'Calendar'),
      (Icons.directions_transit_rounded, 'Transport'),
      (Icons.inbox_outlined, 'Sources'),
      (Icons.tune_rounded, 'Settings'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.local_florist_rounded, color: orange, size: 29),
            SizedBox(width: 9),
            Text(
              'calendula',
              style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -1),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: refreshing ? null : refresh,
            icon: refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh transit',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              NavigationRail(
                selectedIndex: page,
                onDestinationSelected: (v) => setState(() => page = v),
                labelType: NavigationRailLabelType.all,
                backgroundColor: paper,
                destinations: destinations
                    .map(
                      (d) => NavigationRailDestination(
                        icon: Icon(d.$1),
                        label: Text(d.$2),
                      ),
                    )
                    .toList(),
              ),
            Expanded(child: contents),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (v) => setState(() => page = v),
              backgroundColor: paper,
              indicatorColor: const Color(0xFFE9EFDC),
              destinations: destinations
                  .map(
                    (d) => NavigationDestination(icon: Icon(d.$1), label: d.$2),
                  )
                  .toList(),
            ),
      floatingActionButton: page == 0 && vaultError == null
          ? FloatingActionButton.extended(
              onPressed: saving ? null : edit,
              backgroundColor: forest,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: Text(saving ? 'Saving…' : 'New event'),
            )
          : null,
    );
  }

  void selectDay(DateTime day) {
    setState(() => selected = day);
    updateWidget();
  }

  Widget calendarPage() {
    final monday = tz.TZDateTime(
      prague,
      selected.year,
      selected.month,
      selected.day - selected.weekday + 1,
    );
    final days = view == 1
        ? List.generate(
            7,
            (i) => tz.TZDateTime(
              prague,
              monday.year,
              monday.month,
              monday.day + i,
            ),
          )
        : [selected];
    final list = days.expand(onDay).toList(),
        next =
            onDay(selected)
                .where((e) => e.end.isAfter(localNow()))
                .firstOrNull ??
            onDay(selected).firstOrNull;
    return RefreshIndicator(
      onRefresh: refresh,
      child: centered(
        ListView(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 100),
          children: [
            eyebrow('A LITTLE SPACE FOR YOUR DAY'),
            Text(
              DateFormat('EEEE, d MMMM').format(selected),
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w500,
                letterSpacing: -1.2,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Everything in its own good time.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 24),
            if (samples)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Sample day · manual travel',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() => samples = false);
                        updateWidget();
                      },
                      child: const Text('Clear view'),
                    ),
                  ],
                ),
              ),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Previous day',
                      onPressed: () => selectDay(
                        tz.TZDateTime(
                          prague,
                          selected.year,
                          selected.month,
                          selected.day - 1,
                        ),
                      ),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    TextButton(
                      onPressed: () => selectDay(localNow()),
                      child: const Text('Today'),
                    ),
                    IconButton(
                      tooltip: 'Next day',
                      onPressed: () => selectDay(
                        tz.TZDateTime(
                          prague,
                          selected.year,
                          selected.month,
                          selected.day + 1,
                        ),
                      ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: view,
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Day')),
                      DropdownMenuItem(value: 1, child: Text('Week')),
                      DropdownMenuItem(value: 2, child: Text('Month')),
                    ],
                    onChanged: (v) => setState(() => view = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (view == 2) monthGrid() else weekStrip(),
            const SizedBox(height: 25),
            if (next != null && !next.allDay) journeyCard(next),
            if (view == 0) ...[
              const SizedBox(height: 20),
              DayTimeline(
                day: selected,
                now: localNow(),
                events: onDay(selected),
                onEvent: details,
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                eyebrow('THE DAY AHEAD', bottom: 0),
                const Spacer(),
                Text(
                  '${list.length} events',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Column(
                  children: [
                    Icon(Icons.wb_sunny_outlined, color: orange, size: 42),
                    SizedBox(height: 16),
                    Text(
                      'A little room to breathe.',
                      style: TextStyle(fontSize: 20),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Add something you want to make time for.',
                      style: TextStyle(color: muted),
                    ),
                  ],
                ),
              ),
            for (final day in days) ...[
              if (view == 1)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: eyebrow(
                    DateFormat('EEEE, d MMM').format(day).toUpperCase(),
                    bottom: 0,
                  ),
                ),
              for (final e in onDay(day)) eventCard(e, day),
            ],
            if (hasConflicts(list))
              const Text(
                'Some events overlap. Open their details to adjust the times.',
                style: TextStyle(color: Color(0xFFA13C31)),
              ),
            const SizedBox(height: 22),
            const Text(
              'Stored encrypted on this device · Europe/Prague',
              style: TextStyle(color: muted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget weekStrip() => Row(
    children: List.generate(7, (i) {
      final first = tz.TZDateTime(
            prague,
            selected.year,
            selected.month,
            selected.day - selected.weekday + 1,
          ),
          d = tz.TZDateTime(prague, first.year, first.month, first.day + i),
          active = dayKey(d) == dayKey(selected);
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => selectDay(d),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                color: active ? forest : Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Text(
                    DateFormat('E').format(d).substring(0, 1),
                    style: TextStyle(
                      color: active ? Colors.white70 : muted,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '${d.day}',
                    style: TextStyle(
                      color: active ? Colors.white : ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    onDay(d).isNotEmpty ? '•' : ' ',
                    style: TextStyle(
                      color: active ? orange : forest,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }),
  );
  Widget monthGrid() {
    final first = tz.TZDateTime(prague, selected.year, selected.month, 1),
        start = tz.TZDateTime(
          prague,
          first.year,
          first.month,
          2 - first.weekday,
        );
    return Column(
      children: [
        Text(DateFormat('MMMM yyyy').format(first)),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 42,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
          ),
          itemBuilder: (_, i) {
            final d = tz.TZDateTime(
                  prague,
                  start.year,
                  start.month,
                  start.day + i,
                ),
                active = dayKey(d) == dayKey(selected);
            return InkWell(
              onTap: () => selectDay(d),
              child: Container(
                decoration: BoxDecoration(
                  color: active ? forest : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${d.day}',
                      style: TextStyle(
                        color: active
                            ? Colors.white
                            : d.month == first.month
                            ? ink
                            : muted,
                      ),
                    ),
                    if (onDay(d).isNotEmpty)
                      Text(
                        '•',
                        style: TextStyle(color: active ? orange : forest),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget journeyCard(CalendarEvent e) => Material(
    color: forest,
    borderRadius: BorderRadius.circular(25),
    child: InkWell(
      key: ValueKey('journey:${e.id}'),
      onTap: () => openJourney(e),
      borderRadius: BorderRadius.circular(25),
      child: Container(
        padding: const EdgeInsets.all(25),
        decoration: BoxDecoration(
          color: forest,
          borderRadius: BorderRadius.circular(25),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.directions_transit_rounded,
                  color: Colors.white70,
                  size: 18,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'YOUR TIME TO LEAVE',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.7,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FittedBox(
                    alignment: Alignment.centerLeft,
                    fit: BoxFit.scaleDown,
                    child: Text(
                      eventJourneys[e.id] != null
                          ? clockLocal(eventJourneys[e.id]!.departure)
                          : e.travelMinutes > 0
                          ? clock(e.leaveAt)
                          : '—:—',
                      style: const TextStyle(
                        fontSize: 52,
                        letterSpacing: -2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const Icon(
                  Icons.arrow_outward_rounded,
                  color: orange,
                  size: 34,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              e.title,
              style: const TextStyle(fontSize: 16, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              e.venue,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 18),
            journeyLines(e, light: true),
            const Divider(color: Colors.white24),
            Row(
              children: [
                Expanded(
                  child: whiteFact(
                    'TRAVEL',
                    eventJourneys[e.id] == null
                        ? '${e.travelMinutes} min'
                        : '${eventJourneys[e.id]!.arrival.difference(eventJourneys[e.id]!.departure).inMinutes} min',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: whiteFact('BUFFER', '${e.bufferMinutes} min')),
                const SizedBox(width: 12),
                Expanded(child: whiteFact('STARTS', clock(e.localStart))),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              eventJourneys[e.id] == null
                  ? e.travelMinutes > 0
                        ? 'Manual estimate · not a live route'
                        : 'Set a starting point and exact destination'
                  : '${eventJourneys[e.id]!.changes} changes · ${eventJourneys[e.id]!.legs.any((l) => l.predicted) ? 'available delay predictions' : 'scheduled connection'}',
              style: TextStyle(color: Colors.white60, fontSize: 10),
            ),
          ],
        ),
      ),
    ),
  );
  Widget journeyLines(CalendarEvent e, {bool light = false}) {
    final plan = eventPlans[e.id];
    final color = light ? Colors.white70 : muted;
    final ended = !e.end.isAfter(localNow());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          ended
              ? 'Event has ended'
              : plan?.leaveLine(e) ??
                    (e.travelMinutes > 0
                        ? 'Leave ${clock(e.leaveAt)} · manual estimate'
                        : 'Calculating departure…'),
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (!ended && plan != null)
          Text(
            'Arrive ${e.bufferMinutes} min early · ${plan.status}${plan.origin.isEmpty ? '' : ' · ${plan.origin}'}',
            style: TextStyle(color: color, fontSize: 10),
          ),
        if (!ended &&
            appVisible &&
            plan != null &&
            plan.departNowChecked &&
            localNow().difference(plan.calculatedAt) <=
                const Duration(minutes: 3))
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              plan.nowLine(e),
              style: TextStyle(color: light ? orange : forest, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget eventCard(CalendarEvent e, DateTime day) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.allDay ? 'All day' : clock(e.localStart),
                  style: const TextStyle(
                    fontSize: 12,
                    color: muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  e.allDay ? '' : clock(e.localEnd),
                  style: const TextStyle(fontSize: 10, color: muted),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Material(
            color: categoryColor(e.category),
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              key: ValueKey('event:${e.id}:${dayKey(day)}'),
              onTap: () => details(e),
              onLongPress: e.sample ? null : () => eventActions(e, day),
              onSecondaryTap: e.sample ? null : () => eventActions(e, day),
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${e.sessionType.isEmpty ? e.category.toUpperCase() : e.sessionType.toUpperCase()}${e.courseCode.isEmpty ? '' : ' · ${e.courseCode}'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.3,
                              color: muted,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.arrow_outward_rounded,
                          size: 15,
                          color: muted,
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    if (!e.sample && events.any((other) => overlaps(e, other)))
                      const Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: Text(
                          'Time conflict',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFFAC612A),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Text(
                      e.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (e.venue.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          e.venue,
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                      ),
                    if (e.room.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Room ${e.room}${e.floor.isNotEmpty ? ' · Floor ${e.floor}' : ''}',
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                    if (e.address.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          e.address,
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                    if (e.category == 'Study' && e.sessionType.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Class type not specified · edit to set',
                          style: TextStyle(fontSize: 10, color: muted),
                        ),
                      ),
                    if (!e.allDay) journeyLines(e),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  Widget sourcesPage() => centered(
    ListView(
      padding: const EdgeInsets.all(24),
      children: [
        eyebrow('ONLY WHAT YOU CHOOSE'),
        title('Your sources'),
        const SizedBox(height: 25),
        panel(
          Icons.table_chart_outlined,
          'University CSV',
          'Read a SIS schedule locally. Review dates, rooms, odd/even weeks and overlapping classes.',
          action: FilledButton(
            onPressed: loading || saving || vaultError != null
                ? null
                : () async {
                    final added = await Navigator.of(context)
                        .push<List<CalendarEvent>>(
                          MaterialPageRoute(
                            builder: (_) => CsvImportPage(
                              existing: [...events],
                              commit: commitImport,
                            ),
                          ),
                        );
                    if (added != null && added.isNotEmpty && mounted) {
                      setState(() {
                        selected = added.first.localStart;
                        page = 0;
                        view = 0;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${added.length} events imported.'),
                        ),
                      );
                    }
                  },
            child: const Text('Import CSV'),
          ),
        ),
        const SizedBox(height: 16),
        panel(
          Icons.edit_note_rounded,
          'Paste a schedule',
          'Review an ICS event or a structured text invitation on this device.',
          action: FilledButton(
            onPressed: () async {
              final e = await Navigator.of(context).push<CalendarEvent>(
                MaterialPageRoute(builder: (_) => const ImportPage()),
              );
              if (e != null) {
                await save([...events, e]);
              }
            },
            child: const Text('Paste & review'),
          ),
        ),
        const SizedBox(height: 16),
        panel(
          Icons.mail_outline,
          'Gmail & Outlook',
          'Read recent inbox invitations on open or by request. Local recognition and review; nothing is sent or marked read.',
          action: FilledButton(
            onPressed: () async {
              if (!mail.ready) await mail.load();
              if (mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MailPage(
                      controller: mail,
                      events: () => [...events],
                      commit: commitImport,
                    ),
                  ),
                );
              }
            },
            child: const Text('Mail invitations'),
          ),
        ),
        const SizedBox(height: 16),
        panel(
          Icons.description_outlined,
          'PDF, Excel & recurring ICS',
          'Read text PDFs, XLSX tables, daily and weekly ICS, or text. Review incomplete and unsupported records locally.',
          action: FilledButton(
            onPressed: loading || saving || vaultError != null
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ImportReviewPage(existing: [...events], commit: save),
                    ),
                  ),
            child: const Text('Import & review'),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'No mail, schedule or destination is sent to an AI service.',
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ],
    ),
  );
  Widget settingsPage() => centered(
    ListView(
      padding: const EdgeInsets.all(24),
      children: [
        eyebrow('A CALMER KIND OF CALENDAR'),
        title('Made personal'),
        if (Platform.isWindows) ...[
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DesktopSettingsPage()),
            ),
            icon: const Icon(Icons.desktop_windows_outlined),
            label: const Text('Windows & desktop agenda'),
          ),
        ],
        const SizedBox(height: 25),
        panel(
          Icons.trip_origin,
          'Journey starting point',
          'Use current GPS location, a home address or another address. No background location tracking.',
          action: FilledButton(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const JourneySettingsPage()),
              );
              if (mounted) {
                unawaited(readOrigin());
                updateWidget();
              }
            },
            child: const Text('Set home & starting point'),
          ),
        ),
        const SizedBox(height: 16),
        panel(
          Icons.lock_outline,
          'On your device',
          'AES-256-GCM encrypted calendar. Key held by OS secure storage. Android cloud backup is disabled.',
        ),
        const SizedBox(height: 16),
        panel(
          Icons.public_outlined,
          'Prague transport',
          'Embedded Tor hides your device IP for PID downloads. Automatic updates share one public cache and persistent retry limits. No calendar or GPS is uploaded.',
          action: FilledButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NetworkSettingsPage()),
            ),
            child: const Text('Private updates'),
          ),
        ),
        const SizedBox(height: 16),
        panel(
          Icons.widgets_outlined,
          Platform.isWindows ? 'Desktop agenda window' : 'Home screen widget',
              'Long-press your Android home screen → Widgets → Calendula. Resize it vertically to show more of the day. Exact event addresses and your starting point settings calculate planned departures automatically. The leave-now row is refreshed while the app is open. Missing places and manual estimates stay labelled.',
          action: Platform.isAndroid
              ? OutlinedButton(
                  onPressed: () async {
                    try {
                      await widgetChannel.invokeMethod('preview');
                    } on PlatformException {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Widget preview unavailable'),
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Preview Android widget'),
                )
              : null,
        ),
        const SizedBox(height: 16),
        panel(
          Icons.devices_outlined,
          'Device sync',
          'Encrypted operations through WebDAV / Yandex, a shared folder or local pairing. Concurrent edits stay reviewable; account tokens stay here.',
          action: syncRepository == null
              ? null
              : FilledButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SyncPage(
                        repository: syncRepository!,
                        onSetupApplied: mail.load,
                      ),
                    ),
                  ),
                  child: const Text('Connect devices'),
                ),
        ),
        TextButton(
          onPressed: () =>
              showLicensePage(context: context, applicationName: 'Calendula'),
          child: const Text('Open-source licenses'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show sample day'),
          subtitle: const Text('Examples stay separate from saved events.'),
          value: samples,
          onChanged: (v) {
            setState(() => samples = v);
            updateWidget();
          },
        ),
        const SizedBox(height: 18),
        const Text(
          'Native preview 0.1 · English · Europe/Prague\nTransit data: PID / ROPID · CC BY 4.0',
          style: TextStyle(color: muted, fontSize: 12),
        ),
      ],
    ),
  );
}

bool hasConflicts(List<CalendarEvent> events) {
  for (var i = 0; i < events.length; i++) {
    for (var j = i + 1; j < events.length; j++) {
      if (events[i].start.isBefore(events[j].end) &&
          events[j].start.isBefore(events[i].end)) {
        return true;
      }
    }
  }
  return false;
}

Widget centered(Widget child) => SafeArea(
  child: Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: child,
    ),
  ),
);
Widget eyebrow(String text, {double bottom = 10}) => Padding(
  padding: EdgeInsets.only(bottom: bottom),
  child: Text(
    text,
    style: const TextStyle(
      fontSize: 10,
      color: muted,
      letterSpacing: 1.6,
      fontWeight: FontWeight.w600,
    ),
  ),
);
Widget title(String text) => Text(
  text,
  style: const TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w500,
    letterSpacing: -1,
  ),
);
Widget whiteFact(String label, String value) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(
      label,
      style: const TextStyle(
        color: Colors.white60,
        fontSize: 9,
        letterSpacing: .8,
      ),
    ),
    const SizedBox(height: 5),
    Text(value, style: const TextStyle(color: Colors.white, fontSize: 14)),
  ],
);
Widget detail(IconData icon, String text) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 8),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 19, color: muted),
      const SizedBox(width: 12),
      Expanded(child: Text(text)),
    ],
  ),
);
Widget panel(IconData icon, String heading, String text, {Widget? action}) =>
    Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: forest, size: 28),
          const SizedBox(height: 15),
          Text(
            heading,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 9),
          Text(text, style: const TextStyle(color: muted, height: 1.5)),
          if (action != null)
            Padding(padding: const EdgeInsets.only(top: 18), child: action),
        ],
      ),
    );

class TransportPage extends StatefulWidget {
  final Future<void> Function()? updateTimetable;
  final bool timetableUpdating;
  final String? timetableStatus;
  final DateTime? initialArrival;
  final MetroIndex? index;
  final LiveFeed? live;
  final String label;
  final String? error;
  final Future<void> Function() refresh;
  const TransportPage({
    super.key,
    this.index,
    this.live,
    required this.label,
    this.error,
    required this.refresh,
    this.initialArrival,
    this.updateTimetable,
    this.timetableUpdating = false,
    this.timetableStatus,
  });
  @override
  State<TransportPage> createState() => _TransportPageState();
}

class _TransportPageState extends State<TransportPage> {
  String from = 'Dejvická', to = 'Muzeum';
  DateTime day = localNow();
  late TimeOfDay time;
  MetroJourney? result;
  String? error;
  bool searched = false;
  @override
  void initState() {
    super.initState();
    final target =
        widget.initialArrival ?? localNow().add(const Duration(hours: 1));
    day = target;
    time = TimeOfDay.fromDateTime(target);
  }

  @override
  void didUpdateWidget(TransportPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (searched &&
        (oldWidget.live != widget.live || oldWidget.index != widget.index)) {
      calculate();
    }
  }

  void calculate() {
    try {
      final r = widget.index?.arriveBy(
        from,
        to,
        tz.TZDateTime.from(wallTime(day, time), prague),
        live: widget.live,
      );
      setState(() {
        result = r;
        searched = true;
        error = r == null
            ? 'No direct metro trip. Try stations on the same line or a later arrival.'
            : null;
      });
    } catch (e) {
      setState(() {
        result = null;
        searched = true;
        error = e is FormatException
            ? e.message
            : e is StateError
            ? e.message
            : 'Unable to plan this trip.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => centered(
    ListView(
      padding: const EdgeInsets.all(24),
      children: [
        eyebrow('PRAGUE, IN YOUR OWN TIME'),
        title('A way to get there'),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => NetworkPlannerPage(
                initialArrival: widget.initialArrival,
                live: () => widget.live,
              ),
            ),
          ),
          icon: const Icon(Icons.route),
          label: const Text('Plan with connections'),
        ),
        const SizedBox(height: 12),
        const Text(
          'Private calculation. Common public data.',
          style: TextStyle(color: muted),
        ),
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
              Row(
                children: [
                  Icon(
                    widget.live?.fresh(DateTime.now()) == true
                        ? Icons.sensors_rounded
                        : Icons.schedule,
                    color: orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.refresh,
                    icon: const Icon(Icons.refresh, color: Colors.white),
                    tooltip: 'Refresh PID',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                widget.live == null
                    ? 'Updates automatically through embedded Tor.'
                    : '${widget.live!.trips.length} trip updates · ${widget.live!.delayed} trips report a delay',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 10),
              const Text(
                'No account or API key used. Your itinerary stays here.',
                style: TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ],
          ),
        ),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 15),
            child: Text(
              widget.error!,
              style: const TextStyle(color: Color(0xFFA13C31)),
            ),
          ),
        const SizedBox(height: 25),
        if (widget.updateTimetable != null) ...[
          OutlinedButton.icon(
            onPressed: widget.timetableUpdating ? null : widget.updateTimetable,
            icon: const Icon(Icons.download_rounded),
            label: Text(
              widget.timetableUpdating
                  ? 'Updating timetable…'
                  : 'Update timetable (~48 MB)',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.timetableStatus ?? 'Daily on open over an unmetered network. The full public PID file is downloaded; direct metro is currently indexed.',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 20),
        ],
        if (widget.index == null)
          const LinearProgressIndicator()
        else ...[
          eyebrow('DIRECT METRO · EARLY ROUTING PREVIEW'),
          DropdownButtonFormField<String>(
            initialValue: from,
            decoration: const InputDecoration(labelText: 'From station'),
            isExpanded: true,
            items: widget.index!.stations
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: (v) {
              setState(() {
                from = v!;
                result = null;
                searched = false;
              });
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: to,
            decoration: const InputDecoration(labelText: 'To station'),
            isExpanded: true,
            items: widget.index!.stations
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: (v) {
              setState(() {
                to = v!;
                result = null;
                searched = false;
              });
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: day,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2040),
                    );
                    if (d != null) {
                      setState(() {
                        day = d;
                        result = null;
                        searched = false;
                      });
                    }
                  },
                  child: Text(DateFormat('d MMM yyyy').format(day)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: time,
                      builder: (ctx, child) => MediaQuery(
                        data: MediaQuery.of(ctx)
                            .copyWith(alwaysUse24HourFormat: true),
                        child: child!,
                      ),
                    );
                    if (t != null) {
                      setState(() {
                        time = t;
                        result = null;
                        searched = false;
                      });
                    }
                  },
                  child: Text(
                    'Arrive ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: calculate,
            icon: const Icon(Icons.route_outlined),
            label: const Text('Calculate on this device'),
          ),
          const SizedBox(height: 20),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Text(
                error!,
                style: const TextStyle(color: Color(0xFFA13C31)),
              ),
            ),
          if (result case final r?)
            panel(
              Icons.directions_subway_rounded,
              'Line ${r.line} · ${clock(r.departure)} → ${clock(r.arrival)}',
              '${r.origin} → ${r.destination}\nTowards ${r.headsign}\n${r.updated ? 'Updated by fresh PID predictions' : 'Scheduled · no matching live prediction'}\nStation to station only. Walking and transfers are not included.',
            ),
          const SizedBox(height: 20),
          Text(
            'Timetable ${widget.index!.start} — ${widget.index!.end}\nPID / ROPID · CC BY 4.0',
            style: const TextStyle(color: muted, fontSize: 11),
          ),
          const SizedBox(height: 12),
          const Text(
            'Direct metro only. Full tram, bus, transfers, walking and event-linked routes are being implemented. A missing prediction never means “on time”.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.5),
          ),
        ],
        const SizedBox(height: 30),
      ],
    ),
  );
}
