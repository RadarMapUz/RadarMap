'use strict';
// «Разбор видео»: подпись кластеров знаков и слой покрытия дорог.
let signLabels = null;
const SHAPE_NAME = { red_circle: 'круг с красным кантом', blue_circle: 'синий круг', blue_square: 'синий квадрат',
  red_triangle: 'треугольник', red_inverted: 'треугольник вниз', red_octagon: 'восьмиугольник', yellow_diamond: 'ромб' };

const _setTab = setTab;
setTab = function (t) {   // вкладка «Знаки» — поверх карты, как разметка
  _setTab(t);
  $('signgrid').hidden = t !== 'signs';
  if (t === 'signs') loadSigns();
};

async function loadSigns() {
  if (!signLabels) signLabels = await api('/api/signs/labels');
  const q = new URLSearchParams();
  if ($('s-shape').value) q.set('shape', $('s-shape').value);
  if ($('s-all').checked) q.set('all', '1');
  const cl = await api('/api/signs/clusters?' + q);
  const grid = $('signgrid');
  grid.innerHTML = cl.length ? '' : '<div class="muted">Кластеров нет — разбор ещё идёт или всё подписано.</div>';
  $('signs-stats').textContent = `кластеров ${cl.length}, вырезок ${cl.reduce((s, c) => s + c.size, 0)}`;
  for (const c of cl) {
    const d = document.createElement('div');
    d.className = 'scl' + (c.label ? ' done' : '');
    const opts = signLabels.map((l) => `<option value="${l.key}">${esc(l.name)}</option>`).join('');
    d.innerHTML = `<div class="muted">${esc(SHAPE_NAME[c.shape] || c.shape)} · ${c.size} шт.${c.label ? ' · ' + esc(c.label) : ''}</div>
      <div class="g">${c.reps.map((r) => `<img src="${r.url}" loading="lazy">`).join('')}</div>
      <select><option value="">— класс —</option>${opts}</select>
      <input type="number" placeholder="число на знаке (для ограничения)" min="20" max="120" step="10" hidden>
      <div class="row"><button class="ok">Подписать</button><button class="sp">Разбить</button></div>`;
    const sel = d.querySelector('select'), num = d.querySelector('input');
    sel.onchange = () => { num.hidden = sel.value !== 'speed_limit'; };
    d.querySelector('.ok').onclick = async () => {
      if (!sel.value) return;
      try {
        await api(`/api/signs/clusters/${c.id}/label`, { label: sel.value, value: num.value ? +num.value : null });
        d.classList.add('done');
      } catch (e) { alert(e.message); }
    };
    d.querySelector('.sp').onclick = async () => { await api(`/api/signs/clusters/${c.id}/split`, {}); loadSigns(); };
    grid.appendChild(d);
  }
}
$('s-shape').onchange = loadSigns;
$('s-all').onchange = loadSigns;

// ---------- слой покрытия ----------
async function toggleCoverage() {
  await mapReady;
  if (!map.getSource('coverage')) {
    map.addSource('coverage', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map.addLayer({ id: 'coverage', type: 'circle', source: 'coverage',
      paint: { 'circle-radius': ['interpolate', ['linear'], ['zoom'], 11, 2, 16, 9],
        'circle-color': ['case', ['get', 'pinned'], '#0b5d1e',
          ['interpolate', ['linear'], ['get', 'passes'], 0, '#bbbbbb', 1, '#f2c94c', 3, '#7cb342']],
        'circle-opacity': 0.6 } }, map.getLayer('finds') ? 'finds' : undefined);
  }
  const on = $('f-cov').checked;
  map.setLayoutProperty('coverage', 'visibility', on ? 'visible' : 'none');
  if (!on) return;
  const cells = await api('/api/coverage');
  map.getSource('coverage').setData({ type: 'FeatureCollection', features: cells.map((c) => ({
    type: 'Feature', geometry: { type: 'Point', coordinates: [c.lon, c.lat] },
    properties: { passes: c.passes, pinned: c.pinned } })) });
}
$('f-cov').onchange = toggleCoverage;
