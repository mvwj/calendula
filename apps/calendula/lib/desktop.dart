import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart' as native;

import 'calendar.dart';
import 'main.dart';
import 'sync.dart';
import 'widget_snapshot.dart';
import 'desktop_tor.dart';
import 'transit.dart';
import 'event_place.dart';
import 'day_timeline.dart';

bool desktopWidgetMode = false;
final desktopController = DesktopController();

class DesktopController with WindowListener {
  bool tray = false;
  native.TrayIcon? _icon;
  native.Image? _image;
  static const storage = FlutterSecureStorage();
  static const channel = MethodChannel('app.calendula/desktop');
  Future<void> initialize({
    required bool widget,
    bool autostart = false,
  }) async {
    desktopWidgetMode = widget;
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: widget ? const Size(380, 560) : const Size(1180, 780),
        minimumSize: widget ? const Size(320, 380) : const Size(740, 600),
        title: widget ? 'Calendula · Today' : 'Calendula',
        backgroundColor: paper,
        skipTaskbar: widget,
      ),
      () async {
        await windowManager.show();
      },
    );
    windowManager.addListener(this);
    if (widget) {
      await windowManager.setAlwaysOnTop(true);
      return;
    }
    tray = await storage.read(key: 'calendula.desktop.tray') == 'true';
    await setTray(tray);
    if (autostart && tray) await windowManager.hide();
  }

  Future<void> setTray(bool value) async {
    if (value && _icon == null) {
      _icon = native.TrayIcon.create();
      _image = native.Image.fromFile(
        '${File(Platform.resolvedExecutable).parent.path}/calendula.png',
      );
      if (_icon == null || _image == null) {
        throw StateError('Tray icon is unavailable.');
      }
      _icon!.icon = _image;
      _icon!.setTooltip('Calendula · click to open');
      _icon!.addListener((event) {
        if (event is native.TrayIconClickedEvent ||
            event is native.TrayIconDoubleClickedEvent) {
          windowManager.show();
          windowManager.focus();
        }
      });
      _icon!.setVisible(true);
    } else if (!value) {
      _icon?.dispose();
      _icon = null;
      _image?.dispose();
      _image = null;
    }
    tray = value;
    await windowManager.setPreventClose(true);
    await storage.write(key: 'calendula.desktop.tray', value: '$value');
  }

  Future<void> widget() async {
    await Process.start(
      Platform.resolvedExecutable,
      ['--widget'],
      workingDirectory: File(Platform.resolvedExecutable).parent.path,
      mode: ProcessStartMode.detached,
    );
  }

  @override
  Future<void> onWindowClose() async {
    if (tray) {
      await windowManager.hide();
    } else {
      await DesktopTor.instance.stop();
      await windowManager.destroy();
    }
  }
}

class DesktopSettingsPage extends StatefulWidget {
  const DesktopSettingsPage({super.key});
  @override
  State<DesktopSettingsPage> createState() => _DesktopSettingsPageState();
}

class _DesktopSettingsPageState extends State<DesktopSettingsPage> {
  bool startup = false;
  String? error;
  @override
  void initState() {
    super.initState();
    DesktopController.channel.invokeMethod<bool>('startupStatus').then((v) {
      if (mounted) setState(() => startup = v ?? false);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Windows preferences')),
    body: centered(
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          eyebrow('NATIVE WINDOWS APP'),
          title('A quiet place on your desktop'),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep Calendula running in the tray'),
            subtitle: const Text(
              'Closing the main window hides it. Open it from the flower icon; delays and cloud sync continue while Windows is awake.',
            ),
            value: desktopController.tray,
            onChanged: (v) async {
              try {
                await desktopController.setTray(v);
                if (mounted) setState(() {});
              } catch (_) {
                if (mounted) {
                  setState(() => error = 'The tray could not be changed.');
                }
              }
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Start at Windows sign-in'),
            value: startup,
            onChanged: (v) async {
              try {
                await DesktopController.channel.invokeMethod('startup', v);
                if (mounted) setState(() => startup = v);
              } catch (_) {
                if (mounted) {
                  setState(
                    () => error = 'Startup preference could not be saved.',
                  );
                }
              }
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: desktopController.widget,
            icon: const Icon(Icons.widgets_outlined),
            label: const Text('Open desktop agenda'),
          ),
          TextButton(
            onPressed: () async {
              await DesktopTor.instance.stop();
              await windowManager.destroy();
            },
            child: const Text('Quit Calendula'),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 20),
          const Text(
            'The agenda is a separate compact window. Calendar contents remain encrypted; it reads the same local calendar as the main app.',
            style: TextStyle(color: muted),
          ),
        ],
      ),
    ),
  );
}

class DesktopAgenda extends StatefulWidget {
  final SyncRepository repository;
  const DesktopAgenda({super.key, required this.repository});
  @override
  State<DesktopAgenda> createState() => _DesktopAgendaState();
}

class _DesktopAgendaState extends State<DesktopAgenda>
    with WidgetsBindingObserver {
  List<CalendarEvent> events = [];
  WidgetSnapshot? snapshot;
  String? error;
  Timer? timer;
  bool busy = false;
  bool visible = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => refresh());
  }

  Future<void> refresh() async {
    if (busy) return;
    busy = true;
    try {
      final list = widget.repository.initialized
          ? await widget.repository.reloadFromDisk()
          : await widget.repository.load();
      final bytes = await DesktopTor.instance.cachedLive();
      final data = await buildWidgetSnapshot(
        list,
        bytes == null ? null : LiveFeed.decode(bytes),
        includeDepartNow: visible,
      );
      if (mounted) {
        setState(() {
          events = list.map(effectiveEvent).toList();
          snapshot = data;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Open Calendula to unlock your local calendar.');
      }
    } finally {
      busy = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    widget.repository.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    visible = state == AppLifecycleState.resumed;
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final today = localNow(),
        list = eventsOnDay(
          events,
          today,
        ).where((e) => e.end.isAfter(today)).toList();
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              child: const Row(
                children: [
                  Icon(Icons.local_florist_rounded, color: orange, size: 27),
                  SizedBox(width: 10),
                  Text(
                    'calendula',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -1,
                    ),
                  ),
                  Spacer(),
                  Icon(Icons.drag_indicator, color: muted),
                ],
              ),
            ),
            const SizedBox(height: 25),
            eyebrow('TODAY · ${dayKey(today)}'),
            title('A little clearer.'),
            if (snapshot != null)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 20),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: forest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.directions_transit, color: orange),
                    const SizedBox(height: 12),
                    Text(
                      snapshot!.data['leave'],
                      style: const TextStyle(
                        fontSize: 22,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      snapshot!.data['note'],
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    if (visible &&
                        (snapshot!.data['departNow'] as String? ?? '')
                            .isNotEmpty)
                      Text(
                        snapshot!.data['departNow'],
                        style: const TextStyle(color: orange, fontSize: 13),
                      ),
                  ],
                ),
              ),
            DayTimeline(day: today, now: today, events: list),
            const SizedBox(height: 18),
            for (final e in list.take(8))
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  color: categoryColor(e.category),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.allDay
                          ? 'ALL DAY'
                          : '${clock(e.localStart)} — ${clock(e.localEnd)}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: muted,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      e.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (e.sessionType.isNotEmpty)
                      Text(
                        e.sessionType,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    if (e.address.isNotEmpty)
                      Text(
                        e.address,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    if (!e.allDay && snapshot?.plans[e.id] != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        snapshot!.plans[e.id]!.leaveLine(e),
                        style: const TextStyle(fontSize: 12, color: forest),
                      ),
                      if (visible &&
                          snapshot!.plans[e.id]!.departNowChecked &&
                          today.difference(
                                snapshot!.plans[e.id]!.calculatedAt,
                              ) <=
                              const Duration(minutes: 3))
                        Text(
                          snapshot!.plans[e.id]!.nowLine(e),
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                    ],
                    if (e.venue.isNotEmpty)
                      Text(
                        '${e.venue}${e.room.isEmpty ? '' : ' · Room ${e.room}'}${e.floor.isEmpty ? '' : ' · Floor ${e.floor}'}',
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                  ],
                ),
              ),
            if (error != null) Text(error!),
            if (list.isEmpty && error == null)
              const Text(
                'A little room to breathe.',
                style: TextStyle(color: muted),
              ),
            TextButton.icon(
              onPressed: () => Process.start(
                Platform.resolvedExecutable,
                [],
                mode: ProcessStartMode.detached,
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open calendar'),
            ),
          ],
        ),
      ),
    );
  }
}
