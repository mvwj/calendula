import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'calendar.dart';
import 'sync.dart';

/// Explicit owner-authorized cloud check. Logs no credentials or real events.
/// Mutations are restricted to a freshly generated, labelled diagnostic event.
Future<Map<String, dynamic>> cloudSyncCheck(Map<String, dynamic> config) async {
  final repo = SyncRepository(legacy: EncryptedEventRepository());
  final report = <String, dynamic>{'platform': Platform.operatingSystem};
  try {
    var events = await repo.load();
    report['configured'] = repo.profile != null && repo.mode == 'webdav';
    if (report['configured'] != true) return report;
    final fingerprint = await Sha256().hash(
      utf8.encode('${repo.profile!.calendarId}:${repo.profile!.key}'),
    );
    report['pairFingerprint'] = fingerprint.bytes
        .take(10)
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
    report['host'] = Uri.parse(repo.url).host;
    final action = config['action'] ?? 'inspect';
    final id = config['id'] as String? ?? '';
    if (action != 'inspect' &&
        !RegExp(r'^calendula-sync-check-[A-Za-z0-9_-]{24}$').hasMatch(id)) {
      throw const FormatException(
        'Only a synthetic diagnostic event may change.',
      );
    }
    if (action == 'add') {
      if (events.any((e) => e.id == id)) {
        throw StateError('Probe already exists');
      }
      await repo.save([
        ...events,
        CalendarEvent(
          id: id,
          title: 'Calendula sync check · synthetic',
          start: DateTime.utc(2026, 10, 6, 10),
          end: DateTime.utc(2026, 10, 6, 11),
          notes: 'Temporary device verification',
        ),
      ]);
    } else if (action == 'edit' || action == 'remove') {
      final probe = events.where((e) => e.id == id).toList();
      if (probe.length != 1 ||
          probe.single.title != 'Calendula sync check · synthetic') {
        throw StateError(
          'Labelled probe is unavailable; personal events were kept',
        );
      }
      await repo.save(
        action == 'remove'
            ? events.where((e) => e.id != id).toList()
            : events
                  .map(
                    (e) => e.id == id
                        ? CalendarEvent.fromJson({
                            ...e.toJson(),
                            'room': 'Android cloud edit',
                          })
                        : e,
                  )
                  .toList(),
      );
    } else if (action != 'inspect' && action != 'verify') {
      throw const FormatException('Unknown diagnostic action');
    }
    // Respect the persisted minimum and provider backoff, including other app processes.
    await repo.synchronize();
    events = await repo.reloadFromDisk();
    final found = events.where((e) => e.id == id).toList();
    report.addAll({
      'syncError': repo.syncError,
      'lastSync': repo.lastSync?.toUtc().toIso8601String(),
      'retryAt': repo.retryAt?.toUtc().toIso8601String(),
      'eventCount': events.length,
      'probePresent': found.isNotEmpty,
      'probeEdited':
          found.isNotEmpty && found.single.room == 'Android cloud edit',
      'conflictCount': repo.document.conflicts.length,
      'pendingOperations': repo.operations
          .where((o) => !repo.published.contains(o.id))
          .length,
    });
  } catch (error) {
    report['errorType'] = error.runtimeType.toString();
  } finally {
    repo.dispose();
  }
  return report;
}

Future<void> windowsCloudSyncCheck(List<String> args) async {
  runApp(const SizedBox.shrink());
  final configFile = args
      .firstWhere((v) => v.startsWith('--check-config='))
      .substring(15);
  final config =
      jsonDecode(await File(configFile).readAsString()) as Map<String, dynamic>;
  final report = await cloudSyncCheck(config);
  await File('$configFile.report.json')
      .writeAsString(jsonEncode(report), flush: true);
  exit(
    report['errorType'] == null &&
            report['configured'] == true &&
            report['syncError'] == null
        ? 0
        : 1,
  );
}

Future<void> androidCloudSyncCheck() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const channel = MethodChannel('app.calendula/sync-check');
  final encoded = await channel.invokeMethod<String>('config');
  final config =
      jsonDecode(utf8.decode(base64Decode(encoded!))) as Map<String, dynamic>;
  final report = await cloudSyncCheck(config);
  final ok =
      report['errorType'] == null &&
      report['configured'] == true &&
      report['syncError'] == null;
  await channel.invokeMethod(
    'complete',
    '${ok ? 'PASS' : 'FAIL'}: ${jsonEncode(report)}',
  );
}
