// Симуляция: машина едет по полосам нашей карты и перестраивается.
//
// Геометрия — только наша: ось ленты, её ширина и число полос (route.json из
// make_route.py — та же сеть, что в тайлах). Машина — объёмные примитивы
// (fill-extrusion из GeoJSON, обновляется каждый кадр): тот же приём
// работает и в MapLibre Native на телефоне, без сторонних 3D-библиотек.
(function () {
  'use strict';

  const SPEED_KMH = 55;
  const LANE_CHANGE_SECONDS = 3.2;      // длительность перестроения
  const LANE_HOLD_SECONDS = [5, 9];     // сколько держать полосу между манёврами
  const SIGNAL_LEAD_SECONDS = 1.5;      // поворотник до начала манёвра
  const CAMERA = { zoom: 19.3, pitch: 62, behindMeters: 18 };
  const KM = 111320;

  const params = new URLSearchParams(location.search);
  // Зерно случайности: один и тот же заезд при каждом открытии (?seed=…).
  let seed = Number(params.get('seed') || 7) >>> 0;
  function random() {
    seed = (seed + 0x6D2B79F5) >>> 0;
    let t = seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  const style = params.get('style') || 'st_light_full.json';
  const map = new maplibregl.Map({ container: 'map', style: style, center: [69.2052, 41.2742],
                                   zoom: 18, pitch: 60, antialias: true });

  let route = null;          // [{x, y, s, width, lanes}] в метрах от начала
  const state = { s: 0, lane: 0, fromOffset: 0, toLane: 0, changeStart: -1, holdUntil: 0,
                  signal: 0, signalSince: 0, heading: 0, time: 0 };

  function project(lon, lat, origin) {
    const kx = KM * Math.cos(origin[1] * Math.PI / 180);
    return [(lon - origin[0]) * kx, (lat - origin[1]) * KM];
  }
  function unproject(x, y, origin) {
    const kx = KM * Math.cos(origin[1] * Math.PI / 180);
    return [origin[0] + x / kx, origin[1] + y / KM];
  }

  function prepare(points) {
    const origin = [points[0][0], points[0][1]];
    let s = 0;
    const out = [];
    points.forEach(function (p, i) {
      const xy = project(p[0], p[1], origin);
      if (i > 0) {
        const prev = out[out.length - 1];
        s += Math.hypot(xy[0] - prev.x, xy[1] - prev.y);
      }
      out.push({ x: xy[0], y: xy[1], s: s, width: p[2], lanes: Math.max(1, p[3]) });
    });
    return { origin: origin, points: out, length: s };
  }

  // Точка, касательная и параметры ленты на расстоянии s по оси.
  function sample(s) {
    const pts = route.points;
    let i = 1;
    while (i < pts.length - 1 && pts[i].s < s) { i += 1; }
    const a = pts[i - 1], b = pts[i];
    const t = Math.max(0, Math.min(1, (s - a.s) / Math.max(0.01, b.s - a.s)));
    const tx = (b.x - a.x), ty = (b.y - a.y);
    const len = Math.hypot(tx, ty) || 1;
    return { x: a.x + tx * t, y: a.y + ty * t, tx: tx / len, ty: ty / len,
             width: a.width, lanes: a.lanes };
  }

  // Смещение центра полосы от оси ленты, вправо по ходу (м).
  function laneOffset(lane, at) {
    const laneWidth = at.width / at.lanes;
    return -at.width / 2 + laneWidth * (lane + 0.5);
  }

  function smoothstep(t) { return t * t * (3 - 2 * t); }

  function step(dt) {
    state.time += dt;
    state.s += SPEED_KMH / 3.6 * dt;
    if (state.s >= route.length - 5) { state.s = 0; }
    const at = sample(state.s);
    if (state.lane >= at.lanes) { state.lane = at.lanes - 1; state.toLane = state.lane; }

    // Решение о манёвре: соседняя полоса, если она есть; сначала поворотник.
    if (state.changeStart < 0 && state.signal === 0 && state.time > state.holdUntil && at.lanes > 1) {
      const options = [];
      if (state.lane > 0) { options.push(-1); }
      if (state.lane < at.lanes - 1) { options.push(1); }
      state.signal = options[Math.floor(random() * options.length)];
      state.signalSince = state.time;
    }
    if (state.signal !== 0 && state.changeStart < 0 && state.time - state.signalSince >= SIGNAL_LEAD_SECONDS) {
      state.fromOffset = laneOffset(state.lane, at);
      state.toLane = state.lane + state.signal;
      state.changeStart = state.time;
    }
    let offset = laneOffset(state.lane, at);
    let drift = 0;
    if (state.changeStart >= 0) {
      const t = Math.min(1, (state.time - state.changeStart) / LANE_CHANGE_SECONDS);
      const target = laneOffset(state.toLane, at);
      offset = state.fromOffset + (target - state.fromOffset) * smoothstep(t);
      drift = (target - state.fromOffset) * 6 * t * (1 - t) / LANE_CHANGE_SECONDS;   // м/с вбок
      if (t >= 1) {
        state.lane = state.toLane;
        state.changeStart = -1;
        state.signal = 0;
        const hold = LANE_HOLD_SECONDS[0] + random() * (LANE_HOLD_SECONDS[1] - LANE_HOLD_SECONDS[0]);
        state.holdUntil = state.time + hold;
      }
    }
    // Правая нормаль к ходу: (ty, -tx).
    const x = at.x + at.ty * offset, y = at.y - at.tx * offset;
    // Курс машины — по оси плюс угол бокового смещения при перестроении.
    const forward = SPEED_KMH / 3.6;
    const yaw = Math.atan2(at.tx, at.ty) + Math.atan2(drift, forward);
    state.heading = yaw;
    return { x: x, y: y, yaw: yaw, lanes: at.lanes };
  }

  // Прямоугольник в системе машины (x вправо, y вперёд) → кольцо lon/lat.
  function box(car, left, right, back, front) {
    const sin = Math.sin(car.yaw), cos = Math.cos(car.yaw);
    const corners = [[left, back], [right, back], [right, front], [left, front], [left, back]];
    return corners.map(function (c) {
      const ex = car.x + c[0] * cos + c[1] * sin;
      const ny = car.y - c[0] * sin + c[1] * cos;
      return unproject(ex, ny, route.origin);
    });
  }

  function part(ring, base, height, color) {
    return { type: 'Feature', geometry: { type: 'Polygon', coordinates: [ring] },
             properties: { base: base, height: height, color: color } };
  }

  function carShape(car) {
    const blink = Math.floor(state.time * 2.5) % 2 === 0;
    const parts = [
      part(box(car, -0.92, 0.92, -2.25, 2.25), 0.28, 1.0, '#2f6fdd'),          // кузов
      part(box(car, -0.80, 0.80, -1.25, 0.85), 1.0, 1.42, '#24324a'),           // кабина (стёкла)
      part(box(car, -0.74, 0.74, -1.05, 0.65), 1.42, 1.47, '#2f6fdd'),          // крыша
      part(box(car, -0.95, -0.55, 1.6, 2.0), 0.0, 0.62, '#1c1f24'),             // колёса
      part(box(car, 0.55, 0.95, 1.6, 2.0), 0.0, 0.62, '#1c1f24'),
      part(box(car, -0.95, -0.55, -1.95, -1.55), 0.0, 0.62, '#1c1f24'),
      part(box(car, 0.55, 0.95, -1.95, -1.55), 0.0, 0.62, '#1c1f24'),
      part(box(car, -0.85, -0.45, 2.22, 2.3), 0.65, 0.85, '#fff6d6'),           // фары
      part(box(car, 0.45, 0.85, 2.22, 2.3), 0.65, 0.85, '#fff6d6'),
      part(box(car, -0.85, -0.45, -2.3, -2.22), 0.7, 0.88, '#d32f2f'),          // стопы
      part(box(car, 0.45, 0.85, -2.3, -2.22), 0.7, 0.88, '#d32f2f'),
    ];
    if (state.signal !== 0 && blink) {
      const side = state.signal > 0 ? [0.82, 0.96] : [-0.96, -0.82];
      parts.push(part(box(car, side[0], side[1], 2.0, 2.3), 0.62, 0.9, '#ffab00'));
      parts.push(part(box(car, side[0], side[1], -2.3, -2.0), 0.62, 0.9, '#ffab00'));
    }
    return { type: 'FeatureCollection', features: parts };
  }

  let last = null;
  let cameraHeading = null;
  function frame(now) {
    const dt = last === null ? 0 : Math.min(0.1, (now - last) / 1000);
    last = now;
    draw(step(dt), dt);
    requestAnimationFrame(frame);
  }

  function draw(car, dt) {
    map.getSource('car').setData(carShape(car));
    // Камера плавно поворачивает за машиной и стоит позади неё.
    const deg = car.yaw * 180 / Math.PI;
    if (cameraHeading === null) { cameraHeading = deg; }
    const diff = ((deg - cameraHeading + 540) % 360) - 180;
    cameraHeading += dt > 0 ? diff * Math.min(1, dt * 2.5) : 0;
    const back = CAMERA.behindMeters;
    const rad = cameraHeading * Math.PI / 180;
    const centre = unproject(car.x + Math.sin(rad) * back * 0.6, car.y + Math.cos(rad) * back * 0.6, route.origin);
    map.jumpTo({ center: centre, bearing: cameraHeading, pitch: CAMERA.pitch, zoom: CAMERA.zoom });
    document.getElementById('hud').textContent =
      SPEED_KMH + ' км/ч · полоса ' + (state.lane + 1) + ' из ' + car.lanes +
      (state.signal ? (state.signal > 0 ? ' · → перестроение' : ' · ← перестроение') : '');
  }

  map.on('error', function (e) {
    document.getElementById('hud').textContent = 'ошибка карты: ' + (e.error && e.error.message);
  });
  map.on('load', function () {
    fetch(params.get('route') || 'route.json').then(function (r) { return r.json(); }).then(function (data) {
      route = prepare(data.points);
      map.addSource('car', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
      map.addLayer({ id: 'sim-car', type: 'fill-extrusion', source: 'car',
                     paint: { 'fill-extrusion-color': ['get', 'color'],
                              'fill-extrusion-base': ['get', 'base'],
                              'fill-extrusion-height': ['get', 'height'],
                              'fill-extrusion-opacity': 1 } });
      // ?t=секунды — кадр для проверки: прокрутить заезд и остановиться.
      if (params.has('t')) {
        const until = Number(params.get('t'));
        let car = null;
        for (let time = 0; time < until; time += 1 / 30) { car = step(1 / 30); }
        cameraHeading = car.yaw * 180 / Math.PI;
        draw(car, 0);
        return;
      }
      requestAnimationFrame(frame);
    });
  });
})();
