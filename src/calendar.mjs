export const DEFAULT_ZONE = 'Europe/Prague';
const categories = new Set(['study', 'personal', 'culture', 'work']);
const finite = (value, name, max = 1440) => {
  const number = Number(value ?? 0);
  if (!Number.isFinite(number) || number < 0 || number > max) throw new Error(`${name}: enter a number from 0 to ${max}`);
  return number;
};
export function partsInZone(value, zone = DEFAULT_ZONE) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(value));
  return Object.fromEntries(parts.filter(p => p.type !== 'literal').map(p => [p.type, p.value]));
}
export function dayKey(value, zone = DEFAULT_ZONE) {
  const p = partsInZone(value, zone); return `${p.year}-${p.month}-${p.day}`;
}
export function localInput(value, zone = DEFAULT_ZONE) {
  const p = partsInZone(value, zone); return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
}
export function localToIso(value, zone = DEFAULT_ZONE) {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!match) throw new Error('Enter a date and time: YYYY-MM-DD HH:MM');
  const [, y, mo, d, h, mi, s = '00'] = match;
  const wall = Date.UTC(+y, +mo - 1, +d, +h, +mi, +s);
  const offsets = new Set();
  for (const shift of [-48, -24, 0, 24, 48]) {
    const sample = wall + shift * 3600000;
    const p = partsInZone(sample, zone);
    offsets.add(Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - sample);
  }
  const possible = [...offsets].map(offset => wall - offset).filter(candidate => {
    const p = partsInZone(candidate, zone);
    return p.year === y && p.month === mo && p.day === d && p.hour === h && p.minute === mi && p.second === s;
  });
  if (!possible.length) throw new Error('This date or time does not exist in the selected time zone');
  if (possible.length > 1) throw new Error('This time occurs twice during the clock change. Import a time with an explicit UTC offset');
  return new Date(possible[0]).toISOString();
}
function instant(value, zone) {
  const text = String(value ?? '');
  if (!/T/.test(text)) throw new Error('The time must include a date');
  if (!/(Z|[+-]\d{2}:?\d{2})$/i.test(text)) return localToIso(text, zone);
  const date = new Date(text);
  if (!Number.isFinite(date.getTime())) throw new Error('Could not read the date');
  // Date.parse нормализует 30 февраля: отдельно проверяем календарный день.
  const match = /^(\d{4})-(\d{2})-(\d{2})T/.exec(text);
  if (!match || +match[2] < 1 || +match[2] > 12 || +match[3] < 1 || +match[3] > new Date(Date.UTC(+match[1], +match[2], 0)).getUTCDate()) throw new Error('Invalid calendar date');
  return date.toISOString();
}
export function normalizeEvent(input, idFactory = () => globalThis.crypto.randomUUID()) {
  if (!input || typeof input !== 'object') throw new Error('Expected an event record');
  const title = String(input.title ?? '').trim();
  if (!title || title.length > 300) throw new Error('The title must contain 1 to 300 characters');
  const timeZone = String(input.timeZone || DEFAULT_ZONE);
  const start = instant(input.start, timeZone), end = instant(input.end, timeZone);
  if (new Date(end) <= new Date(start)) throw new Error('The end must be later than the start');
  return {
    id: String(input.id || idFactory()), title, start, end, timeZone,
    category: categories.has(input.category) ? input.category : 'personal',
    address: String(input.address || '').slice(0, 1000), venue: String(input.venue || '').slice(0, 300),
    room: String(input.room || '').slice(0, 100), floor: String(input.floor || '').slice(0, 100),
    notes: String(input.notes || '').slice(0, 10000), source: String(input.source || 'manual').slice(0, 300),
    sourceUid: String(input.sourceUid || '').slice(0, 1000),
    travelMinutes: input.travelMinutes === '' || input.travelMinutes == null ? null : finite(input.travelMinutes, 'Travel duration'),
    bufferMinutes: finite(input.bufferMinutes ?? 10, 'Arrival buffer'),
    prepMinutes: finite(input.prepMinutes ?? 0, 'Preparation time')
  };
}
export function departurePlan(event) {
  if (event.travelMinutes == null || !event.address.trim()) return null;
  const targetArrival = new Date(new Date(event.start).getTime() - event.bufferMinutes * 60000);
  const leaveAt = new Date(targetArrival.getTime() - event.travelMinutes * 60000);
  return { targetArrival: targetArrival.toISOString(), leaveAt: leaveAt.toISOString(), prepareAt: new Date(leaveAt.getTime() - event.prepMinutes * 60000).toISOString(), durationMinutes: event.travelMinutes, kind: 'manual-estimate' };
}
export function eventsOnDay(events, day, zone = DEFAULT_ZONE) {
  return events.filter(e => dayKey(e.start, zone) <= day && dayKey(new Date(new Date(e.end).getTime() - 1), zone) >= day).sort((a, b) => a.start.localeCompare(b.start));
}
export function conflicts(events) {
  const result = [];
  for (let i = 0; i < events.length; i++) for (let j = i + 1; j < events.length; j++) {
    if (events[i].start < events[j].end && events[j].start < events[i].end) result.push([events[i].id, events[j].id]);
  }
  return result;
}
export function isDuplicate(event, existing) {
  return existing.some(e => (event.sourceUid && e.sourceUid === event.sourceUid) || (e.title.trim().toLowerCase() === event.title.trim().toLowerCase() && e.start === event.start && e.address.trim().toLowerCase() === event.address.trim().toLowerCase()));
}
function collect(rows, source, timeZone) {
  const events = [], warnings = [];
  rows.forEach((row, index) => {
    try { events.push(normalizeEvent({ ...row, id: undefined, source, timeZone: row.timeZone || timeZone })); }
    catch (error) { warnings.push(`Record ${index + 1}: ${error.message}`); }
  });
  return { events, warnings };
}
export function parseCsv(text, timeZone = DEFAULT_ZONE) {
  text = text.replace(/^\uFEFF/, '');
  const first = text.split(/\r?\n/)[0];
  const delimiter = [';', ',', '\t'].sort((a,b) => first.split(b).length - first.split(a).length)[0];
  const rows = []; let row = [], value = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') { if (quoted && text[i+1] === '"') { value += '"'; i++; } else quoted = !quoted; }
    else if (c === delimiter && !quoted) { row.push(value); value = ''; }
    else if ((c === '\n' || c === '\r') && !quoted) { if (c === '\r' && text[i+1] === '\n') i++; row.push(value); if (row.some(v => v.trim())) rows.push(row); row = []; value = ''; }
    else value += c;
  }
  if (quoted) throw new Error('An unmatched quote was found in the CSV');
  row.push(value); if (row.some(v => v.trim())) rows.push(row);
  if (rows.length < 2) throw new Error('A header row and at least one event are required');
  const aliases = { 'название': 'title', 'начало': 'start', 'окончание': 'end', 'адрес': 'address', 'место': 'venue', 'аудитория': 'room', 'этаж': 'floor', 'заметки': 'notes', 'категория': 'category', 'путь': 'travelMinutes' };
  const headers = rows.shift().map(h => aliases[h.trim().toLowerCase()] || h.trim());
  if (!['title', 'start', 'end'].every(h => headers.includes(h))) throw new Error('CSV requires title, start and end columns (Russian equivalents also accepted)');
  return collect(rows.map(cells => Object.fromEntries(headers.map((h, i) => [h, cells[i] ?? '']))), 'CSV', timeZone);
}
const unescapeIcs = value => value.replace(/\\[nN]/g, '\n').replace(/\\([,;\\])/g, '$1');
function icsDate(property, zone) {
  const { value, params } = property;
  if (params.includes('VALUE=DATE') || /^\d{8}$/.test(value)) throw new Error('All-day event: support is planned for the native version');
  const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z)?$/.exec(value);
  if (!match) throw new Error('Unsupported ICS date');
  const [, y, mo, d, h, mi, s, z] = match;
  const local = `${y}-${mo}-${d}T${h}:${mi}:${s}`;
  const tzid = /TZID=([^;]+)/.exec(params)?.[1]?.replace(/^"|"$/g, '');
  return z ? instant(`${local}Z`, zone) : localToIso(local, tzid || zone);
}
export function parseIcs(text, zone = DEFAULT_ZONE) {
  if (!/BEGIN:VCALENDAR/i.test(text)) throw new Error('This is not an iCalendar file');
  const lines = text.replace(/\r?\n[ \t]/g, '').split(/\r?\n/);
  const events = [], warnings = []; let record = null, count = 0, nested = false;
  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') { record = {}; nested = false; count++; continue; }
    if (!record) continue;
    if (line === 'END:VEVENT') {
      try {
        if (record.RRULE || record.RDATE || record.EXDATE || record['RECURRENCE-ID']) throw new Error('Recurring event: a full recurrence parser is required');
        if (record.STATUS?.value === 'CANCELLED') throw new Error('Cancelled event skipped; the prototype does not automatically cancel existing records');
        if (!record.DTSTART || !record.DTEND) throw new Error('The prototype requires DTSTART and DTEND');
        events.push(normalizeEvent({ title: unescapeIcs(record.SUMMARY?.value || ''), start: icsDate(record.DTSTART, zone), end: icsDate(record.DTEND, zone), address: unescapeIcs(record.LOCATION?.value || ''), notes: unescapeIcs(record.DESCRIPTION?.value || ''), sourceUid: record.UID?.value || '', source: 'ICS', timeZone: zone }));
      } catch (error) { warnings.push(`Event ${count}: ${error.message}`); }
      record = null; continue;
    }
    if (line.startsWith('BEGIN:')) { nested = true; continue; }
    if (line.startsWith('END:')) { nested = false; continue; }
    if (nested) continue;
    const colon = line.indexOf(':'); if (colon < 0) continue;
    const [key, ...parameters] = line.slice(0, colon).split(';');
    record[key.toUpperCase()] = { params: parameters.join(';'), value: line.slice(colon + 1) };
  }
  if (record) warnings.push('The last event is missing END:VEVENT');
  return { events, warnings };
}
export function parseImport(text, extension, zone = DEFAULT_ZONE) {
  if (text.length > 2 * 1024 * 1024) throw new Error('Prototype file size limit: 2 MB');
  if (extension === 'ics') return parseIcs(text, zone);
  if (extension === 'csv' || extension === 'tsv') return parseCsv(text, zone);
  if (extension === 'json') {
    const parsed = JSON.parse(text);
    const rows = Array.isArray(parsed) ? parsed : parsed.events;
    if (!Array.isArray(rows)) throw new Error('JSON requires an event array or an object with an events array');
    if (rows.length > 2000) throw new Error('Prototype limit: 2000 events');
    return collect(rows, 'JSON', zone);
  }
  throw new Error('Available formats: ICS, CSV, TSV and JSON. PDF, Excel and photos are planned');
}
export function extractText(text, zone = DEFAULT_ZONE) {
  const iso = text.match(/\b(\d{4}-\d{2}-\d{2})\b/);
  const dotted = text.match(/\b(\d{2})\.(\d{2})\.(\d{4})\b/);
  const day = iso?.[1] || (dotted ? `${dotted[3]}-${dotted[2]}-${dotted[1]}` : null);
  const times = text.match(/\b([0-2]?\d:[0-5]\d)\s*[–—-]\s*([0-2]?\d:[0-5]\d)\b/);
  const lines = text.split(/\r?\n/).map(x => x.trim()).filter(Boolean);
  const title = lines.find(l => /^(тема|название|предмет|subject|title|course)\s*:/i.test(l))?.replace(/^[^:]+:\s*/, '') || lines[0] || '';
  const field = (name) => lines.find(l => new RegExp(`^${name}\\s*:`, 'i').test(l))?.replace(/^[^:]+:\s*/, '') || '';
  const missing = []; if (!day) missing.push('an exact date including the year'); if (!times) missing.push('start and end times');
  const draft = { title, address: field('(адрес|address)'), venue: field('(место|venue)'), room: field('(аудитория|room)'), floor: field('(этаж|floor)'), notes: text, source: 'Text', timeZone: zone };
  if (missing.length) return { draft, warnings: [`Please clarify: ${missing.join(', ')}`] };
  const pad = time => time.split(':').map(n => n.padStart(2,'0')).join(':');
  try { return { draft: normalizeEvent({ ...draft, start: `${day}T${pad(times[1])}`, end: `${day}T${pad(times[2])}` }), warnings: draft.address ? [] : ['Address not found: add it manually if travel is needed'] }; }
  catch (error) { return { draft, warnings: [error.message] }; }
}
export function exportIcs(events) {
  const esc = value => String(value).replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/,/g, '\\,').replace(/;/g, '\\;').replace(/\r/g, '');
  const date = value => new Date(value).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Calendula//Prototype//RU', 'CALSCALE:GREGORIAN'];
  for (const e of events) lines.push('BEGIN:VEVENT', `UID:${esc(e.sourceUid || e.id)}`, `DTSTAMP:${date(new Date())}`, `DTSTART:${date(e.start)}`, `DTEND:${date(e.end)}`, `SUMMARY:${esc(e.title)}`, `LOCATION:${esc(e.address)}`, `DESCRIPTION:${esc(e.notes)}`, 'END:VEVENT');
  lines.push('END:VCALENDAR');
  // RFC 5545: предел 75 октетов, перенос без разрыва UTF-8 символов.
  return lines.map(line => {
    let output = '', piece = '', bytes = 0;
    for (const char of line) { const size = new TextEncoder().encode(char).length; if (bytes + size > 75) { output += `${piece}\r\n`; piece = ' '; bytes = 1; } piece += char; bytes += size; }
    return output + piece;
  }).join('\r\n') + '\r\n';
}
