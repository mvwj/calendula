import 'dart:math';

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'main.dart' show forest, orange, muted, categoryColor;

/// A wall-clock scale: daylight-saving days still display their local hours.
class DayTimeline extends StatelessWidget {
  final DateTime day, now;
  final List<CalendarEvent> events;
  final void Function(CalendarEvent)? onEvent;
  const DayTimeline({
    super.key,
    required this.day,
    required this.now,
    required this.events,
    this.onEvent,
  });
  @override
  Widget build(BuildContext context) {
    final timed = events.where((e) => !e.allDay).toList();
    const begin = 0, finish = 24;
    const height = 360.0;
    double y(DateTime t) {
      if (dayKey(t).compareTo(dayKey(day)) < 0) return 0;
      if (dayKey(t).compareTo(dayKey(day)) > 0) return height;
      return ((t.hour * 60 + t.minute - begin * 60) /
              ((finish - begin) * 60) *
              height)
          .clamp(0, height);
    }

    final local = tz.TZDateTime.from(now, prague);
    return Container(
      key: const ValueKey('day-timeline'),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SizedBox(
        height: height + 14,
        child: Stack(
          children: [
            for (var hour = begin; hour <= finish; hour += 2)
              Positioned(
                left: 0,
                right: 0,
                top: (hour - begin) / (finish - begin) * height,
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${hour.toString().padLeft(2, '0')}:00',
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                    ),
                    const Expanded(
                      child: Divider(height: 1, color: Color(0xFFE5E9E2)),
                    ),
                  ],
                ),
              ),
            for (var i = 0; i < timed.length; i++)
              Positioned(
                left:
                    53.0 +
                    (i.isOdd &&
                            i > 0 &&
                            timed[i].start.isBefore(timed[i - 1].end)
                        ? 16
                        : 0),
                right: 2,
                top: y(timed[i].localStart),
                height: max(24, y(timed[i].localEnd) - y(timed[i].localStart)),
                child: Tooltip(
                  message:
                      '${timed[i].title} · ${clock(timed[i].localStart)}–${clock(timed[i].localEnd)}',
                  child: Material(
                    color: categoryColor(timed[i].category),
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      onTap: onEvent == null ? null : () => onEvent!(timed[i]),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        child: Text(
                          timed[i].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: forest, fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (dayKey(local) == dayKey(day))
              Positioned(
                key: const ValueKey('timeline-now'),
                left: 0,
                right: 0,
                top: y(local),
                child: Semantics(
                  label: 'Current time ${clock(local)}',
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        decoration: BoxDecoration(
                          color: orange,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          clock(local),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 10,
                            color: forest,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: orange,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const Expanded(
                        child: Divider(height: 2, thickness: 2, color: orange),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
