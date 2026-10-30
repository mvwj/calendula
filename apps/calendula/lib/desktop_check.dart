import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'desktop_tor.dart';
import 'transit.dart';
import 'network_router.dart';
import 'import_review_page.dart';
import 'calendar.dart';
import 'secure_json_store.dart';
import 'sync.dart';

class _CheckCalendar implements EventRepository {
  @override
  Future<List<CalendarEvent>> load() async => [];
  @override
  Future<void> save(List<CalendarEvent> events) async {}
}

/// Explicit command-line integration check. Uses public fixtures, never a calendar.
Future<void> desktopCheck() async {
  runApp(const SizedBox.shrink());
  final root = File(Platform.resolvedExecutable).parent;
  final report = <String, dynamic>{
    'version': '0.2.4',
    'calendarRead': false,
    'gpsRead': false,
  };
  var passed = false;
  final engine = NetworkEngine();
  const secure = FlutterSecureStorage();
  const probe = 'calendula.integration-test.storage';
  const probeValue = 'local-roundtrip · Praha · Календула';
  try {
    await secure.write(key: probe, value: probeValue);
    report['secureStorage'] = await secure.read(key: probe) == probeValue;
    await secure.delete(key: probe);
    final temp = await Directory.systemTemp.createTemp(
      'calendula-desktop-check-',
    );
    final name = 'integration-${randomSyncId()}';
    final repo = SyncRepository(
      legacy: _CheckCalendar(),
      store: SecureJsonStore(name, directory: () async => temp),
      profileStorageKey: 'calendula.$name.profile.v1',
      manageBackground: false,
    );
    try {
      await repo.load();
      await repo.save([
        CalendarEvent(
          id: 'synthetic-check',
          title: 'Synthetic encrypted check',
          start: DateTime.utc(2026, 10, 5, 10),
          end: DateTime.utc(2026, 10, 5, 11),
        ),
      ]);
      report['syncVault'] =
          (await repo.reloadFromDisk()).single.id == 'synthetic-check' &&
          !(await File(
            '${temp.path}/$name.vault',
          ).readAsString()).contains('Synthetic');
    } finally {
      repo.dispose();
      await secure.delete(key: 'calendula.$name.key.v1');
      final prefix =
          '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}calendula-desktop-check-';
      if (temp.absolute.path.startsWith(prefix) &&
          !await FileSystemEntity.isLink(temp.path)) {
        await temp.delete(recursive: true);
      }
    }
    final check = await DesktopTor.instance.check();
    report['torVerified'] = true;
    report['exitIp'] = check['ip'];
    final live = await LiveFeed.download();
    report['publicTripUpdates'] = live.trips.length;
    report['feedGenerated'] = live.generated.toIso8601String();
    await engine.load(null);
    final journeys = <Map<String, dynamic>>[];
    for (final pair in [
      ('Terminál 1', 'Háje'),
      ('Sídliště Barrandov', 'Černý Most'),
      ('Zoo Praha - Troja', 'Nemocnice Motol'),
    ]) {
      final result = await engine.route(
        pair.$1,
        pair.$2,
        DateTime.utc(2026, 10, 5, 6),
        arriveBy: false,
      );
      if (result == null) {
        throw StateError('Public benchmark connection unavailable.');
      }
      journeys.add({
        'from': pair.$1,
        'to': pair.$2,
        'changes': result.changes,
        'minutes': result.arrival.difference(result.departure).inMinutes,
      });
    }
    report['publicBenchmarks'] = journeys;
    final pdf = await importDocument(
      'import-example.pdf',
      await File('${root.path}/import-example.pdf').readAsBytes(),
      DateTime(2026, 10, 1),
      DateTime(2026, 10, 31),
    );
    report['pdfEvents'] = pdf.events.length;
    passed =
        report['secureStorage'] == true &&
        report['syncVault'] == true &&
        pdf.events.length == 1;
  } catch (e) {
    report['errorType'] = e.runtimeType.toString();
  } finally {
    engine.dispose();
    await secure.delete(key: probe);
    await DesktopTor.instance.stop();
  }
  report['passed'] = passed;
  await File('${root.path}/desktop-check.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  exit(passed ? 0 : 1);
}
