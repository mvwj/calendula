import 'package:timezone/timezone.dart' as tz;
import 'package:intl/intl.dart';

import 'address_index.dart';
import 'calendar.dart';
import 'event_journey.dart';
import 'event_place.dart';
import 'journey_preferences.dart';
import 'network_router.dart';
import 'planner_runtime.dart';
import 'transit.dart';

class WidgetSnapshot {
  final Map<String, dynamic> data;
  final Map<String, NetworkJourney> journeys;
  final Map<String, EventJourneyPlan> plans;
  WidgetSnapshot(this.data, this.journeys, [this.plans = const {}]);
}

Future<WidgetSnapshot> buildWidgetSnapshot(
  List<CalendarEvent> originalEvents,
  LiveFeed? live, {
  NetworkEngine? routing,
  AddressIndex? addresses,
  JourneyPreferences? preferences,
  OriginFix? originFix,
  bool includeDepartNow = false,
  DateTime? visibleDay,
  DateTime? at,
  void Function(String, EventJourneyPlan)? onPlan,
}) async {
  final events = originalEvents.map(effectiveEvent).toList(),
      now = at == null ? localNow() : tz.TZDateTime.from(at, prague),
      plans = <String, EventJourneyPlan>{};
  final candidates =
      events
          .where(
            (e) =>
                !e.allDay &&
                e.end.isAfter(now) &&
                (e.start.isBefore(now.add(const Duration(hours: 48))) ||
                    visibleDay != null &&
                        dayKey(e.localStart) == dayKey(visibleDay)),
          )
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  PlannerLease? lease;
  final currentRoutes = <String, NetworkJourney?>{};
  try {
    if (candidates.isNotEmpty) {
      final settings =
          preferences ?? await const JourneyPreferenceStore().load();
      final fix =
          originFix ??
          (settings.mode == OriginMode.current
              ? await const JourneyPreferenceStore().lastLocation()
              : null);
      // Missing prerequisites stay visible without loading the heavy graph.
      final ready = candidates.any(
        (e) =>
            eventDestination(e).isNotEmpty &&
            (startingPointText(e, settings).isNotEmpty ||
                settings.mode == OriginMode.current &&
                    fix?.usableAt(now) == true),
      );
      NetworkEngine? engine = routing;
      AddressIndex? addressData = addresses;
      if (ready) {
        final addressLoading = addressData == null ? AddressIndex.load() : null;
        if (engine == null) {
          lease = await PlannerRuntime.shared.acquire(await plannerCachePath());
          engine = lease.engine;
        }
        addressData ??= await addressLoading;
      }
      for (final e in candidates) {
        if (engine == null || !ready) {
          plans[e.id] = EventJourneyPlan(
            status: eventDestination(e).isEmpty
                ? 'Add an exact destination address'
                : 'Set home or open the app for GPS',
            origin: settings.address,
            calculatedAt: now,
            departNowChecked:
                includeDepartNow &&
                dayKey(e.localStart) == dayKey(visibleDay ?? now),
          );
          onPlan?.call(e.id, plans[e.id]!);
          continue;
        }
        try {
          plans[e.id] = await planEventJourney(
            e,
            engine,
            addressData,
            settings,
            live: live,
            now: now,
            fix: fix,
            includeDepartNow:
                includeDepartNow &&
                dayKey(e.localStart) == dayKey(visibleDay ?? now),
            departNowCache: currentRoutes,
          );
        } catch (_) {
          plans[e.id] = EventJourneyPlan(
            status: 'Route unavailable · tap to replan',
            origin: settings.address,
            calculatedAt: now,
          );
        }
        onPlan?.call(e.id, plans[e.id]!);
      }
    }
  } catch (_) {
    for (final e in candidates) {
      plans[e.id] = EventJourneyPlan(
        status: 'Journey settings unavailable · tap to replan',
        origin: '',
        calculatedAt: now,
      );
    }
  } finally {
    lease?.release();
  }
  final journeys = <String, NetworkJourney>{
    for (final entry in plans.entries)
      if (entry.value.planned != null) entry.key: entry.value.planned!,
  };
  String locationLine(CalendarEvent e) {
    final value = [
      e.sessionType,
      e.room.isEmpty ? '' : 'Room ${e.room}',
      e.address.isEmpty ? e.venue : e.address,
    ].where((s) => s.isNotEmpty).join(' · ');
    return value.length > 140 ? value.substring(0, 140) : value;
  }

  Map<String, dynamic> day(DateTime date) {
    final dayEvents = eventsOnDay(
      events,
      date,
    ).where((e) => dayKey(date) != dayKey(now) || e.end.isAfter(now)).toList();
    final next = dayEvents
        .where((e) => !e.allDay && e.end.isAfter(now))
        .firstOrNull;
    String leave = 'Your day, a little clearer.',
        note = 'Updated ${clock(now)} · tap to open',
        current = '';
    if (next != null) {
      final plan = plans[next.id];
      leave =
          plan?.leaveLine(next) ??
          (next.travelMinutes > 0
              ? 'Leave ${clock(next.leaveAt)} · manual estimate'
              : 'Open Calendula to calculate departure');
      if (plan != null) {
        note =
            '${plan.status} · arrive ${next.bufferMinutes} min early'
            '${plan.origin.isEmpty ? '' : ' · from ${plan.origin}'} · ${clock(now)}';
        if (includeDepartNow && dayKey(date) == dayKey(visibleDay ?? now)) {
          current = '${plan.nowLine(next)} · checked ${clock(now)}';
        }
      }
    }
    return {
      'heading': DateFormat('EEEE, d MMM').format(date),
      'events':
          dayEvents
              .take(3)
              .map(
                (e) =>
                    '${e.allDay ? 'All day' : clock(e.localStart)}  ${e.title.length > 80 ? e.title.substring(0, 80) : e.title}'
                    '\n${locationLine(e)}',
              )
              .join('\n\n') +
          (dayEvents.length > 3
              ? '\n\n+${dayEvents.length - 3} more · tap to open'
              : ''),
      'leave': leave,
      'note': note,
      'departNow': current,
      'nowAt': current.isEmpty ? 0 : now.millisecondsSinceEpoch,
    };
  }

  final days = {
    for (var i = 0; i < 14; i++)
      dayKey(DateTime(now.year, now.month, now.day + i)): day(
        DateTime(now.year, now.month, now.day + i),
      ),
  };
  return WidgetSnapshot(
    {
      'date': dayKey(now),
      'calculatedAt': now.millisecondsSinceEpoch,
      'liveGenerated': live?.generated.millisecondsSinceEpoch ?? 0,
      'days': days,
      'upcoming': [
        for (final e
            in (events
                    .where(
                      (e) =>
                          !e.allDay &&
                          e.end.isAfter(now) &&
                          e.start.isBefore(now.add(const Duration(days: 14))),
                    )
                    .toList()
                  ..sort((a, b) => a.start.compareTo(b.start)))
                .take(300))
          [
            (journeys[e.id]?.departure ?? e.leaveAt).millisecondsSinceEpoch,
            e.start.add(const Duration(minutes: 15)).millisecondsSinceEpoch,
          ],
      ],
      ...days[dayKey(now)]!,
    },
    journeys,
    plans,
  );
}
