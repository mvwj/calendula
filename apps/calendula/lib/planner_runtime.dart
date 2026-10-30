import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'address_index.dart';
import 'network_router.dart';

class _EngineEntry {
  final String revision;
  final NetworkEngine engine;
  final Future<void> loading;
  int users = 0;
  bool retired = false, disposed = false;
  _EngineEntry(this.revision, this.engine, this.loading);
  void retire() {
    retired = true;
    collect();
  }

  void collect() {
    if (retired && users == 0 && !disposed) {
      disposed = true;
      engine.dispose();
    }
  }
}

class PlannerLease {
  final _EngineEntry _entry;
  bool _released = false;
  PlannerLease._(this._entry);
  NetworkEngine get engine => _entry.engine;
  void release() {
    if (_released) return;
    _released = true;
    _entry.users--;
    _entry.collect();
  }
}

/// Keeps one common timetable worker warm for the UI process. A new file
/// revision gets a new worker; open planners finish on their leased revision.
/// Private endpoints/live input are still sent separately on every query.
class PlannerRuntime {
  static final shared = PlannerRuntime();
  final NetworkEngine Function() createEngine;
  _EngineEntry? _current;
  bool _closed = false;
  PlannerRuntime({NetworkEngine Function()? createEngine})
    : createEngine = createEngine ?? NetworkEngine.new;

  Future<PlannerLease> acquire(String? path) async {
    final stat = path == null ? null : await File(path).stat();
    final revision = stat == null || stat.type == FileSystemEntityType.notFound
        ? 'bundled'
        : '$path:${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    if (_closed) throw StateError('Planner runtime closed.');
    var entry = _current;
    if (entry == null || entry.revision != revision) {
      final engine = createEngine();
      final loading = engine.load(path);
      loading.ignore();
      final previous = entry;
      entry = _EngineEntry(revision, engine, loading);
      _current = entry;
      previous?.retire();
    }
    entry.users++;
    final lease = PlannerLease._(entry);
    try {
      await entry.loading;
      if (_closed) throw StateError('Planner runtime closed.');
      return lease;
    } catch (_) {
      if (identical(_current, entry)) _current = null;
      entry.retire();
      lease.release();
      rethrow;
    }
  }

  void dispose() {
    _closed = true;
    _current?.retire();
    _current = null;
  }
}

Future<String> plannerCachePath() async =>
    '${(await getApplicationSupportDirectory()).path}/public-network.json.gz';

/// Called on normal app open/resume and after a common timetable update.
/// Only local common files are touched; UI/calendar initialization does not wait.
Future<void> warmNetworkPlanner() async {
  final addresses = AddressIndex.load();
  addresses.ignore();
  PlannerLease? lease;
  try {
    lease = await PlannerRuntime.shared.acquire(await plannerCachePath());
    await addresses;
  } catch (_) {
    // A planner still reports load errors through its normal screen.
  } finally {
    lease?.release();
  }
}
