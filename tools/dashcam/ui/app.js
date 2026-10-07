'use strict';
// «Разбор видео», этап M1: поездки → карта с треком → видео с ползунком.
// Время ролика — по часам регистратора; на трек его переводит сдвиг
// синхронизации: время телефона = время регистратора + offset.

const LOCAL_STYLE = 'http://127.0.0.1:8770/st_light_full.json';
const PROD_STYLE = 'https://soulmed.uz/radarmap/map_style.json';
const BLANK_STYLE = { version: 8, sources: {}, layers: [
  { id: 'bg', type: 'background', paint: { 'background-color': '#eef0f2' } }] };
const TZ = 5 * 3600; // часы регистратора — Ташкент, UTC+5

const $ = (id) => document.getElementById(id);
let trips = [], detail = null, selKey = null, selTrack = null;
let map = null, mapReady = null, car = null, popup = null, styleNote = '';
let active = $('va'), standby = $('vb'), activeIdx = -1, standbyIdx = -1;
let pendingSeek = null, dragging = false;

// ---------- форматирование ----------
function hms(t, frac) {
  if (t == null || !isFinite(t)) return '—';
  const s = new Date((t + TZ) * 1000).toISOString().substr(11, frac ? 10 : 8);
  return s;
}
function syncText(s) {
  if (!s) return 'не синхронизировано';
  if (s.method === 'anchors') {
    const med = s.residual_median_m == null ? '—' : s.residual_median_m;
    return `по опорам ${s.anchors_used}/${s.anchors} · невязка ${med} м (макс ${s.residual_max_m ?? '—'})`;
  }
  if (s.offset == null) return 'нет общих данных с треком';
  return `сдвиг ${s.offset >= 0 ? '+' : ''}${s.offset.toFixed(1)} с · r ${s.quality.toFixed(3)}`;
}
const STAGE = { no_gpx: 'нет GPX', no_anchors: 'нет опор', before_history: 'до начала истории (опоры с 17.09)', ocr: 'нужен OCR полосы', sync: 'не синхронизировано',
  bad_sync: 'синхронизация не годится', ready: 'готово' };
function esc(s) { return String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`); }

async function api(path, body) {
  const opt = body ? { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body) } : {};
  const r = await fetch(path, opt);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

// ---------- список поездок ----------
async function loadTrips() {
  trips = await api('/api/trips');
  renderTrips();
  const running = trips.some((t) => t.job && (t.job.state === 'ocr' || t.job.state === 'sync'));
  if (running) setTimeout(refreshAfterJob, 2000);
  if (!selKey && trips.length) selectTrip(trips[0].key);
}
async function refreshAfterJob() {
  const before = JSON.stringify(trips.map((t) => [t.key, t.stage, t.job && t.job.state]));
  await loadTrips();
  const after = JSON.stringify(trips.map((t) => [t.key, t.stage, t.job && t.job.state]));
  if (before !== after && selKey) selectTrip(selKey, true);
}

function renderTrips() {
  const box = $('trips');
  box.innerHTML = '';
  if (!trips.length) box.innerHTML = '<div class="muted">Поездок пока нет — импортируйте папку роликов.</div>';
  for (const t of trips) {
    const div = document.createElement('div');
    div.className = 'trip' + (t.key === selKey ? ' sel' : '');
    const job = t.job;
    let stage = STAGE[t.stage] || t.stage, cls = t.stage;
    if (job && job.state === 'ocr') { stage = `OCR полосы… ${job.done}/${job.total || t.clips}`; cls = 'ocr'; }
    else if (job && job.state === 'sync') { stage = 'синхронизация…'; cls = 'sync'; }
    else if (job && job.state === 'error') { stage = 'ошибка: ' + job.error; cls = 'error'; }
    const tr = t.track;
    const mins = Math.round((t.end - t.start) / 60);
    div.innerHTML = `
      <div class="when">${hms(t.start).substr(0, 5)}–${hms(t.end).substr(0, 5)}
        <span class="muted">${new Date((t.start + TZ) * 1000).toISOString().substr(0, 10)}</span></div>
      <div class="muted">${t.clips} рол. · ${mins} мин · OCR ${t.ocr_done}/${t.clips}</div>
      <div class="muted">${tr ? esc(tr.name) + (tr.kind === 'anchored' ? (/опор/.test(tr.name) ? '' : ' · по опорам') : ' · подробный')
        + (tr.synthetic ? '<span class="badge synth">синтетика</span>' : '') : 'трека нет'}</div>
      <div class="stage ${cls}">${esc(stage)}</div>
      ${t.sync ? `<div class="muted">${esc(syncText(t.sync))}</div>` : ''}`;
    if (t.tracks.length > 1) {
      const sel = document.createElement('select');
      for (const c of t.tracks) {
        const o = document.createElement('option');
        o.value = c.id;
        o.textContent = (c.synthetic ? '[синтетика] ' : '') + c.name;
        if (t.key === selKey && (selTrack ? selTrack === c.id : tr && tr.id === c.id)) o.selected = true;
        sel.appendChild(o);
      }
      sel.onclick = (e) => e.stopPropagation();
      sel.onchange = () => { selTrack = +sel.value; selectTrip(t.key, false, true); };
      div.appendChild(sel);
    }
    if (t.stage !== 'ready' && !['no_gpx', 'no_anchors', 'before_history'].includes(t.stage) && !(job && ['ocr', 'sync'].includes(job.state))) {
      const b = document.createElement('button');
      b.textContent = t.ocr_done < t.clips ? 'OCR + синхронизация' : 'Синхронизировать';
      b.onclick = async (e) => { e.stopPropagation(); await api(`/api/trips/${t.key}/process`, {}); loadTrips(); };
      div.appendChild(b);
    }
    div.onclick = () => { if (t.key !== selKey) { selTrack = null; selectTrip(t.key); } };
    box.appendChild(div);
  }
}

$('import').onsubmit = async (e) => {
  e.preventDefault();
  const path = $('import-path').value.trim();
  if (!path) return;
  $('import-msg').textContent = 'импорт…';
  try {
    const r = await api('/api/import', { path });
    $('import-msg').textContent = `новых роликов ${r.clips}, треков ${r.tracks}`;
    loadTrips();
  } catch (err) { $('import-msg').textContent = err.message; }
};

// ---------- карта ----------
async function pickStyle() {
  for (const [url, note] of [[LOCAL_STYLE, 'наш стиль (локальное превью)'], [PROD_STYLE, 'прод-стиль']]) {
    try {
      const r = await fetch(url, { cache: 'no-store' });
      if (r.ok) { await r.json(); styleNote = note; return url; }
    } catch (_) { /* следующий */ }
  }
  styleNote = 'без подложки: стиль недоступен';
  return BLANK_STYLE;
}

function initMap() {
  mapReady = (async () => {
    map = new maplibregl.Map({ container: 'map', style: await pickStyle(), center: [69.27, 41.33],
      zoom: 12, attributionControl: { compact: true } });
    map.addControl(new maplibregl.NavigationControl({ showCompass: true }), 'top-left');
    await new Promise((res) => map.on('load', res));
    const empty = { type: 'FeatureCollection', features: [] };
    for (const id of ['shape', 'track', 'anchors']) map.addSource(id, { type: 'geojson', data: empty });
    map.addLayer({ id: 'shape', type: 'line', source: 'shape',
      paint: { 'line-color': '#7a7f88', 'line-width': 2, 'line-dasharray': [2, 2] } });
    map.addLayer({ id: 'track-casing', type: 'line', source: 'track',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': '#fff', 'line-width': 8 } });
    map.addLayer({ id: 'track', type: 'line', source: 'track',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-width': 5, 'line-color': ['interpolate', ['linear'], ['get', 'kmh'],
        0, '#c62828', 20, '#f57c00', 40, '#fbc02d', 60, '#7cb342', 80, '#1e88e5'] } });
    map.addLayer({ id: 'anchors', type: 'circle', source: 'anchors',
      paint: { 'circle-radius': 7, 'circle-stroke-width': 2, 'circle-stroke-color': '#fff',
        'circle-color': ['case', ['==', ['get', 'used'], false], '#9aa0aa', '#6a1b9a'] } });
    const el = document.createElement('div');
    el.className = 'car';
    el.innerHTML = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="11" fill="#1f6feb" stroke="#fff" stroke-width="2"/>'
      + '<path d="M12 4 L18 17 L12 14 L6 17 Z" fill="#fff"/></svg>';
    car = new maplibregl.Marker({ element: el, rotationAlignment: 'map' });
    map.on('click', 'track', (e) => {
      if (!detail || !detail.points.length) return;
      const t = nearestTime(e.lngLat.lat, e.lngLat.lng);
      if (t != null) seekTo(t - detail.offset);
    });
    map.on('click', 'anchors', (e) => {
      const p = e.features[0].properties;
      showAnchor(p, e.lngLat);
      if (p.t != null) seekTo(p.t - detail.offset - 3);
    });
    for (const id of ['track', 'anchors']) {
      map.on('mouseenter', id, () => { map.getCanvas().style.cursor = 'pointer'; });
      map.on('mouseleave', id, () => { map.getCanvas().style.cursor = ''; });
    }
  })();
  return mapReady;
}

function showAnchor(p, lngLat) {
  if (popup) popup.remove();
  const res = p.residual_m != null && p.residual_m !== 'null' ? `<br>невязка перегона: ${p.residual_m} м` : '';
  const used = p.used === false || p.used === 'false' ? '<br><i>вне видео — в модель не взята</i>' : '';
  const off = p.offset_m != null && p.offset_m !== 'null' ? `<br>от формы трека: ${p.offset_m} м` : '';
  popup = new maplibregl.Popup({ closeButton: true }).setLngLat(lngLat)
    .setHTML(`<b>${esc(p.name)}</b><br>${hms(+p.t)}${off}${res}${used}`).addTo(map);
}

function drawTrip() {
  const pts = detail.points;
  const segs = [];
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1], b = pts[i];
    if (a[1] === b[1] && a[2] === b[2]) continue;
    segs.push({ type: 'Feature', properties: { kmh: b[3] ?? 0 },
      geometry: { type: 'LineString', coordinates: [[a[2], a[1]], [b[2], b[1]]] } });
  }
  map.getSource('track').setData({ type: 'FeatureCollection', features: segs });
  map.getSource('shape').setData({ type: 'FeatureCollection', features: detail.shape.length ? [{
    type: 'Feature', properties: {},
    geometry: { type: 'LineString', coordinates: detail.shape.map((p) => [p[1], p[0]]) } }] : [] });
  map.getSource('anchors').setData({ type: 'FeatureCollection', features: detail.anchors.map((a) => ({
    type: 'Feature', properties: { name: a.name, t: a.t, used: a.used, residual_m: a.residual_m ?? null,
      offset_m: a.offset_m ?? null },
    geometry: { type: 'Point', coordinates: [a.lon, a.lat] } })) });
  const all = pts.length ? pts.map((p) => [p[2], p[1]]) : detail.shape.map((p) => [p[1], p[0]]);
  if (all.length) {
    const b = all.reduce((bb, c) => bb.extend(c), new maplibregl.LngLatBounds(all[0], all[0]));
    map.fitBounds(b, { padding: 40, duration: 0 });
  }
}

// Позиция и курс на треке по времени телефона (как locate.position_at).
function lowerIdx(t) {
  const pts = detail.points;
  let lo = 0, hi = pts.length - 1;
  while (lo < hi) { const m = (lo + hi + 1) >> 1; if (pts[m][0] <= t) lo = m; else hi = m - 1; }
  return lo;
}
function bearing(a, b) {
  const kx = Math.cos(a[1] * Math.PI / 180);
  return (Math.atan2((b[2] - a[2]) * kx, b[1] - a[1]) * 180 / Math.PI + 360) % 360;
}
function moved(a, b) {
  const kx = Math.cos(a[1] * Math.PI / 180) * 111195, ky = 111195;
  return Math.hypot((b[2] - a[2]) * kx, (b[1] - a[1]) * ky) >= 1;
}
function posAt(t) {
  const pts = detail.points;
  if (!pts.length || t < pts[0][0] || t > pts[pts.length - 1][0]) return null;
  const i = Math.min(lowerIdx(t), pts.length - 2);
  if (i < 0) return { lat: pts[0][1], lon: pts[0][2], course: null, kmh: pts[0][3] };
  const a = pts[i], b = pts[i + 1];
  const k = b[0] > a[0] ? (t - a[0]) / (b[0] - a[0]) : 0;
  let course = null;
  for (let j = i; j >= 0 && course == null; j--) if (moved(pts[j], pts[j + 1])) course = bearing(pts[j], pts[j + 1]);
  for (let j = i + 1; j < pts.length - 1 && course == null; j++) if (moved(pts[j], pts[j + 1])) course = bearing(pts[j], pts[j + 1]);
  return { lat: a[1] + (b[1] - a[1]) * k, lon: a[2] + (b[2] - a[2]) * k, course,
    kmh: a[3] == null ? null : a[3] + ((b[3] ?? a[3]) - a[3]) * k };
}
function nearestTime(lat, lon) {
  const pts = detail.points, kx = Math.cos(lat * Math.PI / 180);
  let best = null, bd = Infinity;
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1], b = pts[i];
    const x0 = a[2] * kx, y0 = a[1], dx = (b[2] - a[2]) * kx, dy = b[1] - a[1];
    const L = dx * dx + dy * dy;
    let u = L > 0 ? ((lon * kx - x0) * dx + (lat - y0) * dy) / L : 0;
    u = Math.max(0, Math.min(1, u));
    const d = Math.hypot(x0 + dx * u - lon * kx, y0 + dy * u - lat);
    if (d < bd) { bd = d; best = a[0] + (b[0] - a[0]) * u; }
  }
  return best;
}

// ---------- видео: несколько роликов как одна лента ----------
function tripStart() { return detail.clips[0].start; }
function tripEnd() { const c = detail.clips[detail.clips.length - 1]; return c.start + c.duration; }
function clipIndexAt(t) {
  const cs = detail.clips;
  for (let i = 0; i < cs.length; i++) if (t < cs[i].start + cs[i].duration) return i;
  return cs.length - 1;
}
function loadInto(video, idx) {
  video.dataset.idx = idx;
  video.src = `/video/${detail.clips[idx].id}`;
  video.load();
}
function swap() {
  [active, standby] = [standby, active];
  [activeIdx, standbyIdx] = [standbyIdx, activeIdx];
  active.hidden = false; standby.hidden = true;
  standby.pause();
}
function seekTo(t, play) {
  if (!detail || !detail.clips.length) return;
  t = Math.max(tripStart(), Math.min(tripEnd() - 0.05, t));
  const wasPlaying = play ?? !active.paused;
  const idx = clipIndexAt(t);
  const c = detail.clips[idx];
  const pos = Math.max(0, t - c.start);
  if (idx === activeIdx) {
    active.currentTime = pos;
    if (wasPlaying) active.play();
  } else if (idx === standbyIdx && standby.readyState >= 1) {
    swap();
    active.currentTime = pos;
    if (wasPlaying) active.play();
  } else {
    activeIdx = idx;
    pendingSeek = { pos, play: wasPlaying };
    loadInto(active, idx);
  }
  render(t);
}
for (const v of [$('va'), $('vb')]) {
  v.addEventListener('loadedmetadata', () => {
    if (v !== active || !pendingSeek) return;
    v.currentTime = pendingSeek.pos;
    if (pendingSeek.play) v.play();
    pendingSeek = null;
  });
  v.addEventListener('ended', () => {
    if (v !== active) return;
    const next = activeIdx + 1;
    if (next >= detail.clips.length) { $('play').textContent = '▶'; return; }
    if (standbyIdx === next && standby.readyState >= 2) {
      swap();
      active.currentTime = 0;
      active.play();
    } else {
      // следующий ролик не успел подгрузиться — грузим его в тот же плеер с начала
      activeIdx = next;
      pendingSeek = { pos: 0, play: true };
      loadInto(active, next);
    }
  });
  v.addEventListener('play', () => { if (v === active) $('play').textContent = '❚❚'; });
  v.addEventListener('pause', () => { if (v === active) $('play').textContent = '▶'; });
}
function currentTime() {
  if (activeIdx < 0) return null;
  return detail.clips[activeIdx].start + active.currentTime;
}
function preloadNext() {
  const next = activeIdx + 1;
  if (next >= detail.clips.length || standbyIdx === next) return;
  const c = detail.clips[activeIdx];
  if (c.duration - active.currentTime < 15) { standbyIdx = next; loadInto(standby, next); }
}

function render(t) {
  if (t == null) return;
  if (!dragging) $('seek').value = t - tripStart();
  const phone = t + detail.offset;
  const p = posAt(phone);
  $('t-phone').textContent = hms(phone, true) + (p && p.kmh != null ? ` · ${Math.round(p.kmh)} км/ч` : '');
  $('t-cam').textContent = `регистратор ${hms(t)} · ${detail.clips[clipIndexAt(t)].name}`;
  if (p && map && car) {
    car.setLngLat([p.lon, p.lat]);
    if (!car._map) car.addTo(map);
    if (p.course != null) car.setRotation(p.course);
    if ($('follow').checked && !map.isMoving()) {
      const px = map.project([p.lon, p.lat]), c = map.getContainer();
      if (px.x < 60 || px.y < 60 || px.x > c.clientWidth - 60 || px.y > c.clientHeight - 60)
        map.easeTo({ center: [p.lon, p.lat], duration: 400 });
    }
  } else if (car && car._map) car.remove();
}
function loop() {
  if (detail && activeIdx >= 0) { const t = currentTime(); render(t); preloadNext(); }
  requestAnimationFrame(loop);
}

$('play').onclick = () => { if (active.paused) active.play(); else active.pause(); };
$('seek').addEventListener('input', () => { dragging = true; render(tripStart() + +$('seek').value); });
$('seek').addEventListener('change', () => { dragging = false; seekTo(tripStart() + +$('seek').value); });
document.addEventListener('keydown', (e) => {
  if (!detail || e.target.tagName === 'INPUT' && e.target.type !== 'range') return;
  if (e.code === 'Space') { e.preventDefault(); $('play').click(); }
  if (e.code === 'ArrowRight') seekTo(currentTime() + 5);
  if (e.code === 'ArrowLeft') seekTo(currentTime() - 5);
});

// ---------- выбор поездки ----------
async function selectTrip(key, keepPosition, trackChanged) {
  const keepT = keepPosition && detail && detail.key === key ? currentTime() : null;
  selKey = key;
  renderTrips();
  const q = selTrack ? `?track=${selTrack}` : '';
  detail = await api(`/api/trips/${key}${q}`);
  await mapReady;
  drawTrip();
  const banner = $('banner');
  banner.hidden = true; banner.className = '';
  if (detail.track && detail.track.synthetic) {
    banner.hidden = false;
    banner.textContent = 'Трек СИНТЕТИЧЕСКИЙ: скорость из кадра, разложенная по форме маршрута со сдвигом часов. Для отладки синхронизации, не правда о поездке.';
  } else if (detail.stage !== 'ready' && !['no_gpx', 'no_anchors', 'before_history'].includes(detail.stage)) {
    banner.hidden = false; banner.className = 'warn';
    banner.textContent = `${STAGE[detail.stage] || detail.stage}: машинка на карте может расходиться с видео.`;
  }
  const s = detail.sync, sum = detail.summary;
  let legend = `<div class="bar"></div><div style="display:flex;justify-content:space-between"><span>0</span><span>40</span><span>80+ км/ч</span></div>`;
  if (detail.model === 'anchored') {
    legend += `<div>Старая поездка: время только у проездов камер (● опоры). Между опорами машинка идёт по скорости из кадра, подогнанной под следующую опору.</div>`;
    if (sum) legend += `<div>Опор в видео: ${sum.anchors_used} из ${sum.anchors}; невязка перегона медиана <b>${sum.residual_median_m ?? '—'} м</b>, макс ${sum.residual_max_m ?? '—'} м — на столько машинка может ошибаться между опорами.</div>`;
  } else if (s && s.method === 'speed') {
    legend += `<div>${esc(syncText(s))}${s.good ? '' : ' — не годится'}</div>`;
  }
  legend += `<div>Подложка: ${esc(styleNote)}</div>`;
  $('legend').innerHTML = legend;
  // видео
  $('novideo').hidden = !!detail.clips.length;
  $('play').disabled = $('seek').disabled = !detail.clips.length;
  if (!detail.clips.length) return;
  $('seek').max = tripEnd() - tripStart();
  activeIdx = standbyIdx = -1;
  active.removeAttribute('src'); standby.removeAttribute('src');
  standby.hidden = true; active.hidden = false;
  seekTo(keepT ?? tripStart(), false);
}

initMap();
loadTrips();
requestAnimationFrame(loop);
