'use strict';
// «Разбор видео», вкладка «Камеры»: камеры фиксации по видео — кандидаты
// «новая» (устойчивый всплеск без камеры базы) и «возможно, снята» (днём на
// ходу проезжали ≥ 3 раз — и ни разу не увидели), плюс честные цифры
// классификатора и опознания. Данные — cams/run.py candidates → /api/cams.
// Общие функции (api, esc, $, map, mapReady, setTab) — из app.js / finds.js.

let camsData = null;

const _setTab3 = setTab;
setTab = function (t) {
  _setTab3(t);
  $('cams-card').hidden = true;
  if (t === 'cams') loadCams();
  else if (map && map.getLayer('cams-pts')) map.setLayoutProperty('cams-pts', 'visibility', 'none');
};

function pct(x) { return x == null ? '—' : Math.round(x * 100) + ' %'; }

function camsReport(r) {
  const out = [];
  const c = r.classifier;
  if (c) {
    const fv = c.frames_val || {};
    const ev = c['events_p' + camsData.p_min] || {};
    out.push(`<div><b>Классификатор</b> (${esc(c.model || '')}): по кадрам val ${pct(fv.acc)}
      (камера ${pct(fv.recall_camera)}, фон ${pct(fv.specificity)}); события: найдено ${pct(ev.recall)}
      проездов, точность ${pct(ev.precision)}, ложных ${ev.fp_per_10km ?? '—'} на 10 км</div>`);
  }
  const h = r.honest && r.honest.total;
  if (h) {
    out.push(`<div><b>Опознание без опор</b> (HMM, ${h.trips} поездок): из ${h.truth_passes} проездов верно
      ${h.correct} (${pct(h.share_correct_of_truth)}), ложных ${h.false}, пропущено ${h.missed}</div>`);
  }
  const o = r.honest_oracle && r.honest_oracle.total;
  if (o) {
    out.push(`<div class="muted">Потолок HMM при идеальных событиях: верно ${o.correct} из ${o.truth_passes},
      ложных ${o.false}</div>`);
  }
  return out.join('');
}

async function loadCams() {
  camsData = await api('/api/cams');
  const s = camsData.summary;
  $('cams-summary').innerHTML = s
    ? `«новая»: <b>${s.new}</b> · «снята?»: <b>${s.removed}</b> · камер подтверждено видео: ${s.cameras_seen}`
    : esc(camsData.note || 'нет данных');
  $('cams-report').innerHTML = camsReport(camsData.reports || {});
  const list = $('cams-list');
  list.innerHTML = '';
  const kind = $('cams-kind').value;
  const items = [...camsData.new.map((x) => ({ ...x, kind: 'new' })), ...camsData.removed.map((x) => ({ ...x, kind: 'removed' }))]
    .filter((x) => !kind || x.kind === kind);
  for (const it of items) {
    const d = document.createElement('div');
    d.className = 'cams-item ' + it.kind;
    d.innerHTML = it.kind === 'new'
      ? `<b>Новая?</b> ${it.trips.length} поездки · ${it.n_events} всплеска · ${pct(it.p)}`
      : `<b>Снята?</b> №${it.camera_id} · ${esc(it.location || '')} · ${it.passes} проездов без всплеска`;
    d.onclick = () => showCam(it);
    list.appendChild(d);
  }
  await drawCams(items);
}

async function drawCams(items) {
  await mapReady;
  const fc = { type: 'FeatureCollection', features: items.filter((x) => x.lat != null).map((x, i) => ({
    type: 'Feature', geometry: { type: 'Point', coordinates: [x.lon, x.lat] }, properties: { kind: x.kind, i } })) };
  if (!map.getSource('cams')) {
    map.addSource('cams', { type: 'geojson', data: fc });
    map.addLayer({ id: 'cams-pts', type: 'circle', source: 'cams', paint: {
      'circle-radius': ['interpolate', ['linear'], ['zoom'], 11, 4, 16, 9],
      'circle-color': ['match', ['get', 'kind'], 'new', '#1f6feb', '#d97706'],
      'circle-stroke-color': '#fff', 'circle-stroke-width': 1.5 } });
    map.on('click', 'cams-pts', (e) => {
      const f = e.features[0];
      const lst = [...camsData.new.map((x) => ({ ...x, kind: 'new' })), ...camsData.removed.map((x) => ({ ...x, kind: 'removed' }))]
        .filter((x) => !$('cams-kind').value || x.kind === $('cams-kind').value);
      if (lst[f.properties.i]) showCam(lst[f.properties.i]);
    });
  } else {
    map.getSource('cams').setData(fc);
  }
  map.setLayoutProperty('cams-pts', 'visibility', 'visible');
}

function showCam(it) {
  if (it.lat != null) map.flyTo({ center: [it.lon, it.lat], zoom: 16 });
  const card = $('cams-card');
  const imgs = (it.crops || []).map((c) => `<img src="/cams/crop/${encodeURIComponent(c)}" loading="lazy">`).join('');
  card.innerHTML = it.kind === 'new'
    ? `<h3>Возможно, новая камера</h3>
       <div class="muted">${it.lat.toFixed(6)}, ${it.lon.toFixed(6)} · курс ${it.course == null ? '—' : Math.round(it.course) + '°'}</div>
       <div>Всплеск в ${it.trips.length} поездках (${it.n_events} событий), уверенность до ${pct(it.p)}.
         Ближайшая камера базы: ${it.nearest_db ? '№' + it.nearest_db.id + ', ' + it.nearest_db.m + ' м' : 'нет в 300 м'}.</div>
       <div class="muted">Поездки: ${it.trips.map(esc).join(', ')}</div>`
    : `<h3>Возможно, снята: №${it.camera_id}</h3>
       <div class="muted">${esc(it.type || '')} · ${esc(it.location || '')}</div>
       <div>Днём на ходу проезжали ${it.passes} раз — классификатор ни разу не увидел камеру.
         Ниже — самые «камерные» кадры за 0,5–3 с до проезда.</div>
       <div class="muted">Поездки: ${it.trips.map(esc).join(', ')}</div>`;
  card.innerHTML += `<div class="cams-crops">${imgs || '<span class="muted">вырезок нет</span>'}</div>
    <div class="muted">Это кандидат, не правка: решение — за человеком (панель модератора).</div>
    <button id="cams-close">Закрыть</button>`;
  card.hidden = false;
  $('cams-close').onclick = () => { card.hidden = true; };
}

$('cams-kind').onchange = loadCams;
