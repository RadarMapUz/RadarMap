(function () {
  'use strict';
  // Каркас панели на MapLibre. Этап Э4: карта, камера, слои из MVT, стиль по
  // классам. Рисование и правка остаются в рабочей панели до этапа Э5 —
  // конструктор единственный инструмент разметки, и переносить его вместе с
  // движком значило бы менять две вещи разом.

  // Палитра — ТА ЖЕ, что на телефоне и в рабочей панели. Один язык в трёх
  // местах: модератор, поставивший объект, обязан видеть то же, что увидит
  // водитель.
  const GROUND = '#0e1013';
  const ASPHALT = { 1: '#6b6a63', 2: '#6b6a63', 3: '#5e5d58', 4: '#525252',
                    5: '#4a4a4a', 6: '#464646', 7: '#3c3c3c' };
  const LAND = { 1: '#16324a', 2: '#152a1b', 3: '#2a2723', 4: '#12151b',
                 5: '#1b1f26', 6: '#1f232c' };

  function asphalt() {
    // Цвет по классу — выражением MapLibre, а не перебором в JS: перебор
    // означал бы свой слой на каждый класс и семь проходов вместо одного.
    const stops = ['match', ['get', 'cls']];
    Object.keys(ASPHALT).forEach(function (cls) {
      stops.push(Number(cls), ASPHALT[cls]);
    });
    stops.push('#464646');
    return stops;
  }

  function landColour() {
    const stops = ['match', ['get', 'kind']];
    Object.keys(LAND).forEach(function (kind) {
      stops.push(Number(kind), LAND[kind]);
    });
    stops.push('#1a1d22');
    return stops;
  }

  // Ширина линии дороги в ПИКСЕЛЯХ от зума.
  //
  // Ширина в тайле лежит в метрах, и рисовать её метрами правильно только
  // вблизи: на обзоре улица шириной одиннадцать метров стала бы тоньше
  // волоса, и сеть исчезла бы вовсе. Поэтому у линии свой рост по зуму, а
  // настоящая ширина живёт в слое поверхности — он и включается вблизи.
  //
  // `extra` — прибавка для каймы. Прибавляется ВНУТРИ, а не снаружи: обернуть
  // готовое выражение в ['+', …, 2] нельзя — MapLibre принимает ['zoom']
  // только на верхнем уровне interpolate, и стиль падает целиком с
  // «"zoom" expression may only be used as input to a top-level "step" or
  // "interpolate" expression».
  function roadWidth(extra) {
    const add = extra || 0;
    function byClass(one, two, three, four, rest) {
      return ['match', ['get', 'cls'],
              1, one + add, 2, two + add, 3, three + add, 4, four + add,
              rest + add];
    }
    return ['interpolate', ['exponential', 1.6], ['zoom'],
            10, byClass(1.4, 1.2, 1.0, 0.8, 0.6),
            14, byClass(5, 4.5, 4, 3, 2),
            17, byClass(22, 20, 16, 12, 7)];
  }

  // Метка сборки: после публикации адрес тайла меняется, и браузер идёт за
  // новым. Без неё модератор смотрит вчерашнюю карту и не знает об этом.
  const holder = document.getElementById('map');
  const stamp = holder && holder.dataset.stamp
    ? '?v=' + holder.dataset.stamp : '';

  const style = {
    version: 8,
    // Глифы — СВОИ, три диапазона из трёхсот килобайт: латиница, латиница с
    // диакритикой (в узбекских названиях есть oʻ и gʻ) и кириллица. По
    // замеру именно они и нужны: 72 % улиц центра записаны латиницей, 28 % —
    // кириллицей, и на карте встречаются обе.
    glyphs: location.origin + '/glyphs/{fontstack}/{range}.pbf',
    sources: {
      // Спутник. Единственный чужой источник на странице, и включается он
      // руками: подложка нужна, когда обводят дом или ищут, где на самом деле
      // проходит дорога, — а не всё время.
      //
      // Esri World Imagery: правообладатель разрешил её для обводки в OSM
      // явно, и именно её показывают iD и JOSM. Спутник Яндекса здесь брать
      // нельзя — это их условия.
      sky: {
        type: 'raster',
        tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/'
                + 'World_Imagery/MapServer/tile/{z}/{y}/{x}'],
        tileSize: 256,
        maxzoom: 19,
        attribution: 'Esri World Imagery',
      },
      own: {
        type: 'vector',
        tiles: [location.origin + '/mvt/{z}/{x}/{y}.mvt' + stamp],
        minzoom: 11,
        maxzoom: 15,
      },
    },
    layers: [
      { id: 'ground', type: 'background',
        paint: { 'background-color': GROUND } },
      // Слой спутника лежит выключенным. Включённый по умолчанию, он тянул бы
      // чужие тайлы у всех и всегда — включая тех, кому он не нужен.
      { id: 'sky', type: 'raster', source: 'sky',
        layout: { visibility: 'none' },
        paint: { 'raster-opacity': 1 } },
      // Порядок слоёв тот же, что на телефоне: квартал закрывает пустоту
      // между улицами, дом ложится на него, вода и зелень поверх.
      { id: 'land', type: 'fill', source: 'own', 'source-layer': 'land',
        filter: ['==', ['geometry-type'], 'Polygon'],
        paint: { 'fill-color': landColour(), 'fill-opacity': 0.9 } },
      { id: 'land-lines', type: 'line', source: 'own', 'source-layer': 'land',
        filter: ['==', ['geometry-type'], 'LineString'],
        paint: { 'line-color': landColour(), 'line-width': 1.5 } },
      { id: 'houses', type: 'fill', source: 'own', 'source-layer': 'houses',
        minzoom: 14,
        paint: { 'fill-color': LAND[6], 'fill-outline-color': '#2b303a' } },
      // Поверхность считается в сборке (этап Э1) и заливается как есть.
      // Именно ради неё переход и имеет смысл: браузер перестал строить
      // полотно, перекрёстки и фаски на каждое движение карты.
      { id: 'surface', type: 'fill', source: 'own', 'source-layer': 'surface',
        minzoom: 14,
        filter: ['!=', ['get', 'kind'], 9],
        paint: { 'fill-color': asphalt(), 'fill-opacity': 1 } },
      // Кромка полотна — бордюр. Без неё асфальт сливается с землёй и
      // читается плоским пятном, а не поверхностью, у которой есть край.
      // Перекрёсток не обводим: контур поперёк проезжей части — это шов,
      // которого мы и избегали.
      { id: 'kerb', type: 'line', source: 'own', 'source-layer': 'surface',
        minzoom: 15, filter: ['==', ['get', 'kind'], 7],
        paint: { 'line-color': '#5c5b57', 'line-width': 1 } },
      // Разделительная и островок — ЗЕМЛЯ поверх асфальта, с бордюром.
      { id: 'median', type: 'fill', source: 'own', 'source-layer': 'surface',
        minzoom: 15, filter: ['==', ['get', 'kind'], 9],
        paint: { 'fill-color': '#12151b',
                 'fill-outline-color': '#5c5b57' } },
      // Линии сети остаются: на обзоре поверхность вырождается в нитку, и
      // рисовать её там нечем.
      { id: 'roads-case', type: 'line', source: 'own', 'source-layer': 'roads',
        maxzoom: 14,
        layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': '#04060a',
                 'line-width': roadWidth(2) } },
      { id: 'roads', type: 'line', source: 'own', 'source-layer': 'roads',
        layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': asphalt(), 'line-width': roadWidth(),
                 // Вблизи линию гасим: там уже нарисована настоящая
                 // поверхность, и линия поверх неё дала бы вторую дорогу.
                 'line-opacity': ['interpolate', ['linear'], ['zoom'],
                                  13.5, 1, 14.5, 0] } },
      // Подпись идёт ВДОЛЬ улицы и никогда вверх ногами — то же правило, что
      // на телефоне. Бюджет на кадр держит сам движок: он расставляет то, что
      // помещается без наложений, и молча отбрасывает остальное.
      { id: 'street-labels', type: 'symbol', source: 'own',
        'source-layer': 'roads', minzoom: 14,
        filter: ['all', ['has', 'name'], ['<=', ['get', 'cls'], 6]],
        layout: { 'symbol-placement': 'line',
                  'text-field': ['get', 'name'],
                  'text-font': ['Noto Sans Regular'],
                  'text-size': ['interpolate', ['linear'], ['zoom'],
                                14, 10, 17, 13],
                  'text-max-angle': 35,
                  'text-padding': 4,
                  'symbol-spacing': 260 },
        // Приглушённо и с тёмной обводкой: ночью подпись не должна светить, а
        // на сером асфальте белый текст без обводки не читается вовсе.
        paint: { 'text-color': '#cfd3d8', 'text-halo-color': '#0e1013',
                 'text-halo-width': 1.4, 'text-opacity': 0.9 } },
      { id: 'points', type: 'circle', source: 'own', 'source-layer': 'points',
        minzoom: 15,
        paint: { 'circle-radius': 3, 'circle-color': '#e0d9b8',
                 'circle-stroke-width': 1, 'circle-stroke-color': '#04060a' } },
    ],
  };

  function placeFromHash() {
    const parts = (location.hash || '').replace('#', '').split(',');
    const lat = parseFloat(parts[0]);
    const lon = parseFloat(parts[1]);
    const zoom = parseFloat(parts[2]);
    if (!isFinite(lat) || !isFinite(lon)) { return null; }
    return { center: [lon, lat], zoom: isFinite(zoom) ? zoom : 16 };
  }

  const count = document.getElementById('count');

  // Сказанное держится, а не смывается счётчиком.
  //
  // Фоновая цифра «в кадре: 815» появляется на каждом успокоении карты и
  // затирала единственное место, где написано, что произошло, — включая
  // «сохранено» и «конец примкнул к…». Сообщение, которого не успели
  // прочитать, равно отсутствию сообщения.
  const HOLD_MS = 4000;
  let saidAt = 0;

  function say(text) {
    saidAt = Date.now();
    if (count) { count.textContent = text; }
  }

  function murmur(text) {
    if (Date.now() - saidAt < HOLD_MS) { return; }
    if (count) { count.textContent = text; }
  }

  const start = placeFromHash() || { center: [69.280, 41.311], zoom: 16 };
  const map = new maplibregl.Map({
    container: 'map',
    // Стиль ставится ПОСЛЕ подписки на ошибки, а не в конструкторе.
    //
    // Проверка стиля идёт внутри конструктора, синхронно: неверный стиль
    // роняет карту раньше, чем к ней можно подписаться, и на экране остаётся
    // чёрное поле без единого слова. Это стоило часа поисков вслепую.
    // Пустой стиль поднимается всегда, а настоящий приходит следом — и любая
    // его беда попадает в строку состояния.
    style: { version: 8, sources: {}, layers: [] },
    center: start.center,
    zoom: start.zoom,
    hash: false,
    attributionControl: false,
  });
  // Подписка на ошибки — ПЕРВЫМ делом после создания карты.
  //
  // Раньше она стояла в конце файла, и это стоило получаса: неверный стиль
  // роняет карту ещё до того, как очередь дойдёт до подписки, и на экране
  // остаётся чёрное поле без единого слова. Молчащая ошибка хуже громкой.
  map.on('error', function (e) {
    const message = (e && e.error && e.error.message) || 'ошибка карты';
    say(message);
  });

  map.setStyle(style);

  map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }),
                 'bottom-right');
  map.addControl(new maplibregl.AttributionControl({
    customAttribution: 'OpenStreetMap · своя схема',
  }), 'bottom-left');

  // Адрес несёт место — тот же формат, что у рабочей панели, чтобы ссылка
  // открывалась в обеих.
  map.on('moveend', function () {
    const c = map.getCenter();
    location.replace('#' + c.lat.toFixed(5) + ',' + c.lng.toFixed(5)
                     + ',' + map.getZoom().toFixed(1));
  });

  // Карта следит за размером СВОЕГО контейнера, а не только за окном.
  //
  // Замечено на себе: после смены размера окна карта оставалась пустой —
  // холст сохранял прежние размеры, а перерисовки не происходило. Панель
  // открывают и в половину экрана, и рядом с рабочей для сверки, и в этот
  // момент она обязана остаться картой, а не чёрным полем.
  if (window.ResizeObserver && holder) {
    new ResizeObserver(function () { map.resize(); }).observe(holder);
  }

  // --- Этап Э5: конструктор ------------------------------------------------
  //
  // Половина работы уже наша и переносится как есть: магнит считает СЕРВЕР
  // (/api/snap), правка сохраняется тем же /api/edit, и класс, причина и
  // полосы имеют ответ до вопроса. Меняется ровно одно — попадание по дороге.
  //
  // В холсте его приходилось считать самим: координата → ближайшая улица в
  // загруженном списке. Здесь это даёт движок (queryRenderedFeatures), и он
  // отвечает по НАРИСОВАННОМУ, а не по нашему представлению о нарисованном.
  // Это единственное место, где переход упрощает код, а не переносит его.

  const CLASSES = { 3: 'проспект', 4: 'улица', 6: 'жилая', 7: 'проезд' };
  // Ближе этого конец линии примыкает к существующей дороге. Тот же порог,
  // что в рабочей панели: дорога, нарисованная РЯДОМ с существующей, а не в
  // неё, — не дорога, а вторая линия поверх первой.
  const ATTACH_METERS = 12;

  let drawing = null;      // {cls, points: [[lon,lat], …]}
  let mine = [];           // свои правки в кадре
  let held = null;         // вершина под пальцем: {edit, at}
  let pointCode = 0;       // ждём щелчка, чтобы поставить обстановку
  let lanesAt = null;      // дорога выбрана, ждём число полос
  let choosing = null;     // магнит не выбрал: {list, then}
  const POINTS = { 1: 'светофор', 2: 'лежачий полицейский', 3: 'стоп-линия',
                   4: 'разворот', 5: 'пешеходный переход' };
  const HOUSE_AREA = 6;
  // Ближе этого две вершины считаются ОДНИМ узлом. Два метра — не догадка:
  // координата в тайле лежит с шагом 1,1 м, и всё, что ближе, неразличимо в
  // самих данных.
  const WELD_METERS = 2;

  function post(path, body) {
    return fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      credentials: 'same-origin',
    }).then(function (r) {
      // Ответ читаем ЧЕСТНО: r.json().catch(() => ({})) превращает пятисотку
      // в «сохранено», и панель врёт о результате. Это уже было.
      if (!r.ok) { return r.text().then(function (t) {
        return { error: 'сервер ответил ' + r.status + ': ' + t.slice(0, 120) };
      }); }
      return r.json();
    }, function () { return { error: 'сервер не ответил' }; });
  }

  function line(points) {
    return { type: 'Feature', properties: {},
             geometry: { type: 'LineString', coordinates: points } };
  }

  function dots(points) {
    return points.map(function (p, i) {
      return { type: 'Feature', properties: { last: i === points.length - 1 },
               geometry: { type: 'Point', coordinates: p } };
    });
  }

  function drawnFeatures() {
    const out = [];
    if (drawing && drawing.points.length > 1) {
      // Контур дома замыкается уже при рисовании: незамкнутая ломаная
      // выглядит недорисованной дорогой, а не обводкой.
      out.push(line(drawing.area && drawing.points.length > 2
        ? drawing.points.concat([drawing.points[0]])
        : drawing.points));
    }
    if (drawing) { out.push.apply(out, dots(drawing.points)); }
    mine.forEach(function (edit) {
      if (edit.points && edit.points.length > 1) { out.push(line(edit.points)); }
    });
    return { type: 'FeatureCollection', features: out };
  }

  function repaintDraft() {
    const source = map.getSource('draft');
    if (source) { source.setData(drawnFeatures()); }
  }

  function addDraftLayers() {
    map.addSource('draft', { type: 'geojson', data: drawnFeatures() });
    map.addLayer({ id: 'draft-line', type: 'line', source: 'draft',
      filter: ['==', ['geometry-type'], 'LineString'],
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': '#ffb020', 'line-width': 4 } });
    map.addLayer({ id: 'draft-dots', type: 'circle', source: 'draft',
      filter: ['==', ['geometry-type'], 'Point'],
      paint: { 'circle-radius': ['case', ['get', 'last'], 6, 4],
               'circle-color': '#ffb020',
               'circle-stroke-width': 2, 'circle-stroke-color': '#0e1013' } });
  }

  function startDrawing(cls) {
    drawing = { cls: cls, points: [], area: false };
    pointCode = 0;
    lanesAt = null;
    map.getCanvas().style.cursor = 'crosshair';
    say('рисуем: ' + CLASSES[cls] + ' · Enter — закончить, Esc — отменить');
    repaintDraft();
  }

  function startArea() {
    drawing = { cls: 0, points: [], area: true };
    pointCode = 0;
    lanesAt = null;
    map.getCanvas().style.cursor = 'crosshair';
    say('обводим дом · Enter — замкнуть, Esc — отменить');
    repaintDraft();
  }

  function cancelDrawing(quiet) {
    drawing = null;
    map.getCanvas().style.cursor = '';
    repaintDraft();
    if (!quiet) { say('отменено'); }
  }

  function attachEnd(lngLat) {
    // Магнит считает СЕРВЕР — тот же, что у рабочей панели. Не ради мощности:
    // прилипать надо к той геометрии, которая поедет на телефон, вместе со
    // всей генерализацией, а в браузере её нет.
    return post('/api/snap', { lat: lngLat.lat, lon: lngLat.lng })
      .then(function (snap) {
        const near = (snap.candidates || [])[0];
        if (near && !snap.ambiguous && near.meters <= ATTACH_METERS) {
          // Прилипание НАЗЫВАЕТСЯ вслух: невидимое читается как «панель
          // поставила точку сама, а я исправляй».
          say('конец примкнул к «' + (near.name || 'дороге класса ' + near.cls)
              + '», ' + near.meters + ' м');
          return near.point;
        }
        return [lngLat.lng, lngLat.lat];
      });
  }

  function finishDrawing() {
    if (!drawing || drawing.points.length < 2) {
      say('нужно хотя бы две вершины');
      return;
    }
    const cls = drawing.cls;
    const points = drawing.points.slice();
    const last = points[points.length - 1];
    // Последнюю вершину притягиваем НА ВЫХОДЕ: пока рисуешь, неизвестно,
    // какая из них последняя.
    attachEnd({ lng: last[0], lat: last[1] }).then(function (point) {
      const ready = points.slice(0, -1).concat([point]);
      cancelDrawing(true);
      post('/api/edit', {
        kind: 'geometry', geom: ready, raw: ready[0],
        props: { cls: cls, oneway: false, bridge: false, why: 'нет в OSM' },
        status: 1,
      }).then(function (result) {
        if (result.error) { say(result.error); return; }
        say(CLASSES[cls] + ' сохранена. Публикует владелец со своей машины.');
        loadMine();
      });
    });
  }

  // Свои правки грузятся С ЗАПАСОМ и не перезапрашиваются, пока рамка из него
  // не вышла: движение туда-сюда не должно стоить ни одного запроса. Тайлы
  // движок кэширует сам, а вот правки — наша забота.
  const MARGIN = 0.6;
  const SETTLE_MS = 180;
  let loadedBox = null;
  let mineGeneration = 0;
  let settleTimer = null;

  function insideLoaded() {
    if (!loadedBox) { return false; }
    const b = map.getBounds();
    return b.getSouth() >= loadedBox[0] && b.getWest() >= loadedBox[1]
        && b.getNorth() <= loadedBox[2] && b.getEast() <= loadedBox[3];
  }

  function onMoved() {
    keepPlace();
    if (settleTimer) { clearTimeout(settleTimer); }
    settleTimer = setTimeout(function () {
      settleTimer = null;
      if (insideLoaded()) { return; }
      loadMine();
    }, SETTLE_MS);
  }

  function loadMine() {
    const b = map.getBounds();
    const dy = (b.getNorth() - b.getSouth()) * MARGIN;
    const dx = (b.getEast() - b.getWest()) * MARGIN;
    loadedBox = [b.getSouth() - dy, b.getWest() - dx,
                 b.getNorth() + dy, b.getEast() + dx];
    // Поколение: поздний ответ на старую рамку не имеет права затирать свежий
    // кадр. Молча затёртый кадр читается как «не загрузилось».
    const mine_ = ++mineGeneration;
    const query = '?south=' + loadedBox[0].toFixed(5)
                + '&west=' + loadedBox[1].toFixed(5)
                + '&north=' + loadedBox[2].toFixed(5)
                + '&east=' + loadedBox[3].toFixed(5);
    fetch('/api/edits' + query, { credentials: 'same-origin' })
      .then(function (r) { return r.ok ? r.json() : { edits: [] }; })
      .then(function (data) {
        if (mine_ !== mineGeneration) { return; }
        // Чем правка рисуется, решает СЕРВЕР (draw.shape) — по той же
        // причине, что ширину дороги: вторая реализация в JavaScript
        // разошлась бы с первой молча. Именно на этом однажды и попались:
        // линии рисовались точками по geom[1], и метки летели по всей карте.
        mine = (data.edits || []).filter(function (edit) {
          return edit.draw && edit.draw.shape === 'line'
                 && edit.geom && edit.geom.length > 1;
        }).map(function (edit) {
          // Свойства несём с собой. Сохранить геометрию с пустыми props
          // значит стереть класс дороги, причину правки и односторонность —
          // молча, потому что запись пройдёт успешно.
          return { id: edit.id, points: edit.geom, kind: edit.kind,
                   props: edit.props || {}, version: edit.version };
        });
        repaintDraft();
      }, function () { /* сеть молчит — рисуем что есть */ });
  }

  function metersBetween(a, b) {
    const lat = (a[1] + b[1]) / 2 * Math.PI / 180;
    const dx = (a[0] - b[0]) * Math.cos(lat) * 111320;
    const dy = (a[1] - b[1]) * 111320;
    return Math.hypot(dx, dy);
  }

  function vertexUnder(point) {
    // Ищем по ЭКРАНУ, а не по метрам: палец мажет одинаково на любом зуме, а
    // порог в метрах на дальнем плане накрыл бы полквартала.
    for (let i = 0; i < mine.length; i++) {
      const edit = mine[i];
      for (let v = 0; v < edit.points.length; v++) {
        const at = map.project(edit.points[v]);
        if (Math.hypot(at.x - point.x, at.y - point.y) <= 9) {
          return { edit: edit, at: v };
        }
      }
    }
    return null;
  }

  function weldPartners(edit, at) {
    // Кто ещё держится за эту точку. Перекрёсток у нас — совпадение
    // координат, а не объект, поэтому «кто держится» приходится спрашивать
    // геометрией.
    const spot = edit.points[at];
    const out = [];
    mine.forEach(function (other) {
      other.points.forEach(function (point, index) {
        if (other === edit && index === at) { return; }
        if (metersBetween(spot, point) <= WELD_METERS) {
          out.push({ edit: other, at: index });
        }
      });
    });
    return out;
  }

  function moveVertex(target, lngLat) {
    // Узел двигается ЦЕЛИКОМ, со всеми улицами, которые за него держатся.
    //
    // Перекрёсток у нас существует только как совпадение координат: улицы —
    // независимые ломаные, и общей вершины-объекта у них нет. Подвинуть одну
    // и оставить остальные значит разорвать перекрёсток молча — на схеме
    // останется дырка, а в данных два конца в паре метров друг от друга.
    const also = weldPartners(target.edit, target.at);
    const point = [lngLat.lng, lngLat.lat];
    target.edit.points[target.at] = point;
    also.forEach(function (mate) { mate.edit.points[mate.at] = point.slice(); });
    repaintDraft();
    return [target].concat(also);
  }

  function saveMoved(touched) {
    // Каждая улица сохраняется СВОЕЙ правкой: у них разные версии и разные
    // авторы, и слить их в одну запись значило бы потерять, кто что менял.
    const seen = [];
    touched.forEach(function (one) {
      if (seen.indexOf(one.edit) < 0) { seen.push(one.edit); }
    });
    const jobs = seen.map(function (edit) {
      return post('/api/edit', {
        id: edit.id, version: edit.version,
        kind: edit.kind || 'geometry', geom: edit.points,
        raw: edit.points[0], props: edit.props, status: 1,
      });
    });
    Promise.all(jobs).then(function (results) {
      const lost = results.filter(function (r) { return !r || r.error; });
      if (lost.length) {
        say('не сохранилось: ' + (lost[0].error || 'сервер молчит')
            + ' · обновите страницу, чтобы увидеть, что на сервере');
        return;
      }
      say(seen.length > 1
          ? 'узел подвинут вместе с ' + seen.length + ' улицами'
          : 'вершина подвинута');
      loadMine();
    });
  }

  function offerChoice(snap, then) {
    // Магнит не выбрал между дорогами — значит выбирает человек.
    //
    // Это не редкость и не сбой: на перекрёстке в радиусе захвата всегда
    // несколько улиц, и «onRoad: false» там означает «их три», а не «мимо».
    // Молча отказываться значило бы запретить ставить обстановку ровно там,
    // где она и стоит.
    choosing = { list: (snap.candidates || []).slice(0, 3), then: then };
    const names = choosing.list.map(function (c, i) {
      return (i + 1) + ') ' + (c.name || 'класс ' + c.cls) + ' ' + c.meters + ' м';
    });
    say('на какой дороге? ' + names.join(' · '));
  }

  function placePoint(lngLat, code) {
    // Обстановка садится НА ПРОЕЗЖУЮ ЧАСТЬ, и сажает её сервер: у него та же
    // геометрия, что поедет на телефон, и он же считает азимут и ширину, без
    // которых зебра ляжет чертой в ноль метров.
    post('/api/snap', { lat: lngLat.lat, lon: lngLat.lng,
                        preferNode: code === 1 || code === 3 })
      .then(function (snap) {
        if (!snap.point) {
          say('вне дороги — обстановка ставится на проезжей части');
          return;
        }
        if (!snap.onRoad && snap.ambiguous) {
          offerChoice(snap, function (chosen) {
            savePoint(lngLat, code, snap, chosen.point);
          });
          return;
        }
        savePoint(lngLat, code, snap, snap.point);
      });
  }

  function savePoint(lngLat, code, snap, point) {
    post('/api/edit', {
      kind: 'point', geom: point, raw: [lngLat.lng, lngLat.lat],
      anchor: snap.anchor, fingerprint: snap.fingerprint,
      props: { point: code }, status: 1,
    }).then(function (result) {
      if (result.error) { say(result.error); return; }
      say(POINTS[code] + ' поставлен. Публикует владелец со своей машины.');
      loadMine();
    });
  }

  function askLanes(lngLat) {
    post('/api/snap', { lat: lngLat.lat, lon: lngLat.lng })
      .then(function (snap) {
        const near = (snap.candidates || [])[0];
        if (!near) { say('вне дороги'); return; }
        lanesAt = { geom: snap.point, raw: [lngLat.lng, lngLat.lat],
                    anchor: snap.anchor, fingerprint: snap.fingerprint,
                    name: near.name, cls: near.cls };
        say('«' + (near.name || 'дорога класса ' + near.cls)
            + '» · сколько полос? 1–8');
      });
  }

  function saveLanes(count) {
    const at = lanesAt;
    lanesAt = null;
    post('/api/edit', {
      kind: 'lanes', geom: at.geom, raw: at.raw, anchor: at.anchor,
      fingerprint: at.fingerprint, props: { lanes: count }, status: 1,
    }).then(function (result) {
      if (result.error) { say(result.error); return; }
      // Полосы — единственное, что поднимает покрытие разметки. По стране их
      // знают у 1,4 % дорог, и каждая размеченная руками — это плюс к тому,
      // что водитель увидит за рулём.
      say(count + ' полос(ы) записано. Публикует владелец со своей машины.');
      loadMine();
    });
  }

  function finishArea() {
    if (!drawing || drawing.points.length < 3) {
      say('для контура нужно хотя бы три вершины');
      return;
    }
    const ring = drawing.points.slice();
    cancelDrawing(true);
    post('/api/edit', {
      kind: 'area', geom: ring, raw: ring[0],
      props: { area: HOUSE_AREA }, status: 1,
    }).then(function (result) {
      if (result.error) { say(result.error); return; }
      say('дом обведён. Публикует владелец со своей машины.');
      loadMine();
    });
  }

  function tell(feature) {
    const p = feature.properties || {};
    const bits = [];
    if (p.name) { bits.push('«' + p.name + '»'); }
    bits.push(CLASSES[p.cls] || 'класс ' + p.cls);
    if (p.width) { bits.push(p.width + ' м'); }
    if (p.measured) { bits.push('полосы измерены: ' + p.lanes); }
    else { bits.push('полосы по классу'); }
    if (p.oneway) { bits.push('односторонняя'); }
    say(bits.join(' · '));
  }

  map.on('load', function () {
    addDraftLayers();
    loadMine();
  });

  map.on('moveend', onMoved);

  // Перетаскивание вершины. Не через маркеры-объекты: их пришлось бы держать
  // по одному на вершину, а это ровно та беда, от которой уходили в холсте —
  // тысячи объектов на кадр.
  map.on('mousedown', function (e) {
    if (drawing) { return; }
    const found = vertexUnder(e.point);
    if (!found) { return; }
    e.preventDefault();
    held = found;
    map.dragPan.disable();
    const mates = weldPartners(found.edit, found.at);
    map.getCanvas().style.cursor = 'grabbing';
    say(mates.length
        ? 'узел: за него держатся ещё ' + mates.length + ' — поедут вместе'
        : 'вершина');
  });

  map.on('mousemove', function (e) {
    if (held) { moveVertex(held, e.lngLat); return; }
    if (drawing) { return; }
    map.getCanvas().style.cursor = vertexUnder(e.point) ? 'grab' : '';
  });

  map.on('mouseup', function () {
    if (!held) { return; }
    // Двигать здесь НЕЧЕГО: вершина уже стоит там, куда её вели мышью.
    // Первая версия звала moveVertex(held, map.getCenter()) — и утаскивала
    // вершину в центр экрана на каждом отпускании.
    const target = held;
    held = null;
    map.dragPan.enable();
    map.getCanvas().style.cursor = '';
    saveMoved([target].concat(weldPartners(target.edit, target.at)));
  });

  map.on('click', function (e) {
    if (held) { return; }
    if (pointCode) {
      const code = pointCode;
      pointCode = 0;
      placePoint(e.lngLat, code);
      return;
    }
    if (lanesAt === 0) { askLanes(e.lngLat); return; }
    if (drawing) {
      const first = drawing.points.length === 0;
      if (!first) {
        drawing.points.push([e.lngLat.lng, e.lngLat.lat]);
        repaintDraft();
        return;
      }
      // Первую вершину притягиваем СРАЗУ: с неё начинается связь с сетью, и
      // узел на стыке появляется только по общей вершине.
      attachEnd(e.lngLat).then(function (point) {
        drawing.points.push(point);
        repaintDraft();
      });
      return;
    }
    // Попадание по дороге даёт движок — по НАРИСОВАННОМУ, а не по нашему
    // представлению о нарисованном.
    const hit = map.queryRenderedFeatures(e.point, {
      layers: ['roads', 'surface'].filter(function (id) {
        return map.getLayer(id);
      }),
    });
    if (hit.length) { tell(hit[0]); }
  });

  map.on('dblclick', function (e) {
    if (drawing) { e.preventDefault(); finishDrawing(); }
  });

  document.addEventListener('keydown', function (e) {
    if (e.target && e.target.tagName === 'INPUT') { return; }
    if (e.key === '\\' || e.key === 'ё') { toggleSky(); return; }
    if (e.key === 'Escape') {
      choosing = null;
      lanesAt = null;
      pointCode = 0;
      cancelDrawing();
      return;
    }
    if (drawing && e.key === 'Enter') {
      e.preventDefault();
      if (drawing.area) { finishArea(); } else { finishDrawing(); }
      return;
    }
    if (drawing && e.key === 'Backspace') {
      e.preventDefault();
      drawing.points.pop();
      repaintDraft();
      return;
    }
    // Классы — на тех же буквах, что в рабочей панели. Разные раскладки под
    // одну руку — это не мелочь: модератор работает вслепую, глядя на карту.
    const letters = { q: 3, й: 3, w: 4, ц: 4, e: 6, у: 6, r: 7, к: 7 };
    const cls = letters[e.key.toLowerCase()];
    if (cls) { startDrawing(cls); return; }

    // Цифры при открытом выборе дороги — это ВЫБОР, а не смена инструмента.
    if (choosing && /^[1-3]$/.test(e.key)) {
      const pick = choosing.list[Number(e.key) - 1];
      const then = choosing.then;
      choosing = null;
      if (pick) { then(pick); }
      return;
    }
    // Число после выбранной дороги — это полосы, а не смена инструмента.
    if (lanesAt && /^[1-8]$/.test(e.key)) {
      saveLanes(Number(e.key));
      return;
    }
    if (e.key === '1') {
      lanesAt = 0;
      drawing = null;
      pointCode = 0;
      say('полосы: щёлкните по дороге');
      return;
    }
    if (e.key.toLowerCase() === 'h' || e.key.toLowerCase() === 'р') {
      startArea();
      return;
    }
    // Обстановка — на соседнем ряду букв: рука не путает ряды так, как
    // путает соседние клавиши в одном. Те же буквы, что в рабочей панели.
    const marks = { a: 1, ф: 1, s: 5, ы: 5, d: 3, в: 3, f: 4, а: 4, g: 2, п: 2 };
    const code = marks[e.key.toLowerCase()];
    if (code) {
      pointCode = code;
      drawing = null;
      lanesAt = null;
      say(POINTS[code] + ': щёлкните по проезжей части');
    }
  });

  // --- Спутник -------------------------------------------------------------

  let sky = false;
  // Что гасится над снимком. Полотно поверх спутника закрывает ровно то, ради
  // чего его включили; на снимке нужны тонкие оси — к чему прилипнет магнит.
  const OVER_SKY = { surface: 0.35, land: 0, houses: 0.25 };

  function toggleSky() {
    sky = !sky;
    map.setLayoutProperty('sky', 'visibility', sky ? 'visible' : 'none');
    Object.keys(OVER_SKY).forEach(function (id) {
      if (!map.getLayer(id)) { return; }
      map.setPaintProperty(id, 'fill-opacity', sky ? OVER_SKY[id] : 1);
    });
    if (map.getLayer('roads')) {
      // Над снимком линии сети видны всегда, а не гаснут на ближнем плане:
      // поверхность там приглушена, и без них не видно, где дорога.
      map.setPaintProperty('roads', 'line-opacity', sky ? 0.9
        : ['interpolate', ['linear'], ['zoom'], 13.5, 1, 14.5, 0]);
    }
    say(sky ? 'спутник Esri включён · \\ — обратно на схему'
            : 'схема');
  }

  // --- Поиск по своему индексу и переход между панелями --------------------

  const finder = document.getElementById('find');
  const foundBox = document.getElementById('found');
  const same = document.getElementById('same');

  function showFound(places) {
    if (!foundBox) { return; }
    foundBox.innerHTML = '';
    if (!places.length) {
      foundBox.hidden = true;
      say('ничего не нашлось');
      return;
    }
    places.forEach(function (place) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = place.title;
      button.addEventListener('click', function () {
        map.easeTo({ center: [place.lon, place.lat], zoom: 18 });
        foundBox.hidden = true;
        if (finder) { finder.value = ''; }
      });
      foundBox.appendChild(button);
    });
    foundBox.hidden = false;
  }

  if (finder) {
    finder.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter') { return; }
      e.preventDefault();
      const text = finder.value.trim();
      if (!text) { foundBox.hidden = true; return; }
      const c = map.getCenter();
      // Рамка идёт с запросом: «Навои» есть не в одном городе, а модератор
      // ищет ту улицу, над которой сейчас сидит.
      fetch('/api/address?q=' + encodeURIComponent(text)
            + '&lat=' + c.lat.toFixed(5) + '&lon=' + c.lng.toFixed(5),
            { credentials: 'same-origin' })
        .then(function (r) { return r.ok ? r.json() : { places: [] }; })
        .then(function (data) { showFound(data.places || []); },
              function () { say('поиск недоступен'); });
    });
  }

  // Переход в рабочую панель НА ТО ЖЕ МЕСТО.
  //
  // Э7 требует сверять картинки на одних и тех же точках, а не «примерно
  // там»: две карты, стоящие в разных местах, сравнить нельзя, и человек
  // будет искать одну и ту же улицу руками в каждой.
  function keepPlace() {
    if (!same) { return; }
    const c = map.getCenter();
    same.href = same.href.split('#')[0] + '#' + c.lat.toFixed(5) + ','
              + c.lng.toFixed(5) + ',' + Math.round(map.getZoom());
  }
  keepPlace();

  map.on('idle', function () {
    // Счётчик молчит, пока рисуют. Иначе он затирает единственное место, где
    // написано, что происходит: подсказку режима и слово о прилипании. Это
    // ровно тот случай, когда фоновая цифра важнее не бывает.
    if (drawing) { return; }
    if (!map.getLayer('roads')) { return; }
    const shown = map.queryRenderedFeatures({
      layers: ['roads', 'surface', 'land', 'houses'].filter(function (id) {
        return map.getLayer(id);
      }),
    });
    murmur('в кадре: ' + shown.length);
  });
})();
