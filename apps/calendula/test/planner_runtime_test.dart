import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:calendula/network_router.dart';
import 'package:calendula/planner_runtime.dart';

class FakeEngine extends NetworkEngine {
  final Completer<void> ready = Completer();
  int loads = 0, disposals = 0;
  @override
  Future<void> load(String? path) {
    loads++;
    return ready.future;
  }

  @override
  void dispose() {
    disposals++;
  }
}

void main() {
  test('Simultaneous screens share startup; reopening reuses it; file revision keeps active old screens safe', () async {
    final dir = await Directory.systemTemp.createTemp('calendula-pool-');
    final file = File('${dir.path}/common.gz');
    final engines = <FakeEngine>[];
    final pool = PlannerRuntime(
      createEngine: () {
        final e = FakeEngine();
        engines.add(e);
        return e;
      },
    );
    try {
      await file.writeAsString('public-v1');
      final first = pool.acquire(file.path), second = pool.acquire(file.path);
      await Future<void>.delayed(Duration.zero);
      while (engines.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      engines.single.ready.complete();
      final one = await first, two = await second;
      expect(identical(one.engine, two.engine), true);
      expect(engines.single.loads, 1);
      two.release();
      final reopened = await pool.acquire(file.path);
      expect(reopened.engine, same(one.engine));
      reopened.release();
      await file.writeAsString('public-revision-v2');
      final next = pool.acquire(file.path);
      while (engines.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      engines.last.ready.complete();
      final newLease = await next;
      expect(newLease.engine, isNot(same(one.engine)));
      expect(engines.first.disposals, 0);
      one.release();
      one.release();
      expect(engines.first.disposals, 1);
      newLease.release();
      expect(engines.last.disposals, 0);
      pool.dispose();
      expect(engines.last.disposals, 1);
    } finally {
      pool.dispose();
      await dir.delete(recursive: true);
    }
  });
  test('Failed startup is released and a later open can retry without a stale worker', () async {
    final engines = <FakeEngine>[];
    final pool = PlannerRuntime(
      createEngine: () {
        final e = FakeEngine();
        engines.add(e);
        return e;
      },
    );
    addTearDown(pool.dispose);
    final failed = pool.acquire(null);
    final assertion = expectLater(failed, throwsStateError);
    engines.single.ready.completeError(StateError('Synthetic startup failure'));
    await assertion;
    expect(engines.single.disposals, 1);
    final retry = pool.acquire(null);
    engines.last.ready.complete();
    final lease = await retry;
    expect(engines.length, 2);
    lease.release();
  });
}
