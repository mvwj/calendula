import { DEFAULT_ZONE, normalizeEvent, dayKey, localInput, localToIso, eventsOnDay, conflicts, departurePlan, parseImport, extractText, exportIcs, isDuplicate } from '/src/calendar.mjs';

const $ = selector => document.querySelector(selector);
const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[char]));
const key = 'calendula.prototype.v1';
const categories = { study:'Study', work:'Work', culture:'Culture', personal:'Personal' };
let settings = { theme:'light', timeZone:DEFAULT_ZONE }, events = [], candidates = [], warnings = [], selectedId = null, page = 'calendar', view = 'day', toastTimer, lastUndo;
let storageWarning = '';
try {
  const saved = JSON.parse(localStorage.getItem(key) || 'null');
  if (saved) {
    if (!Array.isArray(saved.events)) throw new Error('The saved calendar is invalid.');
    settings = { ...settings, ...saved.settings };
    new Intl.DateTimeFormat('en', { timeZone:settings.timeZone });
    events = saved.events.map(e => normalizeEvent(e));
  } else {
    const date = dayKey(new Date(), settings.timeZone);
    events = [
      { title:'History of architecture', start:`${date}T09:30`, end:`${date}T11:00`, category:'study', venue:'University · sample', address:'Example campus 12, Prague', room:'204', floor:'2', travelMinutes:32, bufferMinutes:10, prepMinutes:15, notes:'Lecture and seminar. Fictional event for interface testing.' },
      { title:'A little time for yourself', start:`${date}T12:00`, end:`${date}T13:00`, category:'personal', venue:'At home', notes:'Lunch, a book, or simply a break.' },
      { title:'An evening at the cinema', start:`${date}T19:00`, end:`${date}T21:10`, category:'culture', venue:'Cinema · sample', address:'Example cinema 8, Prague', room:'Hall 2', travelMinutes:28, bufferMinutes:10, prepMinutes:10, notes:'Fictional screening. Travel time is a manual estimate.' }
    ].map(e => normalizeEvent({ ...e, timeZone:settings.timeZone, source:'Sample' }));
    persist();
  }
} catch (error) { storageWarning = `Storage could not be loaded: ${error.message}`; }
let date = dayKey(new Date(), settings.timeZone), miniMonth = date.slice(0,7);

function persist() { localStorage.setItem(key, JSON.stringify({ version:1, events, settings })); }
function saveEvents(next) {
  const previous = events; events = next;
  try { persist(); } catch (error) { events = previous; throw new Error(`Could not save your calendar: ${error.message}`); }
}
function toast(message, undo = null) {
  clearTimeout(toastTimer); const element = $('#toast'); element.replaceChildren(document.createTextNode(message)); element.hidden = false; lastUndo = undo;
  if (undo) { const button = document.createElement('button'); button.textContent = 'Undo'; button.addEventListener('click', () => { try { lastUndo?.(); element.hidden = true; } catch (error) { toast(error.message); } }); element.append(button); }
  toastTimer = setTimeout(() => { element.hidden = true; lastUndo = null; }, undo ? 12000 : 6000);
}
function time(value) { return new Intl.DateTimeFormat('en-GB', { timeZone:settings.timeZone, hour:'2-digit', minute:'2-digit' }).format(new Date(value)); }
function prettyDay(value, options = { weekday:'long', day:'numeric', month:'long' }) { return new Intl.DateTimeFormat('en-GB', { ...options, timeZone:'UTC' }).format(new Date(`${value}T12:00:00Z`)); }
function addDays(value, count) { const d = new Date(`${value}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + count); return d.toISOString().slice(0,10); }
function changeMonth(value, count) { const d = new Date(`${value.slice(0,7)}-01T12:00:00Z`); d.setUTCMonth(d.getUTCMonth() + count); return d.toISOString().slice(0,7); }
function monday(value) { const day = new Date(`${value}T12:00:00Z`).getUTCDay(); return addDays(value, -(day + 6) % 7); }
function duration(event) { return Math.round((new Date(event.end) - new Date(event.start)) / 60000); }
function durationLabel(minutes) { return minutes >= 60 ? `${Math.floor(minutes/60)}h${minutes%60 ? ` ${minutes%60}m` : ''}` : `${minutes}m`; }
function applyTheme() { const dark = settings.theme === 'dark' || settings.theme === 'system' && matchMedia('(prefers-color-scheme: dark)').matches; document.documentElement.dataset.theme = dark ? 'dark' : 'light'; }
function setDate(next) { date = next; miniMonth = date.slice(0,7); selectedId = null; showPage('calendar'); }
function showPage(next) {
  page = next;
  for (const name of ['calendar','inbox','sources','settings']) $(`#${name}-page`).hidden = name !== page;
  document.querySelectorAll('[data-page]').forEach(button => { const active = button.dataset.page === page; button.classList.toggle('selected', active); if (active) button.setAttribute('aria-current','page'); else button.removeAttribute('aria-current'); });
  $('#breadcrumb').textContent = ({ calendar:'My schedule', inbox:'Review inbox', sources:'Connected sources', settings:'Your preferences' })[page];
  render();
}
function renderMini() {
  $('#mini-title').textContent = prettyDay(`${miniMonth}-01`, { month:'long', year:'numeric' });
  const first = monday(`${miniMonth}-01`);
  $('#mini-days').innerHTML = Array.from({ length:42 }, (_, index) => {
    const d = addDays(first, index), has = eventsOnDay(events, d, settings.timeZone).length;
    return `<button data-date="${d}" aria-label="${esc(prettyDay(d))}" ${d === date ? 'aria-pressed="true"' : 'aria-pressed="false"'} class="${d.slice(0,7) !== miniMonth ? 'other ' : ''}${d === date ? 'active ' : ''}${has ? 'has-events' : ''}">${+d.slice(-2)}</button>`;
  }).join('');
}
function eventBlock(event, compact = false) {
  const minutes = duration(event);
  return `<button class="event-block ${esc(event.category)} ${compact ? 'week-event' : ''}" data-event="${esc(event.id)}" aria-label="${esc(`${event.title}, ${time(event.start)} to ${time(event.end)}`)}">${!compact ? `<span class="event-duration">${durationLabel(minutes)}</span>` : ''}<div class="event-name">${esc(event.title)}</div><div class="event-meta"><span>${esc(compact ? `${time(event.start)}–${time(event.end)}` : event.venue || categories[event.category])}</span>${!compact && event.room ? `<span>Room ${esc(event.room)}${event.floor ? ` · Floor ${esc(event.floor)}` : ''}</span>` : ''}</div></button>`;
}
function renderSchedule() {
  const todayEvents = eventsOnDay(events, date, settings.timeZone);
  $('#date-caption').textContent = prettyDay(date, { weekday:'long', day:'numeric', month:'long', year:'numeric' }).toUpperCase();
  $('#day-title').textContent = view === 'month' ? prettyDay(date, { month:'long', year:'numeric' }) : view === 'week' ? 'A week at your pace.' : 'A calmer kind of day.';
  const travelling = todayEvents.filter(e => departurePlan(e)).length;
  $('#day-subtitle').textContent = `${todayEvents.length} event${todayEvents.length === 1 ? '' : 's'}${travelling ? ` · ${travelling} journey estimate${travelling === 1 ? '' : 's'}` : ''} · ${settings.timeZone.split('/').pop().replace(/_/g,' ')} time`;
  document.querySelectorAll('[data-view]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.view === view)));
  if (view === 'month') {
    const first = monday(`${date.slice(0,7)}-01`);
    $('#schedule').innerHTML = `<div class="month-grid">${['Mon','Tue','Wed','Thu','Fri','Sat','Sun'].map(d => `<div class="month-label">${d}</div>`).join('')}${Array.from({ length:42 }, (_, index) => {
      const d = addDays(first,index), dayEvents = eventsOnDay(events,d,settings.timeZone);
      return `<button class="month-day ${d.slice(0,7) !== date.slice(0,7) ? 'other' : ''} ${d === date ? 'active' : ''}" data-date="${d}" aria-label="${esc(`${prettyDay(d)}, ${dayEvents.length} events`)}">${+d.slice(-2)}${dayEvents.slice(0,2).map(e => `<small>${esc(e.title)}</small>`).join('')}${dayEvents.length > 2 ? `<small>+${dayEvents.length - 2} more</small>` : ''}</button>`;
    }).join('')}</div>`;
  } else if (view === 'week') {
    $('#schedule').innerHTML = `<div class="week-grid">${Array.from({ length:7 }, (_, index) => {
      const d = addDays(monday(date),index), dayEvents = eventsOnDay(events,d,settings.timeZone);
      return `<section class="week-column"><button class="week-day ${d === date ? 'active' : ''}" data-date="${d}">${esc(prettyDay(d,{weekday:'short',day:'numeric'}))}</button>${dayEvents.length ? dayEvents.map(e => eventBlock(e,true)).join('') : '<div class="week-empty">—</div>'}</section>`;
    }).join('')}</div>`;
  } else if (!todayEvents.length) {
    $('#schedule').innerHTML = '<div class="empty"><div class="empty-symbol">✳</div><h3>A little room to breathe.</h3><p>No events for this day.</p><button class="quiet" data-action="new">Add something</button></div>';
  } else {
    $('#schedule').innerHTML = `<div class="timeline">${todayEvents.map((event,index) => {
      const plan = departurePlan(event), previous = todayEvents[index-1];
      const gap = previous ? Math.round((new Date(event.start) - new Date(previous.end))/60000) : 0;
      return `${gap >= 30 ? `<div class="gap-row">${durationLabel(gap)} between events</div>` : ''}${plan ? `<div class="travel-row"><span class="travel-icon" aria-hidden="true">↗</span><div><strong>Leave at ${time(plan.leaveAt)}</strong> · ${event.travelMinutes} min to ${esc(event.venue || 'your destination')}<small>Manual estimate · ${event.bufferMinutes} min arrival buffer</small></div></div>` : ''}<div class="event-row"><div class="event-time">${time(event.start)}<small>${time(event.end)}</small></div>${eventBlock(event)}</div>`;
    }).join('')}</div>`;
  }
}
function currentEvent() {
  const onDay = eventsOnDay(events,date,settings.timeZone);
  return events.find(e => e.id === selectedId) || onDay.find(e => new Date(e.end) > new Date()) || onDay[0];
}
function journeyMarkup(event) {
  const plan = event && departurePlan(event);
  if (!plan) return `<div class="journey-card"><p class="eyebrow">YOUR NEXT JOURNEY</p><h3>${event ? 'Set your travel estimate' : 'Enjoy the open space.'}</h3><p>${event ? 'Add an address and travel time to see when to leave.' : 'No journeys on this day.'}</p><div class="estimate-tag">Public transport routing is planned.</div></div>`;
  const otherDay = dayKey(plan.leaveAt,settings.timeZone) !== date;
  return `<div class="journey-card"><p class="eyebrow">TIME TO LEAVE${otherDay ? ` · ${esc(prettyDay(dayKey(plan.leaveAt,settings.timeZone),{day:'numeric',month:'short'}))}` : ''}</p><div class="leave-time">${time(plan.leaveAt)}</div><h3>${esc(event.venue || event.title)}</h3><p>${esc(event.address)}</p><div class="journey-facts"><div><span>TRAVEL</span>${event.travelMinutes} min</div><div><span>ARRIVE BY</span>${time(plan.targetArrival)}</div>${event.prepMinutes ? `<div><span>GET READY</span>${time(plan.prepareAt)}</div>` : ''}</div><div class="estimate-tag">Manual estimate · no live route data</div></div>`;
}
function renderRight() {
  $('#right-date').textContent = prettyDay(date,{day:'numeric',month:'short'});
  const event = currentEvent(); $('#journey-panel').innerHTML = journeyMarkup(event);
  if (!event) { $('#details-panel').innerHTML = ''; return; }
  const overlaps = conflicts(events).filter(pair => pair.includes(event.id));
  const plan = departurePlan(event);
  $('#details-panel').innerHTML = `<p class="eyebrow">${esc(categories[event.category])} · ${esc(event.source)}</p><h3>${esc(event.title)}</h3><div class="detail-line"><span aria-hidden="true">◷</span><div>${time(event.start)}–${time(event.end)}<small>${esc(prettyDay(dayKey(event.start,settings.timeZone)))}</small></div></div>${event.venue || event.address ? `<div class="detail-line"><span aria-hidden="true">⌖</span><div>${esc(event.venue || event.address)}${event.venue && event.address ? `<small>${esc(event.address)}</small>` : ''}</div></div>` : ''}${event.room ? `<div class="detail-line"><span aria-hidden="true">▧</span><div>${esc(event.room)}${event.floor ? `<small>Floor ${esc(event.floor)}</small>` : ''}</div></div>` : ''}${plan ? `<div class="detail-line"><span aria-hidden="true">↗</span><div>${event.travelMinutes} min travel + ${event.bufferMinutes} min buffer<small>Public transport estimate entered manually</small></div></div>` : ''}${event.notes ? `<div class="detail-line"><span aria-hidden="true">≡</span><div>${esc(event.notes)}</div></div>` : ''}${overlaps.length ? `<p class="conflict">Overlaps with ${overlaps.length} other event${overlaps.length === 1 ? '' : 's'}.</p>` : ''}<div class="detail-actions"><button class="quiet" data-edit="${esc(event.id)}">Edit event</button><button class="quiet danger" data-delete="${esc(event.id)}">Delete</button></div>`;
}
function renderInbox() {
  $('#inbox-count').textContent = candidates.length;
  $('#import-warnings').replaceChildren(...warnings.map(w => { const p = document.createElement('p'); p.textContent = w; return p; }));
  $('#candidates').innerHTML = candidates.length ? candidates.map(c => {
    const e = c.event, duplicate = e.start && isDuplicate(e,events);
    return `<article class="candidate-card"><p class="eyebrow">${esc(e.source || 'Imported')}${duplicate ? ' · ALREADY IN CALENDAR' : ''}</p><h3>${esc(e.title || 'Untitled event')}</h3><p class="candidate-meta">${e.start && e.end ? `${esc(prettyDay(dayKey(e.start,settings.timeZone)))} · ${time(e.start)}–${time(e.end)}` : 'Date or time needs clarification'}</p><p class="candidate-meta">${esc(e.address || 'No address — optional for events without travel')}</p><div class="detail-actions">${e.start && e.end && !duplicate ? `<button class="primary" data-accept="${c.id}">Add to calendar</button>` : ''}<button class="quiet" data-candidate-edit="${c.id}">Review & edit</button><button class="quiet" data-dismiss="${c.id}">Dismiss</button></div></article>`;
  }).join('') : '<div class="empty"><div class="empty-symbol">↙</div><h3>All clear.</h3><p>Import a timetable or paste an invitation to get started.</p></div>';
}
function render() { applyTheme(); renderMini(); renderSchedule(); renderRight(); renderInbox(); $('#theme').value = settings.theme; $('#timezone').value = settings.timeZone; }
function openForm(event = null, candidateId = '') {
  const form = $('#event-form'); form.reset();
  const start = `${date}T10:00`, end = `${date}T11:00`;
  const values = { id:'', candidateId, title:'', start, end, category:'personal', address:'', venue:'', room:'', floor:'', notes:'', travelMinutes:'', bufferMinutes:10, prepMinutes:0, source:'manual', sourceUid:'' };
  if (event) { Object.assign(values,event); values.start = event.start ? localInput(event.start,settings.timeZone) : start; values.end = event.end ? localInput(event.end,settings.timeZone) : end; values.id = candidateId ? '' : event.id || ''; values.travelMinutes = event.travelMinutes ?? ''; }
  for (const [name,value] of Object.entries(values)) if (form.elements.namedItem(name)) form.elements.namedItem(name).value = value;
  $('#form-title').textContent = candidateId ? 'Review event' : event ? 'Edit event' : 'New event';
  $('#form-zone').textContent = `Times are entered in ${settings.timeZone}.`;
  $('#form-error').textContent = ''; $('#event-dialog').showModal();
}
function addCandidate(event) { candidates.push({ id:crypto.randomUUID(),event }); }
function download(content,name,type) { const url = URL.createObjectURL(new Blob([content],{type})); const a = document.createElement('a'); a.href=url; a.download=name; a.click(); setTimeout(() => URL.revokeObjectURL(url),1000); }
document.querySelectorAll('[data-page]').forEach(b => b.addEventListener('click',() => showPage(b.dataset.page)));
document.querySelectorAll('[data-view]').forEach(b => b.addEventListener('click',() => { view=b.dataset.view; render(); }));
$('#mini-days').addEventListener('click',e => { const button=e.target.closest('[data-date]'); if (button) setDate(button.dataset.date); });
$('#mini-prev').addEventListener('click',() => { miniMonth=changeMonth(miniMonth,-1); renderMini(); });
$('#mini-next').addEventListener('click',() => { miniMonth=changeMonth(miniMonth,1); renderMini(); });
$('#today').addEventListener('click',() => setDate(dayKey(new Date(),settings.timeZone)));
for (const [id,amount] of [['prev-date',-1],['next-date',1]]) $(`#${id}`).addEventListener('click',() => setDate(view === 'month' ? `${changeMonth(date,amount)}-01` : addDays(date,amount*(view === 'week' ? 7 : 1))));
$('#add-event').addEventListener('click',() => openForm());
$('#schedule').addEventListener('click',e => {
  const button=e.target.closest('button'); if (!button) return;
  if (button.dataset.date) { view='day'; setDate(button.dataset.date); }
  if (button.dataset.event) { selectedId=button.dataset.event; renderRight(); }
  if (button.dataset.action === 'new') openForm();
});
$('#details-panel').addEventListener('click',e => {
  const button=e.target.closest('button'); if (!button) return;
  const event=events.find(event => event.id === (button.dataset.edit || button.dataset.delete)); if (!event) return;
  if (button.dataset.edit) openForm(event);
  if (button.dataset.delete) {
    try { saveEvents(events.filter(e => e.id !== event.id)); selectedId=null; render(); toast('Event deleted.',() => { saveEvents([...events,event]); render(); }); }
    catch (error) { toast(error.message); }
  }
});
$('#event-form').addEventListener('submit',e => {
  e.preventDefault(); const values=Object.fromEntries(new FormData(e.target));
  try {
    const normalized=normalizeEvent({ ...values, timeZone:settings.timeZone, start:localToIso(values.start,settings.timeZone), end:localToIso(values.end,settings.timeZone) });
    const existing=events.filter(e => e.id !== normalized.id);
    if (isDuplicate(normalized,existing)) throw new Error('This event is already in your calendar.');
    saveEvents([...existing,normalized]);
    if (values.candidateId) candidates=candidates.filter(c => c.id !== values.candidateId);
    selectedId=normalized.id; date=dayKey(normalized.start,settings.timeZone); miniMonth=date.slice(0,7);
    $('#event-dialog').close(); showPage('calendar'); toast('Event saved.');
  } catch (error) { $('#form-error').textContent=error.message; }
});
document.querySelectorAll('.close-dialog').forEach(b => b.addEventListener('click',() => b.closest('dialog').close()));
for (const id of ['import-button','choose-file','source-import']) $(`#${id}`).addEventListener('click',() => $('#file-input').click());
$('#file-input').addEventListener('change',async e => {
  const file=e.target.files[0]; if (!file) return;
  try {
    if (file.size > 2*1024*1024) throw new Error('Prototype import limit: 2 MB.');
    const result=parseImport(await file.text(),file.name.split('.').pop().toLowerCase(),settings.timeZone);
    if (result.events.length > 2000) throw new Error('Prototype import limit: 2000 events.');
    result.events.forEach(addCandidate); warnings=result.warnings; showPage('inbox'); toast(`${result.events.length} event${result.events.length === 1 ? '' : 's'} ready for review.`);
  } catch (error) { toast(error.message); }
  e.target.value='';
});
$('#text-import').addEventListener('click',() => $('#text-dialog').showModal());
$('#parse-text').addEventListener('click',() => {
  const text=$('#import-text').value.trim(); if (!text) { toast('Paste an invitation or timetable first.'); return; }
  if (text.length > 50000) { toast('Text import limit: 50,000 characters.'); return; }
  try { const result=extractText(text,settings.timeZone); addCandidate(result.draft); warnings=result.warnings; $('#text-dialog').close(); showPage('inbox'); }
  catch (error) { toast(error.message); }
});
$('#demo-mail').addEventListener('click',() => {
  const result=extractText(`Subject: A lecture on design\nDate: ${addDays(date,1)}\nTime: 14:00–15:30\nAddress: Example campus 12, Prague\nVenue: University · sample\nRoom: 305\nFloor: 3`,settings.timeZone);
  addCandidate({ ...result.draft, category:'study', source:'Sample invitation' }); warnings=result.warnings; renderInbox();
});
$('#candidates').addEventListener('click',e => {
  const button=e.target.closest('button'); if (!button) return;
  const id=button.dataset.accept || button.dataset.candidateEdit || button.dataset.dismiss;
  const candidate=candidates.find(c => c.id === id); if (!candidate) return;
  if (button.dataset.candidateEdit) openForm(candidate.event,id);
  if (button.dataset.dismiss) { candidates=candidates.filter(c => c.id !== id); renderInbox(); }
  if (button.dataset.accept) {
    try {
      const event=normalizeEvent(candidate.event);
      if (isDuplicate(event,events)) throw new Error('This event is already in your calendar.');
      saveEvents([...events,event]); candidates=candidates.filter(c => c.id !== id); render(); toast('Added to your calendar.');
    } catch (error) { toast(error.message); }
  }
});
$('#refresh').addEventListener('click',() => toast('No email sources connected yet. Your local calendar is up to date.'));
$('#export-button').addEventListener('click',() => download(exportIcs(events),'calendula.ics','text/calendar;charset=utf-8'));
$('#json-backup').addEventListener('click',() => download(JSON.stringify({ version:1, events, settings },null,2),'calendula-backup.json','application/json'));
for (const [id,property] of [['theme','theme'],['timezone','timeZone']]) $(`#${id}`).addEventListener('change',e => {
  const previous={...settings};
  try { settings[property]=e.target.value; persist(); if (property === 'timeZone') selectedId=null; render(); }
  catch (error) { settings=previous; render(); toast(error.message); }
});
matchMedia('(prefers-color-scheme: dark)').addEventListener('change',applyTheme);
$('#widget-preview').addEventListener('click',() => {
  const onDay=eventsOnDay(events,date,settings.timeZone), current=currentEvent();
  $('#widget-content').innerHTML=`<p class="eyebrow">CALENDULA</p><h3>${esc(prettyDay(date))}</h3>${journeyMarkup(current)}${onDay.map(e => `<div class="widget-event"><time>${time(e.start)}</time><div>${esc(e.title)}<small>${esc(e.venue || categories[e.category])}${e.room ? ` · ${esc(e.room)}` : ''}</small></div></div>`).join('')}`;
  $('#widget-dialog').showModal();
});
render();
if (storageWarning) toast(storageWarning);
