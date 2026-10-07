'use strict';
// «Разбор видео»: находки детекторов на карте, карточка находки с вырезками,
// решения Принять/Отклонить и быстрая разметка «да/нет» для обучения.
// Общие функции (api, esc, $, map, mapReady) — из app.js.

const CLS_NAME = { traffic_light: 'Светофор', speed_limit: 'Знак ограничения', crossing: 'Пешеходный переход',
  speed_bump: 'Неровность? (рывок)' };
const ST_NAME = { new: 'новое', confirms: 'подтверждает', differs: 'расходится' };
const ST_COLOR = { new: '#1f6feb', confirms: '#1a7f37', differs: '#d97706' };
const CLS_STROKE = { traffic_light: '#111', speed_limit: '#c62828', crossing: '#1565c0', speed_bump: '#8d6e63' };
let tab = 'trips', finds = [], selFind = null, labelItem = null;

// ---------- вкладки ----------
for (const b of document.querySelectorAll('#tabs button')) {
  b.onclick = () => setTab(b.dataset.tab);
}
function setTab(t) {
  tab = t;
  for (const b of document.querySelectorAll('#tabs button')) b.classList.toggle('on', b.dataset.tab === t);
  for (const p of document.querySelectorAll('.pane')) p.hidden = p.id !== t;
  $('labeler').hidden = t !== 'label';
  if (t !== 'finds') $('card').hidden = true;
  if (t === 'finds') loadFinds();
  if (t === 'label') nextLabel();
}

// ---------- слой находок ----------
async function ensureFindLayer() {
  await mapReady;
  if (map.getSource('finds')) return;
  map.addSource('finds', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
  map.addSource('rays', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
  map.addLayer({ id: 'rays', type: 'line', source: 'rays',
    paint: { 'line-color': '#8250df', 'line-width': 1.5, 'line-opacity': 0.8 } });
  map.addLayer({ id: 'finds', type: 'circle', source: 'finds',
    paint: {
      'circle-radius': ['interpolate', ['linear'], ['zoom'], 11, 3, 16, 8],
      'circle-color': ['match', ['get', 'status'], 'new', ST_COLOR.new, 'confirms', ST_COLOR.confirms,
        'differs', ST_COLOR.differs, '#888'],
      'circle-stroke-color': ['match', ['get', 'cls'], 'traffic_light', CLS_STROKE.traffic_light,
        'speed_limit', CLS_STROKE.speed_limit, 'crossing', CLS_STROKE.crossing,
        'speed_bump', CLS_STROKE.speed_bump, '#fff'],
      'circle-stroke-width': ['case', ['==', ['get', 'sel'], true], 4, 2],
      'circle-opacity': ['case', ['==', ['get', 'decision'], 'reject'], 0.3, 1],
    } });
  map.on('click', 'finds', (e) => openFind(e.features[0].properties.id));
  map.on('mouseenter', 'finds', () => { map.getCanvas().style.cursor = 'pointer'; });
  map.on('mouseleave', 'finds', () => { map.getCanvas().style.cursor = ''; });
}
function drawFinds() {
  if (!map || !map.getSource('finds')) return;
  map.getSource('finds').setData({ type: 'FeatureCollection', features: finds.map((f) => ({
    type: 'Feature', geometry: { type: 'Point', coordinates: [f.lon, f.lat] },
    properties: { id: f.id, cls: f.cls, status: f.status, decision: f.decision || '', sel: f.id === selFind } })) });
}

function findQuery() {
  const p = new URLSearchParams();
  if ($('f-cls').value) p.set('cls', $('f-cls').value);
  if ($('f-status').value) p.set('status', $('f-status').value);
  if ($('f-dec').value) p.set('decision', $('f-dec').value);
  p.set('min_conf', $('f-conf').value);
  return p.toString();
}
async function loadFinds() {
  await ensureFindLayer();
  finds = await api('/api/findings?' + findQuery());
  const by = {};
  for (const f of finds) by[f.status] = (by[f.status] || 0) + 1;
  $('finds-count').textContent = `${finds.length} находок · ` +
    Object.entries(by).map(([k, v]) => `${ST_NAME[k] || k} ${v}`).join(', ');
  const box = $('finds-list');
  box.innerHTML = '';
  for (const f of finds.slice(0, 300)) {
    const d = document.createElement('div');
    d.className = 'find' + (f.id === selFind ? ' sel' : '') + (f.decision ? ' dec-' + f.decision : '');
    d.innerHTML = `<b>${esc(CLS_NAME[f.cls] || f.cls)}${f.value ? ' ' + f.value : ''}</b>
      <span class="st ${f.status}">${esc(ST_NAME[f.status] || f.status)}</span>
      <div class="muted">${Math.round(f.confidence * 100)} % · поездок ${f.n_trips} · кадров ${f.n_frames}
      · ±${f.err_m ?? '—'} м${f.decision ? ' · ' + (f.decision === 'accept' ? 'принято' : 'отклонено') : ''}</div>`;
    d.onclick = () => openFind(f.id, true);
    box.appendChild(d);
  }
  if (finds.length > 300) box.insertAdjacentHTML('beforeend', `<div class="muted">… и ещё ${finds.length - 300} (сузьте фильтр)</div>`);
  drawFinds();
}
for (const id of ['f-cls', 'f-status', 'f-dec']) $(id).onchange = loadFinds;
$('f-conf').oninput = () => { $('f-conf-v').textContent = $('f-conf').value; };
$('f-conf').onchange = loadFinds;

// ---------- карточка ----------
async function openFind(id, fly) {
  selFind = id;
  const f = await api(`/api/findings/${id}`);
  drawFinds();
  for (const el of document.querySelectorAll('.find')) el.classList.remove('sel');
  const ref = f.map_ref || {};
  let refText = 'в нашей карте рядом ничего нет';
  if (ref.near === 'osm_signal') refText = `светофор OSM в ${ref.dist_m} м`;
  if (ref.near === 'osm_crossing') refText = `переход OSM в ${ref.dist_m} м`;
  if (ref.near === 'maxspeed') refText = `лимит дороги рядом: ${ref.values.join(', ')} км/ч (${ref.dist_m} м)`;
  const card = $('card');
  card.hidden = false;
  card.innerHTML = `<h2>${esc(CLS_NAME[f.cls] || f.cls)}${f.value ? ' ' + f.value + ' км/ч' : ''}</h2>
    <div><span class="st ${f.status}">${esc(ST_NAME[f.status] || f.status)}</span> · ${esc(refText)}</div>
    <div class="crops">${f.crops.map((c) => `<img src="${c.url}" title="${esc(c.trip)} · ${Math.round(c.conf * 100)} %">`).join('')}</div>
    <div class="muted">уверенность ${Math.round(f.confidence * 100)} % · поездок ${f.n_trips} · кадров ${f.n_frames}
      · точность места ±${f.err_m ?? '—'} м</div>
    <div class="muted">${f.objects.map((o) => `${esc(o.trip)}: ${o.method === 'tri' ? 'триангуляция' : 'по размеру'}
      ±${o.err_m} м, кадров ${o.n_frames}, вес привязки ${o.weight ?? '—'}`).join('<br>')}</div>
    <div class="btns"><button class="acc" id="c-acc">Принять (A)</button><button class="rej" id="c-rej">Отклонить (R)</button>
      ${f.decision ? '<button id="c-clr">Сбросить</button>' : ''}</div>
    ${f.decision ? `<div class="muted">решение: ${f.decision === 'accept' ? 'принято' : 'отклонено'}</div>` : ''}`;
  for (const img of card.querySelectorAll('.crops img')) img.onclick = () => window.open(img.src, '_blank');
  $('c-acc').onclick = () => decide('accept');
  $('c-rej').onclick = () => decide('reject');
  if ($('c-clr')) $('c-clr').onclick = () => decide('clear');
  map.getSource('rays').setData({ type: 'FeatureCollection', features: f.rays.map((r) => ({
    type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: [[r[1], r[0]], [f.lon, f.lat]] } })) });
  if (fly) map.easeTo({ center: [f.lon, f.lat], zoom: Math.max(map.getZoom(), 16), duration: 400 });
}
async function decide(d) {
  if (!selFind) return;
  await api(`/api/findings/${selFind}/decision`, { decision: d });
  const cur = finds.findIndex((f) => f.id === selFind);
  if (cur >= 0) finds[cur].decision = d === 'clear' ? null : d;
  drawFinds();
  if (d !== 'clear' && cur >= 0 && cur + 1 < finds.length) openFind(finds[cur + 1].id, true);
  else openFind(selFind);
  loadFinds();
}
function stepFind(k) {
  if (!finds.length) return;
  const cur = finds.findIndex((f) => f.id === selFind);
  const n = Math.max(0, Math.min(finds.length - 1, cur + k));
  openFind(finds[n].id, true);
}

// ---------- разметка ----------
async function nextLabel() {
  const cls = $('l-cls').value;
  labelItem = await api('/api/label/next' + (cls ? `?cls=${cls}` : ''));
  const st = await api('/api/label/stats');
  $('label-stats').innerHTML = Object.entries(st).map(([k, v]) => `${esc(CLS_NAME[k] || k)}: да ${v.yes || 0}, нет ${v.no || 0}
    из ${v.total || 0}`).join('<br>');
  if (labelItem.done) {
    $('l-q').textContent = 'Всё размечено';
    $('l-img').removeAttribute('src');
    $('l-meta').textContent = '';
    return;
  }
  const what = labelItem.cls === 'traffic_light' ? `Горящий светофор (${labelItem.color})?`
    : labelItem.cls === 'speed_limit' ? `Знак «ограничение ${labelItem.value}»?` : 'Знак «пешеходный переход»?';
  $('l-q').textContent = what;
  $('l-img').src = labelItem.url;
  $('l-meta').textContent = `уверенность детектора ${Math.round(labelItem.conf * 100)} % · рамка — в центре вырезки`;
}
async function answer(a) {
  if (!labelItem || labelItem.done) return;
  await api('/api/label', { det_id: labelItem.det_id, answer: a });
  nextLabel();
}
$('l-yes').onclick = () => answer('yes');
$('l-no').onclick = () => answer('no');
$('l-skip').onclick = () => answer('skip');
$('l-cls').onchange = nextLabel;

document.addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT' && e.target.type !== 'range' || e.target.tagName === 'SELECT') return;
  if (tab === 'label') {
    const k = e.key.toLowerCase();
    if (k === 'y' || k === 'н') answer('yes');
    else if (k === 'n' || k === 'т') answer('no');
    else if (k === 's' || k === 'ы') answer('skip');
    else return;
    e.preventDefault(); e.stopImmediatePropagation();
  } else if (tab === 'finds') {
    const k = e.key.toLowerCase();
    if (k === 'a' || k === 'ф') decide('accept');
    else if (k === 'r' || k === 'к') decide('reject');
    else if (e.code === 'ArrowRight') stepFind(1);
    else if (e.code === 'ArrowLeft') stepFind(-1);
    else return;
    e.preventDefault(); e.stopImmediatePropagation();
  }
}, true);
