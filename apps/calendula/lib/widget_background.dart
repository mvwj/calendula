import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'calendar.dart';
import 'sync.dart';
import 'transit.dart';
import 'widget_snapshot.dart';

import 'dart:io';

import 'timetable_store.dart';

Future<void> _applyDownloadedTimetable() async {
  const control = MethodChannel('app.calendula/background');
  final cache = await control.invokeMapMethod<String, dynamic>(
    'timetableCache',
  );
  final now = localNow();
  if (cache == null ||
      cache['day'] != dayKey(now) ||
      cache['path'] is! String) {
    return;
  }
  final file = File(cache['path']);
  final store = TimetableStore(client: () => CachedTimetableClient(file));
  final current = await store.load();
  if (await store.due(now, current)) await store.update(now, current);
}

@pragma('vm:entry-point')
Future<void> widgetBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const control = MethodChannel('app.calendula/background');
  try {
    var timetableApplied = true;
    try {
      await _applyDownloadedTimetable();
    } catch (_) {
      timetableApplied = false;
    }
    final repository = SyncRepository(legacy: EncryptedEventRepository());
    final events = await repository.load();
    final bytes = await control.invokeMethod<Uint8List>('liveCache');
    final feed = bytes == null ? null : LiveFeed.decode(bytes);
    final snapshot = await buildWidgetSnapshot(events, feed);
    await const MethodChannel('app.calendula/widget').invokeMethod('update', {
      ...snapshot.data,
      'revision': repository.operations.length,
    });
    repository.dispose();
    await control.invokeMethod('complete', timetableApplied);
  } catch (_) {
    await control.invokeMethod('complete', false);
  }
}

Future<void> syncBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const control = MethodChannel('app.calendula/background');
  final repository = SyncRepository(legacy: EncryptedEventRepository());
  try {
    await repository.load();
    if (repository.mode == 'webdav') await repository.synchronize();
    if (repository.syncError != null) {
      throw StateError('Cloud sync is waiting for its retry.');
    }
    final bytes = await control.invokeMethod<Uint8List>('liveCache');
    final feed = bytes == null ? null : LiveFeed.decode(bytes);
    final snapshot = await buildWidgetSnapshot(await repository.load(), feed);
    await const MethodChannel('app.calendula/widget').invokeMethod('update', {
      ...snapshot.data,
      'revision': repository.operations.length,
    });
    await control.invokeMethod('complete', true);
  } catch (_) {
    await control.invokeMethod('complete', false);
  } finally {
    repository.dispose();
  }
}
