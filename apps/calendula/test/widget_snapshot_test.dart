import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:calendula/calendar.dart';
import 'package:calendula/widget_snapshot.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test('All-day entries do not hide a later departure outside the first three displayed events', () async {
    final events = [
      for (var i = 0; i < 3; i++)
        CalendarEvent(
          id: 'day-$i',
          title: 'All day $i',
          allDay: true,
          start: DateTime.utc(2026, 10, 4, 22),
          end: DateTime.utc(2026, 10, 5, 22),
        ),
      CalendarEvent(
        id: 'journey',
        title: 'Cinema',
        start: DateTime.utc(2026, 10, 5, 12),
        end: DateTime.utc(2026, 10, 5, 13),
        travelMinutes: 45,
        bufferMinutes: 10,
      ),
    ];
    final snapshot = await buildWidgetSnapshot(
      events,
      null,
      at: DateTime.utc(2026, 10, 5, 10),
    );
    final day = snapshot.data['days']['2026-10-05'];
    expect(day['leave'], 'Leave 13:05 · manual estimate');
    expect(day['events'], contains('+1 more'));
    final late = await buildWidgetSnapshot(
      events,
      null,
      at: DateTime.utc(2026, 10, 5, 14),
    );
    expect(
      late.data['days']['2026-10-05']['leave'],
      'Your day, a little clearer.',
    );
  });
}
