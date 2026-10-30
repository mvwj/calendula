import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeEvent, localToIso, dayKey, eventsOnDay, departurePlan, conflicts, parseCsv, parseIcs, parseImport, extractText, exportIcs, isDuplicate } from '../src/calendar.mjs';

const event = (patch = {}) => normalizeEvent({ title:'Lecture', start:'2026-10-03T09:30', end:'2026-10-03T11:00', address:'Example 12, Prague', travelMinutes:32, bufferMinutes:10, prepMinutes:15, ...patch });
test('Prague local time becomes UTC, independent of host time zone', () => {
  assert.equal(localToIso('2026-10-03T09:30','Europe/Prague'),'2026-10-03T07:30:00.000Z');
  assert.equal(localToIso('2026-12-03T09:30','Europe/Prague'),'2026-12-03T08:30:00.000Z');
});
test('DST gap is rejected instead of silently moving the event', () => assert.throws(() => localToIso('2026-03-29T02:30','Europe/Prague')));
test('DST repeated time requires explicit offset', () => {
  assert.throws(() => localToIso('2026-10-25T02:30','Europe/Prague'));
  assert.equal(event({ start:'2026-10-25T02:30:00+02:00',end:'2026-10-25T02:30:00+01:00' }).start,'2026-10-25T00:30:00.000Z');
});
test('nonexistent calendar date is rejected for local and offset times', () => {
  assert.throws(() => localToIso('2026-02-30T12:00'));
  assert.throws(() => event({ start:'2026-02-30T12:00:00Z' }));
});
test('invalid event duration and negative route estimates are rejected', () => {
  assert.throws(() => event({ end:'2026-10-03T09:00' }));
  assert.throws(() => event({ travelMinutes:-1 }));
  assert.throws(() => event({ bufferMinutes:Infinity }));
});
test('departure includes door-to-door estimate, arrival buffer and separate preparation', () => {
  const p=departurePlan(event());
  assert.equal(p.targetArrival,'2026-10-03T07:20:00.000Z');
  assert.equal(p.leaveAt,'2026-10-03T06:48:00.000Z');
  assert.equal(p.prepareAt,'2026-10-03T06:33:00.000Z');
  assert.equal(p.kind,'manual-estimate');
});
test('no invented travel time for missing address or estimate', () => {
  assert.equal(departurePlan(event({ address:'' })),null);
  assert.equal(departurePlan(event({ travelMinutes:null })),null);
});
test('departure can be on the previous day', () => assert.equal(dayKey(departurePlan(event({ start:'2026-10-03T00:10',end:'2026-10-03T01:00' })).leaveAt),'2026-10-02'));
test('overnight events appear on both days, midnight ending does not extend into next day', () => {
  const overnight=event({ start:'2026-10-03T23:30',end:'2026-10-04T01:00' });
  assert.equal(eventsOnDay([overnight],'2026-10-04').length,1);
  const midnight=event({ start:'2026-10-03T23:30',end:'2026-10-04T00:00' });
  assert.equal(eventsOnDay([midnight],'2026-10-04').length,0);
});
test('touching events do not conflict, overlapping events do', () => {
  const a=event(), b=event({ start:'2026-10-03T11:00',end:'2026-10-03T12:00' });
  assert.equal(conflicts([a,b]).length,0);
  assert.equal(conflicts([a,event({ start:'2026-10-03T10:59',end:'2026-10-03T12:00' })]).length,1);
});
test('CSV supports quoted commas, quotes and newlines', () => {
  const result=parseCsv('title,start,end,address,notes\r\n"A, B",2026-10-03T09:30,2026-10-03T11:00,"Street, Prague","Line 1\nLine ""2"""');
  assert.equal(result.events.length,1); assert.equal(result.events[0].notes,'Line 1\nLine "2"');
});
test('CSV accepts BOM, semicolon and Russian headers but reports broken records', () => {
  const result=parseCsv('\uFEFFназвание;начало;окончание\nLecture;2026-10-03T09:30;2026-10-03T11:00\nBroken;bad;bad');
  assert.equal(result.events.length,1); assert.equal(result.warnings.length,1);
});
test('CSV missing required columns or unmatched quotes is rejected', () => {
  assert.throws(() => parseCsv('title,address\nA,B'));
  assert.throws(() => parseCsv('title,start,end\n"unclosed'));
});
const ics = body => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n${body}\r\nEND:VEVENT\r\nEND:VCALENDAR`;
test('ICS reads TZID, folded title and escaped content', () => {
  const result=parseIcs(ics('UID:lecture-1\r\nSUMMARY:History of\r\n  architecture\r\nDTSTART;TZID=Europe/Prague:20261003T093000\r\nDTEND;TZID=Europe/Prague:20261003T110000\r\nLOCATION:Example\\, Prague\r\nDESCRIPTION:First\\nSecond'));
  assert.equal(result.events[0].title,'History of architecture');
  assert.equal(result.events[0].address,'Example, Prague');
  assert.equal(result.events[0].start,'2026-10-03T07:30:00.000Z');
});
test('ICS does not silently flatten recurrence or all-day semantics', () => {
  for (const special of ['RRULE:FREQ=WEEKLY','RDATE:20261004T093000Z','EXDATE:20261003T093000Z','RECURRENCE-ID:20261003T093000Z']) {
    const result=parseIcs(ics(`SUMMARY:A\nDTSTART:20261003T093000Z\nDTEND:20261003T110000Z\n${special}`));
    assert.equal(result.events.length,0); assert.equal(result.warnings.length,1);
  }
  const result=parseIcs(ics('SUMMARY:A\nDTSTART;VALUE=DATE:20261003\nDTEND;VALUE=DATE:20261004'));
  assert.equal(result.events.length,0); assert.equal(result.warnings.length,1);
});
test('cancelled ICS events are reported, not added', () => {
  const result=parseIcs(ics('SUMMARY:A\nDTSTART:20261003T093000Z\nDTEND:20261003T110000Z\nSTATUS:CANCELLED'));
  assert.equal(result.events.length,0); assert.equal(result.warnings.length,1);
});
test('ICS export round trips UTF-8, punctuation and long folded lines', () => {
  const original=event({ title:'Архитектура, дизайн; '+ 'č'.repeat(150),notes:'A\nB\\C' });
  const text=exportIcs([original]);
  for (const line of text.split('\r\n')) assert.ok(Buffer.byteLength(line) <= 75);
  const result=parseIcs(text);
  assert.equal(result.events[0].title,original.title); assert.equal(result.events[0].start,original.start); assert.equal(result.events[0].notes,original.notes);
});
test('JSON import validates records and never trusts external internal IDs', () => {
  const original=event(); const result=parseImport(JSON.stringify({events:[original,{title:'broken'}]}),'json');
  assert.equal(result.events.length,1); assert.notEqual(result.events[0].id,original.id); assert.equal(result.warnings.length,1);
});
test('deduplication catches reimport and source UID matches', () => {
  const a=event({ sourceUid:'same' }); assert.ok(isDuplicate(event(),[a]));
  assert.ok(isDuplicate(event({ title:'Updated',sourceUid:'same' }),[a]));
  assert.equal(isDuplicate(event({ start:'2026-10-04T09:30',end:'2026-10-04T11:00' }),[a]),false);
});
test('English text extraction creates a reviewable structured event', () => {
  const result=extractText('Subject: Screening\nDate: 2026-10-03\nTime: 19:00–21:00\nAddress: Example 8, Prague\nRoom: Hall 2');
  assert.equal(result.draft.title,'Screening'); assert.equal(result.draft.room,'Hall 2'); assert.equal(result.warnings.length,0);
});
test('relative dates and missing end time are left for clarification', () => {
  const result=extractText('Subject: Meeting tomorrow\nTime: 19:00');
  assert.equal(result.draft.start,undefined); assert.ok(result.warnings.length);
});
test('unsupported format and oversized import are rejected', () => {
  assert.throws(() => parseImport('anything','pdf'));
  assert.throws(() => parseImport('a'.repeat(2*1024*1024+1),'json'));
});
