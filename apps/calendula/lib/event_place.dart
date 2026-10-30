import 'calendar.dart';
import 'place_search.dart';

const sessionTypes = [
  '',
  'Lecture',
  'Practice',
  'Seminar',
  'Lab',
  'Exam',
  'Other',
];

/// Only explicit source labels are recognised; a room/course code is not a type.
String sessionTypeFrom(String text) => switch (foldPlace(text.trim())) {
  'lecture' || 'prednaska' || 'prednasky' => 'Lecture',
  'practice' ||
  'practical' ||
  'tutorial' ||
  'cviceni' ||
  'praktikum' => 'Practice',
  'seminar' => 'Seminar',
  'lab' || 'laboratory' || 'laborator' => 'Lab',
  'exam' || 'zkouska' => 'Exam',
  'other' => 'Other',
  _ => '',
};

String explicitTitleType(String title) {
  final marker = RegExp(r'\(([^()]*)\)\s*$').firstMatch(title);
  return marker == null ? '' : sessionTypeFrom(marker[1]!);
}

const mffBuildingSource =
    'https://www.mff.cuni.cz/cs/vnitrni-zalezitosti/budovy-a-arealy/mala-strana';
const mffRoomSource =
    'https://cs.mff.cuni.cz/cs/o-nas/poslucharny-a-ucebny/poslucharny-s3-s4-s5-s9';
const mffComputerSource =
    'https://cs.mff.cuni.cz/cs/o-nas/pocitacove-ucebny/pocitacove-ucebny-sw1-su1-sw2-su2';

/// Public directory, checked 2026-10-08. Exact room allowlist, no prefix guesses.
CalendarEvent enrichStudyPlace(CalendarEvent event, {bool mff = true}) {
  if (!mff || event.category != 'Study') return event;
  final room = event.room.trim().toUpperCase();
  if (!const {
    'S1',
    'S3',
    'S4',
    'S5',
    'S6',
    'S7',
    'S8',
    'S9',
    'S10',
    'S11',
    'SU1',
    'SU2',
    'SW1',
    'SW2',
  }.contains(room)) {
    return event;
  }
  // Preserve a user's location override as one coherent place.
  if (event.address.isNotEmpty) return event;
  final floor = switch (room) {
    'S3' || 'S4' => '3',
    'S5' => '2',
    'S9' => '1',
    'SU2' || 'SW2' => 'Ground',
    _ => '',
  };
  return CalendarEvent.fromJson({
    ...event.toJson(),
    'venue': event.venue.isEmpty
        ? 'Charles University · MFF Malá Strana'
        : event.venue,
    'address': 'Malostranské náměstí 2/25, Praha 1',
    'floor': event.floor.isEmpty ? floor : event.floor,
    'locationSource': floor.isEmpty
        ? mffBuildingSource
        : room == 'SU2' || room == 'SW2'
        ? mffComputerSource
        : mffRoomSource,
  });
}

/// Older SIS imports on this installation used the MFF room directory. Other
/// calendar entries must never acquire a building just because they say S3.
CalendarEvent effectiveEvent(CalendarEvent event) =>
    event.placeProfile != 'none' &&
        event.id.startsWith('sis:') &&
        event.notes.contains('SIS CSV')
    ? enrichStudyPlace(event)
    : event;

String eventDestination(CalendarEvent original) {
  final event = effectiveEvent(original);
  return event.address.isNotEmpty
      ? event.address
      : event.destinationStop.isNotEmpty
      ? event.destinationStop
      : event.venue;
}

String placeSourceLabel(String source) {
  final host = Uri.tryParse(source)?.host;
  if (host == 'www.mff.cuni.cz' || host == 'cs.mff.cuni.cz') {
    return 'MFF room directory';
  }
  return source == 'User'
      ? 'Entered by you'
      : source == 'SIS CSV'
      ? 'SIS timetable'
      : 'Imported schedule';
}

String? meetingSeries(String id) {
  if (!id.startsWith('sis:')) return null;
  final split = id.lastIndexOf(':');
  return split <= 4 ? null : id.substring(0, split);
}

/// Learn confirmed metadata from exact SIS meeting IDs, never just course title.
/// Conflicting locations/types are left for review instead of choosing a winner.
Map<String, CalendarEvent> reusableMeetingDetails(
  Iterable<CalendarEvent> events,
) {
  final grouped = <String, List<CalendarEvent>>{};
  for (final e in events) {
    final series = meetingSeries(e.id);
    if (series != null) (grouped[series] ??= []).add(e);
  }
  return {
    for (final entry in grouped.entries)
      entry.key: _meetingDetails(entry.value),
  };
}

CalendarEvent _meetingDetails(List<CalendarEvent> events) {
  final addresses = events
          .map((e) => e.address)
          .where((s) => s.isNotEmpty)
          .toSet(),
      types = events
          .map((e) => e.sessionType)
          .where((s) => s.isNotEmpty)
          .toSet();
  final place =
      events.where((e) => e.address.isNotEmpty).firstOrNull ?? events.first;
  return CalendarEvent.fromJson({
    ...place.toJson(),
    'sessionType': types.length == 1 ? types.single : '',
    'address': addresses.length == 1 ? addresses.single : '',
    'venue': addresses.length == 1 ? place.venue : '',
    'floor': addresses.length == 1 ? place.floor : '',
    'locationSource': addresses.length == 1 ? place.locationSource : '',
  });
}
