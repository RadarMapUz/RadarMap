// Конструктор карты: ставим объекты, магнит сажает их на ось дороги.
//
// Тот же стек, что у moderate.js: обычный скрипт файлом, без сборки и
// фреймворков. Панель открывают с телефона между делом, и страница, которая
// грузится за двести миллисекунд, здесь единственно верный выбор.
//
// МАГНИТ СЧИТАЕТ СЕРВЕР. Это не про мощность браузера: пороги посадки — часть
// контракта с запеканием, тайлы собирает build_roads.py теми же числами.
// Вторая реализация здесь разошлась бы с первой молча и разошлась бы именно
// там, где дорого, — на неоднозначных местах.
//
// ПАНЕЛЬ НИЧЕГО НЕ ПУБЛИКУЕТ. Правки копятся в таблице; подписывает и
// выкладывает владелец со своей машины. Взломанный сервер не должен уметь
// дорисовать дорогу телефонам.
(function () {
  const tools = document.querySelector('.tools');
  if (!tools || typeof ymaps === 'undefined') { return; }
  const base = tools.getAttribute('data-base') || '';

  // Названия видов. Код правки — контракт с сервером, а на карточке водителю
  // панели нужно слово: «lanes» в заголовке читается как недоделка.
  const NAMES = { lanes: 'Полосы', turn_lanes: 'Направления полос',
                  u_turn: 'Разворот', geometry: 'Своя геометрия' };

  let kind = 'lanes';
  let map = null;
  let objects = null;
  let ghost = null;
  let highlight = [];
  let current = null;

  function post(url, body) {
    return fetch(base + url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify(body),
    }).then(function (r) { return r.json(); });
  }

  function get(url) {
    return fetch(base + url, { credentials: 'same-origin' })
      .then(function (r) { return r.json(); });
  }

  function bboxQuery() {
    const b = map.getBounds();
    return '?south=' + b[0][0] + '&west=' + b[0][1] +
           '&north=' + b[1][0] + '&east=' + b[1][1];
  }

  // Наш собственный рендер сети поверх спутника.
  //
  // Без него правишь вслепую: объект, идеально поставленный по снимку, на
  // схеме может оказаться под кромкой или за краем охвата. Здесь видно ровно
  // ту геометрию, которая поедет на телефон, — уже разрезанную, склеенную и
  // упрощённую.
  function drawRoads() {
    get('/api/roads' + bboxQuery()).then(function (data) {
      highlight.forEach(function (line) { map.geoObjects.remove(line); });
      highlight = (data.roads || []).map(function (road) {
        const line = new ymaps.Polyline(
          road.points.map(function (p) { return [p[1], p[0]]; }), {},
          { strokeColor: '#38bdf8', strokeWidth: 2, strokeOpacity: 0.45 });
        map.geoObjects.add(line);
        return line;
      });
    });
  }

  function drawEdits() {
    get('/api/edits' + bboxQuery()).then(function (data) {
      objects.removeAll();
      objects.add({
        type: 'FeatureCollection',
        features: (data.edits || []).map(function (edit) {
          return {
            type: 'Feature',
            id: edit.id,
            geometry: { type: 'Point', coordinates: [edit.geom[1], edit.geom[0]] },
            properties: { hintContent: edit.kind + ' · ' + (edit.props.lanes || '') },
            options: { preset: edit.status === 0
                       ? 'islands#grayCircleDotIcon' : 'islands#blueCircleDotIcon' },
          };
        }),
      });
    });
  }

  function hint(text) { document.getElementById('hint').textContent = text; }

  // Клик ставит объект НЕ туда, куда ткнули, а туда, куда посадил магнит.
  // Поставленный на глаз объект промахивается на десяток метров, и на схеме
  // он окажется в поле.
  function place(coords) {
    post('/api/snap', {
      lat: coords[0], lon: coords[1],
      preferNode: kind === 'u_turn' ? false : false,
    }).then(function (snap) {
      if (snap.ambiguous && snap.ambiguous.length) {
        // Магнит не решает за человека: проспект с дублёром выглядит именно
        // так, и угадывание там даёт разворот не с той проезжей части.
        hint('Две дороги рядом — приблизьте карту и укажите точнее.');
        return;
      }
      if (!snap.onRoad) {
        hint('Вне дороги. Ворота публикации об этом спросят.');
        return;
      }
      current = {
        kind: kind,
        raw: [coords[1], coords[0]],
        geom: snap.point,
        anchor: snap.anchor,
        fingerprint: snap.fingerprint,
        props: {},
        note: '',
      };
      showCard(snap);
    });
  }

  function showCard(snap) {
    const card = document.getElementById('card');
    card.hidden = false;
    const lanes = (current.props && current.props.lanes) || '';
    card.innerHTML =
      '<h3>' + (NAMES[current.kind] || current.kind) + '</h3>' +
      '<p class="hint">Класс ' + (snap.anchor ? snap.anchor.cls : '—') +
      ', азимут ' + (snap.anchor ? snap.anchor.bearing : '—') + '°</p>' +
      '<label>Полос всего<input id="lanes" type="number" min="1" max="15" value="' +
      lanes + '"></label>' +
      '<label>Почему<input id="note" value=""></label>' +
      '<button id="save">Принять</button>' +
      '<button id="cancel" class="ghost">Отмена</button>';
    document.getElementById('cancel').onclick = function () {
      card.hidden = true; current = null;
    };
    document.getElementById('save').onclick = function () {
      const value = parseInt(document.getElementById('lanes').value, 10);
      if (!(value >= 1 && value <= 15)) { hint('Полос от 1 до 15.'); return; }
      current.props = { lanes: value };
      current.note = document.getElementById('note').value;
      current.status = 1;
      post('/api/edit', current).then(function (result) {
        if (result.error) { hint(result.error); return; }
        card.hidden = true;
        current = null;
        hint('Принято. Публикует владелец со своей машины.');
        drawEdits();
      });
    };
  }

  // Место в адресе: #широта,долгота,зум.
  //
  // Тот же приём, что у карты камер с её /map#id, и та же причина: очередь
  // изменений будет ссылаться на конкретный перекрёсток, а ссылка, которая
  // открывает карту «где-то в Ташкенте», заставляет искать место руками.
  function placeFromHash() {
    const parts = (location.hash || '').replace('#', '').split(',');
    const lat = parseFloat(parts[0]);
    const lon = parseFloat(parts[1]);
    const zoom = parseInt(parts[2], 10);
    if (!isFinite(lat) || !isFinite(lon)) { return null; }
    return { center: [lat, lon], zoom: isFinite(zoom) ? zoom : 18 };
  }

  ymaps.ready(function () {
    const start = placeFromHash() || { center: [41.311, 69.280], zoom: 17 };
    map = new ymaps.Map('map', {
      center: start.center, zoom: start.zoom,
      controls: ['zoomControl', 'typeSelector'],
    }, { suppressMapOpenBlock: true });
    map.setType('yandex#hybrid');
    objects = new ymaps.ObjectManager({ clusterize: false });
    map.geoObjects.add(objects);

    map.events.add('click', function (e) { place(e.get('coords')); });
    map.events.add('boundschange', function () { drawRoads(); drawEdits(); });
    drawRoads();
    drawEdits();

    document.querySelectorAll('.tool').forEach(function (button) {
      button.addEventListener('click', function () {
        document.querySelectorAll('.tool').forEach(function (b) {
          b.classList.remove('on');
        });
        button.classList.add('on');
        kind = button.getAttribute('data-kind');
      });
    });
    window.addEventListener('hashchange', function () {
      const target = placeFromHash();
      if (target) { map.setCenter(target.center, target.zoom); }
    });
    document.addEventListener('keydown', function (e) {
      const index = ['1', '2', '3'].indexOf(e.key);
      if (index >= 0) { document.querySelectorAll('.tool')[index].click(); }
    });
  });
})();
