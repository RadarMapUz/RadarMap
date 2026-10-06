// Симулятор поездки по нашей карте: 3D-машина, полосы, манёвры, светофоры,
// камеры, подсказка полосы.
//
// Всё — наши данные (route.json из make_route.py): маршрут нашего OSRM,
// посаженный на нашу сеть (ширина и число полос своего направления),
// стрелки turn:lanes, светофоры OSM, камеры нашей базы. Машина — объёмные
// примитивы (fill-extrusion из GeoJSON): тот же приём есть в MapLibre Native.
(function () {
  'use strict';

  // --- Настройки --------------------------------------------------------
  const LANE_CHANGE_SECONDS = 3.0;      // длительность перестроения
  const SIGNAL_LEAD_SECONDS = 1.4;      // поворотник до начала манёвра
  const PREPARE_METERS = 320;           // с какого расстояния встаём в полосу манёвра
  const ACCEL = 1.6, BRAKE = 2.6;       // м/с²
  const SIGNAL_CYCLE = [26, 4, 22];     // зелёный, жёлтый, красный, с
  const STOP_BEFORE_SIGNAL = 4;         // м до точки светофора
  const CAMERA_WARN_METERS = 350;
  const KM = 111320;
  const VIEWS = {
    chase: { zoom: 19.2, pitch: 62, ahead: 10 },
    top: { zoom: 18.2, pitch: 0, ahead: 0 },
    heli: { zoom: 17.4, pitch: 45, ahead: 40 },
  };

  const params = new URLSearchParams(location.search);
  let seed = Number(params.get('seed') || 7) >>> 0;
  function random() {
    seed = (seed + 0x6D2B79F5) >>> 0;
    let t = seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  const map = new maplibregl.Map({ container: 'map', style: params.get('style') || 'st_light_full.json',
                                   center: [69.2052, 41.2742], zoom: 17, pitch: 60, antialias: true });

  let route = null;
  const ui = { paused: false, rate: 1, view: 'chase', wander: true };
  const car = { s: 0, v: 0, lane: 0, toLane: 0, fromOffset: 0, changeStart: -1, signal: 0,
                signalSince: 0, holdUntil: 4, time: 0, yaw: 0, x: 0, y: 0, lanes: 1, why: '',
                light: null, wanted: null, maneuver: null };

  // --- Геометрия маршрута ------------------------------------------------
  function prepare(data) {
    const origin = [data.points[0][0], data.points[0][1]];
    const kx = KM * Math.cos(origin[1] * Math.PI / 180);
    let s = 0;
    const pts = [];
    data.points.forEach(function (p, i) {
      const x = (p[0] - origin[0]) * kx, y = (p[1] - origin[1]) * KM;
      if (i > 0) { s += Math.hypot(x - pts[i - 1].x, y - pts[i - 1].y); }
      pts.push({ x: x, y: y, s: s, width: p[2], lanes: Math.max(1, p[3]), speed: p[4] || 40 });
    });
    return { origin: origin, kx: kx, points: pts, length: s, maneuvers: data.maneuvers || [],
             signals: data.signals || [], cameras: data.cameras || [] };
  }
  function toLonLat(x, y) { return [route.origin[0] + x / route.kx, route.origin[1] + y / KM]; }

  function sample(s) {
    const pts = route.points;
    let lo = 0, hi = pts.length - 1;
    while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (pts[mid].s < s) { lo = mid; } else { hi = mid; } }
    const a = pts[lo], b = pts[hi];
    const t = Math.max(0, Math.min(1, (s - a.s) / Math.max(0.01, b.s - a.s)));
    // Касательная — по отрезку пошире, чтобы курс не дрожал на 5-метровых шагах.
    const ia = Math.max(0, lo - 2), ib = Math.min(pts.length - 1, hi + 2);
    const tx = pts[ib].x - pts[ia].x, ty = pts[ib].y - pts[ia].y;
    const len = Math.hypot(tx, ty) || 1;
    return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, tx: tx / len, ty: ty / len,
             width: a.width, lanes: a.lanes, speed: a.speed };
  }
  function laneOffset(lane, at) {
    const w = at.width / at.lanes;
    return -at.width / 2 + w * (lane + 0.5);
  }
  function smoothstep(t) { return t * t * (3 - 2 * t); }

  // --- Решения ----------------------------------------------------------
  function nextManeuver(s) {
    return route.maneuvers.find(function (m) { return m.s > s + 1 && m.kind !== 'depart'; }) || null;
  }
  // Полосы, из которых манёвр разрешён: по стрелкам подхода; без них — крайняя
  // по направлению поворота; прямо — любая.
  function wantedLanes(m, lanes) {
    if (!m) { return null; }
    if (m.lanes && m.lanes.length) {
      const ok = m.lanes.filter(function (l) { return l < lanes; });
      return ok.length ? ok : null;
    }
    const mod = m.modifier || 'straight';
    if (mod.indexOf('left') >= 0 || mod === 'uturn') { return [0]; }
    if (mod.indexOf('right') >= 0) { return [lanes - 1]; }
    return null;
  }
  function signalPhase(s, time) {
    // Цикл общий, фаза у каждого светофора своя — от его места на маршруте.
    const cycle = SIGNAL_CYCLE[0] + SIGNAL_CYCLE[1] + SIGNAL_CYCLE[2];
    const t = (time + (s * 7.3) % cycle) % cycle;
    if (t < SIGNAL_CYCLE[0]) { return 'green'; }
    if (t < SIGNAL_CYCLE[0] + SIGNAL_CYCLE[1]) { return 'yellow'; }
    return 'red';
  }

  function startChange(dir, why) {
    car.signal = dir;
    car.signalSince = car.time;
    car.why = why;
  }

  function step(dt) {
    car.time += dt;
    const at = sample(car.s);
    car.lanes = at.lanes;
    if (car.lane >= at.lanes) {
      car.lane = at.lanes - 1; car.toLane = car.lane; car.changeStart = -1; car.signal = 0;
    }

    // Скорость: лимит участка, плавные разгон и торможение; на красный — стоп
    // у стоп-линии, на жёлтый — стоп, если успеваем затормозить.
    let target = at.speed / 3.6;
    const light = route.signals.find(function (s) { return s > car.s && s - car.s < 150; });
    car.light = null;
    if (light !== undefined) {
      const phase = signalPhase(light, car.time);
      car.light = { distance: light - car.s, phase: phase };
      const stopAt = light - STOP_BEFORE_SIGNAL - car.s;
      const brakeNeed = car.v * car.v / (2 * BRAKE);
      if (phase !== 'green' && stopAt > 0 && (phase === 'red' || stopAt > brakeNeed)) {
        target = Math.min(target, Math.sqrt(Math.max(0, 2 * BRAKE * stopAt)) * 0.9);
        if (stopAt < 1.2) { target = 0; }
      }
    }
    car.v = car.v < target ? Math.min(target, car.v + ACCEL * dt) : Math.max(target, car.v - BRAKE * dt);
    car.s += car.v * dt;
    if (car.s >= route.length - 2) {
      Object.assign(car, { s: 0, v: 0, lane: 0, toLane: 0, changeStart: -1, signal: 0 });
    }

    // Полоса: перед манёвром — в нужную; вдали от манёвров — иногда обгон.
    const m = nextManeuver(car.s);
    const ahead = m ? m.s - car.s : Infinity;
    const wanted = ahead < PREPARE_METERS ? wantedLanes(m, at.lanes) : null;
    car.wanted = wanted;
    car.maneuver = m;
    if (car.changeStart < 0 && car.signal === 0 && car.v > 2) {
      if (wanted && wanted.indexOf(car.lane) < 0) {
        const nearest = wanted.reduce(function (a, b) {
          return Math.abs(b - car.lane) < Math.abs(a - car.lane) ? b : a;
        });
        startChange(nearest > car.lane ? 1 : -1, 'к манёвру');
      } else if (ui.wander && !wanted && ahead > PREPARE_METERS && car.time > car.holdUntil && at.lanes > 1) {
        const options = [];
        if (car.lane > 0) { options.push(-1); }
        if (car.lane < at.lanes - 1) { options.push(1); }
        startChange(options[Math.floor(random() * options.length)], 'обгон');
      }
    }
    if (car.signal !== 0 && car.changeStart < 0 && car.time - car.signalSince >= SIGNAL_LEAD_SECONDS) {
      car.fromOffset = laneOffset(car.lane, at);
      car.toLane = Math.max(0, Math.min(at.lanes - 1, car.lane + car.signal));
      car.changeStart = car.time;
    }
    let offset = laneOffset(car.lane, at), drift = 0;
    if (car.changeStart >= 0) {
      const t = Math.min(1, (car.time - car.changeStart) / LANE_CHANGE_SECONDS);
      const goal = laneOffset(car.toLane, at);
      offset = car.fromOffset + (goal - car.fromOffset) * smoothstep(t);
      drift = (goal - car.fromOffset) * 6 * t * (1 - t) / LANE_CHANGE_SECONDS;
      if (t >= 1) {
        car.lane = car.toLane;
        car.changeStart = -1;
        car.signal = 0;
        car.holdUntil = car.time + 6 + random() * 6;
      }
    }
    car.x = at.x + at.ty * offset;
    car.y = at.y - at.tx * offset;
    car.yaw = Math.atan2(at.tx, at.ty) + Math.atan2(drift, Math.max(car.v, 1));
  }

  // --- Машина и светофоры -----------------------------------------------
  function box(left, right, back, front) {
    const sin = Math.sin(car.yaw), cos = Math.cos(car.yaw);
    return [[left, back], [right, back], [right, front], [left, front], [left, back]].map(function (c) {
      return toLonLat(car.x + c[0] * cos + c[1] * sin, car.y - c[0] * sin + c[1] * cos);
    });
  }
  function part(ring, base, height, color) {
    return { type: 'Feature', geometry: { type: 'Polygon', coordinates: [ring] },
             properties: { base: base, height: height, color: color } };
  }
  function carShape() {
    const blink = Math.floor(car.time * 2.5) % 2 === 0;
    const braking = car.light && car.light.phase !== 'green' && car.v < 8;
    const parts = [
      part(box(-0.92, 0.92, -2.25, 2.25), 0.28, 0.98, '#2f6fdd'),
      part(box(-0.86, 0.86, -2.0, 1.4), 0.98, 1.05, '#2a62c4'),
      part(box(-0.80, 0.80, -1.25, 0.85), 1.05, 1.42, '#24324a'),
      part(box(-0.74, 0.74, -1.05, 0.65), 1.42, 1.47, '#2f6fdd'),
      part(box(-0.95, -0.55, 1.45, 1.95), 0.0, 0.62, '#1c1f24'),
      part(box(0.55, 0.95, 1.45, 1.95), 0.0, 0.62, '#1c1f24'),
      part(box(-0.95, -0.55, -1.85, -1.35), 0.0, 0.62, '#1c1f24'),
      part(box(0.55, 0.95, -1.85, -1.35), 0.0, 0.62, '#1c1f24'),
      part(box(-0.85, -0.45, 2.22, 2.3), 0.62, 0.82, '#fff6d6'),
      part(box(0.45, 0.85, 2.22, 2.3), 0.62, 0.82, '#fff6d6'),
      part(box(-0.85, -0.45, -2.3, -2.22), 0.68, 0.86, braking ? '#ff1744' : '#a31515'),
      part(box(0.45, 0.85, -2.3, -2.22), 0.68, 0.86, braking ? '#ff1744' : '#a31515'),
    ];
    if (car.signal !== 0 && blink) {
      const side = car.signal > 0 ? [0.82, 0.96] : [-0.96, -0.82];
      parts.push(part(box(side[0], side[1], 2.0, 2.3), 0.6, 0.88, '#ffab00'));
      parts.push(part(box(side[0], side[1], -2.3, -2.0), 0.6, 0.88, '#ffab00'));
    }
    return { type: 'FeatureCollection', features: parts };
  }
  function lightsShape() {
    const features = [];
    route.signals.forEach(function (s) {
      if (Math.abs(s - car.s) > 400) { return; }
      const at = sample(s);
      const x = at.x + at.ty * (at.width / 2 + 1.2), y = at.y - at.tx * (at.width / 2 + 1.2);
      const phase = signalPhase(s, car.time);
      const colour = phase === 'green' ? '#00c853' : phase === 'yellow' ? '#ffd600' : '#ff1744';
      const ring = function (r) {
        const out = [];
        for (let i = 0; i <= 8; i += 1) {
          const a = i / 8 * Math.PI * 2;
          out.push(toLonLat(x + Math.cos(a) * r, y + Math.sin(a) * r));
        }
        return out;
      };
      features.push(part(ring(0.15), 0, 3.2, '#3b3b3b'));
      features.push(part(ring(0.35), 3.2, 4.0, colour));
    });
    return { type: 'FeatureCollection', features: features };
  }

  // --- Экран ------------------------------------------------------------
  const TURN_ICON = { 1: '↑', 2: '↰', 3: '↱', 4: '↖', 5: '↗', 6: '↶', 7: '↰↑', 8: '↑↱', 9: '↰↱', 0: '·' };
  function maneuverText(m) {
    if (!m) { return ''; }
    const mod = m.modifier || '';
    const word = m.kind === 'arrive' ? 'прибытие' :
      mod.indexOf('left') >= 0 ? 'налево' : mod.indexOf('right') >= 0 ? 'направо' :
      mod === 'uturn' ? 'разворот' : 'прямо';
    return word + (m.name ? ' — ' + m.name : '');
  }
  function hud() {
    const m = car.maneuver;
    const ahead = m ? Math.max(0, m.s - car.s) : 0;
    const lanes = [];
    for (let i = 0; i < car.lanes; i += 1) {
      const code = m && m.turns && m.turns.length && ahead < PREPARE_METERS ? m.turns[i] : null;
      const good = car.wanted ? car.wanted.indexOf(i) >= 0 : false;
      lanes.push('<span class="lane' + (i === car.lane ? ' me' : '') + (good ? ' good' : '') + '">' +
                 (code !== null && code !== undefined ? (TURN_ICON[code] || '·') : (i === car.lane ? '●' : '')) +
                 '</span>');
    }
    const camera = route.cameras.find(function (c) { return c.s > car.s && c.s - car.s < CAMERA_WARN_METERS; });
    let html = '<div class="row"><b>' + Math.round(car.v * 3.6) + '</b> км/ч · лимит ' + sample(car.s).speed +
               '</div><div class="lanes">' + lanes.join('') + '</div>';
    if (m) { html += '<div class="row">через ' + Math.round(ahead) + ' м: ' + maneuverText(m) + '</div>'; }
    if (car.wanted && ahead < PREPARE_METERS) {
      html += '<div class="row hint">займите ' + car.wanted.map(function (l) { return l + 1; }).join(', ') +
              '-ю полосу' + (m.turns && m.turns.length ? '' : ' (по направлению поворота)') + '</div>';
    }
    if (car.signal) { html += '<div class="row">' + (car.signal > 0 ? '→' : '←') + ' перестроение · ' + car.why + '</div>'; }
    if (car.light) {
      html += '<div class="row">светофор ' + Math.round(car.light.distance) + ' м · ' +
              ({ green: 'зелёный', yellow: 'жёлтый', red: 'красный' })[car.light.phase] + '</div>';
    }
    if (camera) { html += '<div class="row warn">' + camera.type + ', ' + Math.round(camera.s - car.s) + ' м</div>'; }
    html += '<div class="row muted">' + Math.round(car.s) + ' / ' + Math.round(route.length) + ' м</div>';
    document.getElementById('hud').innerHTML = html;
  }

  let cameraHeading = null;
  function draw(dt) {
    map.getSource('car').setData(carShape());
    map.getSource('lights').setData(lightsShape());
    const deg = car.yaw * 180 / Math.PI;
    if (cameraHeading === null) { cameraHeading = deg; }
    const diff = ((deg - cameraHeading + 540) % 360) - 180;
    cameraHeading += dt > 0 ? diff * Math.min(1, dt * 2.2) : diff;
    const view = VIEWS[ui.view] || VIEWS.chase;
    const rad = cameraHeading * Math.PI / 180;
    map.jumpTo({ center: toLonLat(car.x + Math.sin(rad) * view.ahead, car.y + Math.cos(rad) * view.ahead),
                 bearing: ui.view === 'top' ? 0 : cameraHeading, pitch: view.pitch, zoom: view.zoom });
    hud();
  }

  let last = null;
  function frame(now) {
    const dt = last === null ? 0 : Math.min(0.1, (now - last) / 1000);
    last = now;
    if (!ui.paused) {
      const total = dt * ui.rate;
      const steps = Math.max(1, Math.ceil(total / 0.05));
      for (let i = 0; i < steps; i += 1) { step(total / steps); }
    }
    draw(ui.paused ? 0 : dt);
    requestAnimationFrame(frame);
  }

  function controls() {
    const pause = document.getElementById('pause');
    if (!pause) { return; }
    pause.onclick = function () {
      ui.paused = !ui.paused;
      pause.textContent = ui.paused ? '▶' : '❚❚';
    };
    document.querySelectorAll('[data-rate]').forEach(function (b) {
      b.onclick = function () { ui.rate = Number(b.dataset.rate); };
    });
    document.querySelectorAll('[data-view]').forEach(function (b) {
      b.onclick = function () { ui.view = b.dataset.view; };
    });
    document.getElementById('wander').onchange = function () { ui.wander = this.checked; };
    document.getElementById('restart').onclick = function () {
      Object.assign(car, { s: 0, v: 0, lane: 0, toLane: 0, changeStart: -1, signal: 0 });
    };
  }

  map.on('error', function (e) {
    document.getElementById('hud').textContent = 'ошибка карты: ' + (e.error && e.error.message);
  });
  map.on('load', function () {
    fetch(params.get('route') || 'route.json').then(function (r) { return r.json(); }).then(function (data) {
      route = prepare(data);
      const layer = function (id, source) {
        map.addSource(source, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
        map.addLayer({ id: id, type: 'fill-extrusion', source: source,
                       paint: { 'fill-extrusion-color': ['get', 'color'], 'fill-extrusion-base': ['get', 'base'],
                                'fill-extrusion-height': ['get', 'height'], 'fill-extrusion-opacity': 1 } });
      };
      layer('sim-lights', 'lights');
      layer('sim-car', 'car');
      controls();
      // ?t=секунды — детерминированный кадр для проверки (?view=top|heli).
      if (params.has('t')) {
        if (params.get('view')) { ui.view = params.get('view'); }
        const until = Number(params.get('t'));
        for (let time = 0; time < until; time += 0.05) { step(0.05); }
        draw(0);
        return;
      }
      requestAnimationFrame(frame);
    });
  });
})();
