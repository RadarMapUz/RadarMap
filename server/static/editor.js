// Конструктор карты: ставим и правим объекты, магнит сажает их на ось дороги.
//
// Тот же стек, что у moderate.js: обычный скрипт файлом, без сборки и
// фреймворков. Панель открывают с телефона между делом, и страница, которая
// грузится за двести миллисекунд, здесь единственно верный выбор.
//
// Три правила, из которых выведено всё остальное (docs/plan_admin_ux.md).
//
// РАБОТА ИДЁТ С КЛАВИАТУРЫ, мышь отвечает только на вопрос «где». Никто не
// ставит одну правку: садятся и размечают перекрёсток целиком, и инструмент,
// где каждое число требует прицелиться в поле, на десятом перекрёстке будет
// брошен.
//
// ЛЮБОЕ ДЕЙСТВИЕ ОБРАТИМО ОДНИМ НАЖАТИЕМ. Не диалог подтверждения — он
// тормозит на каждом объекте и всё равно проматывается не глядя. Отмена после
// факта стоит ноль, пока не нужна.
//
// МАГНИТ НЕ ВЫБИРАЕТ ЗА ЧЕЛОВЕКА, но человеку есть чем ответить. «Приблизьте
// карту» ответом не является: приближение не разводит две проезжие части, они
// физически в двадцати метрах друг от друга.
(function () {
  const tools = document.querySelector('.tools');
  if (!tools || typeof ymaps === 'undefined') { return; }
  const base = tools.getAttribute('data-base') || '';

  // Названия видов. Код — контракт с сервером, а на карточке нужно слово:
  // «lanes» в заголовке читается как недоделка.
  const NAMES = { lanes: 'Полосы', turn_lanes: 'Направления полос',
                  u_turn: 'Разворот', geometry: 'Своя геометрия' };
  // Классы дорог — те же, что у OSM: от них зависит и ширина полотна, и то,
  // как дорогу нарисует телефон.
  const CLASSES = [
    { code: 1, name: 'Магистраль' }, { code: 2, name: 'Скоростная' },
    { code: 3, name: 'Проспект' },   { code: 4, name: 'Улица' },
    { code: 5, name: 'Второстепенная' }, { code: 6, name: 'Жилая' },
    { code: 7, name: 'Проезд, двор' },
  ];
  const WHYS = ['нет в OSM', 'OSM неверен', 'временная схема'];
  // Обстановка. Коды те же, что у точек из OSM: панель заводит объект ТОГО ЖЕ
  // вида, а не параллельный, поэтому на телефоне он рисуется тем же кодом и
  // добавлять там нечего.
  const POINTS = { 1: 'Светофор', 2: 'Лежачий полицейский', 3: 'Стоп-линия',
                   4: 'Разворот', 5: 'Пешеходный переход' };
  const DRAFT = 0, ACCEPTED = 1, WITHDRAWN = 3;

  let kind = 'lanes';
  let pointCode = 0;      // какой объект обстановки ставим (0 — никакой)
  let map = null;
  let objects = null;      // все правки в рамке
  let netLines = [];       // наши оси из тайлов
  let schema = false;      // наша подложка вместо спутника
  let ground = null;       // тёмная земля под схемой
  let roadsInFrame = [];   // последний ответ /api/roads
  let pickLines = [];      // подсветка кандидатов при неоднозначности
  let dragger = null;      // перетаскиваемая метка выбранной правки
  let current = null;      // что сейчас в карточке
  let known = {};          // id → правка, как её знает сервер
  let undoStack = null;    // одно действие назад — больше не нужно
  let toastTimer = null;

  // Выбор стороны запоминается на сессию: размечая проспект, выбираешь
  // сторону один раз, а не сорок.
  const remembered = {};

  const els = {
    card: document.getElementById('card'),
    hint: document.getElementById('hint'),
    toast: document.getElementById('toast'),
    todo: document.getElementById('todo'),
    work: document.getElementById('work'),
    worksum: document.getElementById('worksum'),
    find: document.getElementById('find'),
    found: document.getElementById('found'),
  };

  // Палец против курсора. Спрашиваем УКАЗАТЕЛЬ, а не ширину экрана: планшет с
  // пером бывает шире телефона, а мышь на маленьком окне остаётся мышью.
  const coarse = window.matchMedia
    && window.matchMedia('(pointer: coarse)').matches;

  // Очередь работы в видимой рамке и место в ней.
  let queue = [];
  let queueAt = -1;
  // Идём ПО очереди, а не двигаем карту руками.
  //
  // Различать обязательно: перелёт к следующему объекту сам двигает карту, а
  // движение карты пересобирает очередь — и место в ней теряется. Без этого
  // флага «дальше» всегда прыгало бы на первую строку новой рамки, то есть
  // ходило бы по кругу между двумя местами вместо того, чтобы идти вперёд.
  let walking = false;
  let walkTimer = null;

  function post(url, body) {
    return fetch(base + url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify(body),
    }).then(function (r) { return r.json().catch(function () { return {}; }); });
  }

  function get(url) {
    return fetch(base + url, { credentials: 'same-origin' })
      .then(function (r) { return r.json(); });
  }

  function hint(text) { els.hint.textContent = text; }

  function bbox() {
    const b = map.getBounds();
    return '?south=' + b[0][0] + '&west=' + b[0][1] +
           '&north=' + b[1][0] + '&east=' + b[1][1];
  }

  // --- Отмена -------------------------------------------------------------

  function offerUndo(text, action) {
    undoStack = action;
    els.toast.innerHTML = '';
    const label = document.createElement('span');
    label.textContent = text;
    const button = document.createElement('button');
    button.textContent = 'Отменить';
    button.addEventListener('click', undo);
    els.toast.appendChild(label);
    els.toast.appendChild(button);
    els.toast.classList.add('on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(hideToast, 10000);
  }

  function hideToast() {
    els.toast.classList.remove('on');
    undoStack = null;
  }

  function undo() {
    if (!undoStack) { return; }
    const action = undoStack;
    hideToast();
    action().then(function () { hint('Отменено.'); reloadEdits(); });
  }

  // --- Карточка -----------------------------------------------------------

  function closeCard() {
    els.card.hidden = true;
    current = null;
    clearPicks();
    if (dragger) { map.geoObjects.remove(dragger); dragger = null; }
  }

  function showCard(anchor) {
    els.card.hidden = false;
    const lanes = (current.props && current.props.lanes) || '';
    const where = anchor
      ? 'Класс ' + anchor.cls + (anchor.name ? ' · ' + anchor.name : '') +
        ' · азимут ' + anchor.bearing + '°'
      : 'Вне дороги';
    els.card.innerHTML = '';
    els.card.appendChild(node('h3', NAMES[current.kind] || current.kind));
    els.card.appendChild(node('div', where, 'muted'));

    // «Отправить в OSM» — только у своей геометрии и только у сохранённой.
    //
    // Дорога, отданная в OSM, поддерживается всем миром; наша — только нами.
    // Кнопка не украшение, а способ перестать платить за поддержку в одиночку:
    // отданная дорога вернётся обычной воскресной пересборкой, и своя копия
    // снимется по правилу «OSM догнал».
    if (current.id && current.kind === 'geometry') {
      const give = document.createElement('a');
      give.href = base + '/api/edit/' + current.id + '/osm';
      give.textContent = 'Отправить в OSM (файл для JOSM)';
      give.className = 'muted';
      give.style.display = 'block';
      give.style.marginTop = '8px';
      els.card.appendChild(give);
    }

    const lanesInput = field('Полос всего', 'number', lanes);
    els.card.appendChild(lanesInput.label);
    const noteInput = field('Почему', 'text', current.note || '');
    els.card.appendChild(noteInput.label);

    const save = node('button', current.id ? 'Сохранить' : 'Принять');
    save.addEventListener('click', function () {
      commit(parseInt(lanesInput.input.value, 10), noteInput.input.value);
    });
    els.card.appendChild(save);

    if (current.id) {
      const drop = node('button', 'Снять', 'ghost');
      drop.addEventListener('click', withdrawCurrent);
      els.card.appendChild(drop);
    }
    const cancel = node('button', 'Отмена', 'ghost');
    cancel.addEventListener('click', closeCard);
    els.card.appendChild(cancel);

    els.card.appendChild(node('div',
      current.id ? 'Enter — сохранить · Delete — снять · Esc — закрыть'
                 : 'Введите число и Enter · Esc — закрыть', 'muted keys'));
    lanesInput.input.focus();
    lanesInput.input.select();
  }

  function node(tag, text, cls) {
    const element = document.createElement(tag);
    if (text) { element.textContent = text; }
    if (cls) { element.className = cls; }
    return element;
  }

  function field(caption, type, value) {
    const label = node('label', caption);
    const input = document.createElement('input');
    input.type = type;
    if (type === 'number') { input.min = '1'; input.max = '15'; }
    input.value = value;
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); e.target.blur();
        document.querySelector('#card button').click(); }
    });
    label.appendChild(input);
    return { label: label, input: input };
  }

  // --- Сохранение ---------------------------------------------------------

  function commit(lanes, note) {
    if (!(lanes >= 1 && lanes <= 15)) { hint('Полос от 1 до 15.'); return; }
    const before = current.id ? known[current.id] : null;
    const payload = {
      kind: current.kind, geom: current.geom, raw: current.raw,
      anchor: current.anchor, fingerprint: current.fingerprint,
      props: { lanes: lanes }, note: note || '', status: ACCEPTED,
    };
    if (current.id) { payload.id = current.id; payload.version = current.version; }

    post('/api/edit', payload).then(function (result) {
      if (result.error) { hint(result.error); return; }
      closeCard();
      hint('Принято. Публикует владелец со своей машины.');
      // Работа сделана — очередь обязана пересобраться, даже если мы идём по
      // ней: размеченной дороге в списке больше не место.
      walking = false;
      clearTimeout(walkTimer);
      if (before) {
        offerUndo('Правка #' + result.id, function () {
          return post('/api/edit', Object.assign({}, before, {
            id: result.id, version: result.version, status: before.status,
          }));
        });
      } else {
        offerUndo(NAMES[payload.kind] + ' · ' + lanes, function () {
          return post('/api/edit/withdraw',
                      { id: result.id, version: result.version });
        });
      }
      reloadEdits();
    });
  }

  function withdrawCurrent() {
    if (!current || !current.id) { return; }
    const snapshot = known[current.id];
    const id = current.id, version = current.version;
    post('/api/edit/withdraw', { id: id, version: version }).then(function (result) {
      if (result.error) { hint(result.error); return; }
      closeCard();
      hint('Снято. История не удаляется.');
      offerUndo('Снята правка #' + id, function () {
        return post('/api/edit', Object.assign({}, snapshot, {
          id: id, version: version + 1, status: ACCEPTED,
        }));
      });
      reloadEdits();
    });
  }

  // --- Магнит и выбор дороги ---------------------------------------------

  function signature(candidates) {
    return candidates.map(function (c) { return c.cls + ':' + c.name; }).join('|');
  }

  function clearPicks() {
    pickLines.forEach(function (line) { map.geoObjects.remove(line); });
    pickLines = [];
  }

  // Обстановка ставится тем же магнитом, что и всё прочее: азимут и ширину
  // считает не человек, а сервер — он берёт их у дороги под точкой.
  function placePoint(coords, code) {
    post('/api/snap', { lat: coords[0], lon: coords[1], touch: coarse,
                        preferNode: code === 1 || code === 3 })
      .then(function (snap) {
        if (!snap.onRoad) {
          hint('Вне дороги. Обстановка ставится на проезжей части.');
          return;
        }
        post('/api/edit', {
          kind: 'point', geom: snap.point, raw: [coords[1], coords[0]],
          anchor: snap.anchor, fingerprint: snap.fingerprint,
          props: { point: code }, status: ACCEPTED,
        }).then(function (result) {
          if (result.error) { hint(result.error); return; }
          hint(POINTS[code] + ' поставлен. Публикует владелец со своей машины.');
          offerUndo(POINTS[code], function () {
            return post('/api/edit/withdraw',
                        { id: result.id, version: result.version });
          });
          walking = false;
          reloadEdits();
        });
      });
  }

  function place(coords, existing) {
    post('/api/snap', { lat: coords[0], lon: coords[1], touch: coarse })
      .then(function (snap) {
      const list = snap.candidates || [];
      if (!list.length) {
        hint('Вне дороги. Ворота публикации об этом спросят.');
        return;
      }
      if (!snap.ambiguous) { adopt(coords, list[0], snap, existing, null); return; }

      const key = signature(list);
      if (remembered[key] !== undefined && list[remembered[key]]) {
        adopt(coords, list[remembered[key]], snap, existing, 'память');
        return;
      }
      offerChoice(coords, list, snap, existing, key);
    });
  }

  // Обе дороги на карте разными цветами и выбор из двух-трёх строк. Это и есть
  // ответ человека там, где магнит не имеет права решать сам.
  function offerChoice(coords, list, snap, existing, key) {
    clearPicks();
    const colors = ['#3cdcff', '#ffb020', '#ff6b6b'];
    list.forEach(function (candidate, index) {
      const line = new ymaps.Polyline(
        candidate.points.map(function (p) { return [p[1], p[0]]; }), {},
        { strokeColor: colors[index], strokeWidth: 6, strokeOpacity: 0.75 });
      line.events.add('click', function (e) {
        e.stopPropagation();
        remembered[key] = index;
        adopt(coords, candidate, snap, existing, 'выбор');
      });
      map.geoObjects.add(line);
      pickLines.push(line);
    });

    els.card.hidden = false;
    els.card.innerHTML = '';
    els.card.appendChild(node('h3', 'Какая дорога?'));
    els.card.appendChild(node('div',
      'Две проезжие части рядом. Магнит не выбирает за вас — выбор запомнится '
      + 'до конца сеанса.', 'muted'));
    list.forEach(function (candidate, index) {
      const button = node('button', (index + 1) + ' · класс ' + candidate.cls +
        (candidate.name ? ' · ' + candidate.name : '') +
        ' · ' + candidate.meters + ' м', 'pick');
      button.style.borderColor = colors[index];
      button.addEventListener('click', function () {
        remembered[key] = index;
        adopt(coords, candidate, snap, existing, 'выбор');
      });
      els.card.appendChild(button);
    });
    const cancel = node('button', 'Отмена', 'ghost');
    cancel.addEventListener('click', closeCard);
    els.card.appendChild(cancel);
    hint('Выберите дорогу: 1–' + list.length + ' или клик по линии.');
  }

  function adopt(coords, candidate, snap, existing, source) {
    clearPicks();
    // Подсказка обязана говорить о ТЕКУЩЕМ состоянии. Оставленное «выберите
    // дорогу» после того, как выбор уже сделан, — мелкая неправда, из которых
    // и складывается недоверие к инструменту.
    hint(source === 'память'
      ? 'Сторона выбрана как в прошлый раз. Esc — выбрать другую.'
      : 'Класс ' + candidate.cls + (candidate.name ? ' · ' + candidate.name : '') +
        ' · ' + candidate.meters + ' м от клика.');
    current = existing ? Object.assign({}, existing) : {
      kind: kind, props: {}, note: '',
    };
    current.raw = [coords[1], coords[0]];
    current.geom = candidate.point;
    current.anchor = candidate.anchor;
    current.fingerprint = snap.fingerprint;
    showCard(candidate.anchor);
    attachDragger();
  }

  // Перетаскивание выбранной правки: магнит работает так же, как при клике.
  function attachDragger() {
    if (dragger) { map.geoObjects.remove(dragger); }
    dragger = new ymaps.Placemark(
      [current.geom[1], current.geom[0]], { hintContent: 'Тянуть' },
      { preset: 'islands#redCircleDotIcon', draggable: true });
    dragger.events.add('dragend', function () {
      const at = dragger.geometry.getCoordinates();
      place(at, current);
    });
    map.geoObjects.add(dragger);
  }

  // --- Слои ---------------------------------------------------------------

  function drawRoads() {
    get('/api/roads' + bbox()).then(function (data) {
      roadsInFrame = data.roads || [];
      renderRoads();
    });
  }

  // Метров в пикселе на текущем зуме. Ширина проезжей части приходит с сервера
  // В МЕТРАХ — иначе панель рисовала бы одно, а телефон другое, — и перевести
  // её в пиксели можно только здесь.
  function metersPerPixel() {
    const lat = map.getCenter()[0] * Math.PI / 180;
    return 156543.03392 * Math.cos(lat) / Math.pow(2, map.getZoom());
  }

  // Цвет асфальта по классу — те же тона, что на схеме телефона.
  function asphalt(cls) {
    if (cls <= 2) { return '#6b6a63'; }
    if (cls === 3) { return '#5e5d58'; }
    if (cls === 4) { return '#525252'; }
    if (cls <= 6) { return '#464646'; }
    return '#3c3c3c';
  }

  function line(points, options) {
    const shape = new ymaps.Polyline(
      points.map(function (p) { return [p[1], p[0]]; }), {}, options);
    map.geoObjects.add(shape);
    netLines.push(shape);
    return shape;
  }

  function renderRoads() {
    netLines.forEach(function (shape) { map.geoObjects.remove(shape); });
    netLines = [];
    if (ground) { map.geoObjects.remove(ground); ground = null; }

    if (!schema) {
      // Поверх спутника — только тонкие оси: подложка и так занята снимком,
      // а показать надо, к чему прилипнет магнит.
      roadsInFrame.forEach(function (road) {
        line(road.points, { strokeColor: '#38bdf8', strokeWidth: 2,
                            strokeOpacity: 0.45, zIndex: 200 });
      });
      return;
    }

    // Своя подложка. Требование §7.2 плана конструктора, и оно не про красоту:
    // объект, идеально поставленный по спутнику, на схеме может оказаться под
    // кромкой или за краем охвата. Здесь видно ровно то, что увидит водитель.
    const b = map.getBounds();
    // zIndex задаём ЯВНО. У полигона и ломаной он по умолчанию одинаковый, и
    // порядок добавления его не решает: земля ложилась поверх дорог, и схема
    // выглядела пустым чёрным полем — при полностью нарисованных линиях.
    ground = new ymaps.Polygon([[
      [b[0][0], b[0][1]], [b[0][0], b[1][1]],
      [b[1][0], b[1][1]], [b[1][0], b[0][1]], [b[0][0], b[0][1]],
    ]], {}, { fillColor: '#0e1013', strokeWidth: 0, zIndex: 100,
              interactivityModel: 'default#transparent' });
    map.geoObjects.add(ground);

    const perPixel = metersPerPixel();
    // Чем ближе к экрану дороги, тем позже они рисуются: мост обязан лечь
    // ПОВЕРХ того, что под ним, иначе развязка читается перекрёстком.
    const ordered = roadsInFrame.slice().sort(function (a, c) {
      return a.level - c.level;
    });
    ordered.forEach(function (road) {
      const width = Math.max(1.5, road.width / perPixel);
      // Кайма ТЕМНЕЕ земли: полотно читается лежащим на ней, а две улицы в
      // пятнадцати метрах не сливаются в одну широкую.
      line(road.points, { strokeColor: '#04060a', strokeWidth: width + 3,
                          strokeOpacity: 1, zIndex: 200 + road.level * 10 });
      line(road.points, { strokeColor: asphalt(road.cls), strokeWidth: width,
                          strokeOpacity: 1, zIndex: 201 + road.level * 10 });
    });
    ordered.forEach(function (road) {
      // Осевая — только там, где она есть в жизни: на дворовом проезде её нет,
      // а нарисованная была бы выдуманной деталью.
      if (road.oneWay || road.cls > 4) { return; }
      if (road.width / perPixel < 8) { return; }
      line(road.points, { strokeColor: '#e0d9b8', strokeWidth: 1.2,
                          strokeOpacity: 0.30, strokeStyle: 'shortdash',
                          zIndex: 240 });
    });
  }

  function toggleSchema() {
    schema = !schema;
    map.setType(schema ? 'yandex#map' : 'yandex#hybrid');
    renderRoads();
    hint(schema
      ? 'Своя схема: видно то, что увидит водитель. \\ — обратно на спутник.'
      : 'Спутник: видно, где объект стоит на самом деле. \\ — на схему.');
  }

  function reloadEdits() {
    get('/api/edits' + bbox()).then(function (data) {
      known = {};
      objects.removeAll();
      objects.add({
        type: 'FeatureCollection',
        features: (data.edits || []).map(function (edit) {
          known[edit.id] = edit;
          const lanes = edit.props && edit.props.lanes;
          return {
            type: 'Feature',
            id: edit.id,
            geometry: { type: 'Point', coordinates: [edit.geom[1], edit.geom[0]] },
            properties: {
              hintContent: (NAMES[edit.kind] || edit.kind) +
                (lanes ? ' · ' + lanes : ''),
            },
            options: {
              preset: edit.status === DRAFT
                ? 'islands#grayCircleDotIcon' : 'islands#blueCircleDotIcon',
            },
          };
        }),
      });
      reloadTodo();
    });
  }

  function select(id) {
    const edit = known[id];
    if (!edit) { return; }
    current = {
      id: edit.id, version: edit.version, kind: edit.kind,
      geom: edit.geom, raw: edit.raw, anchor: edit.anchor,
      fingerprint: edit.fingerprint, props: edit.props || {},
      note: edit.note || '',
    };
    showCard(edit.anchor);
    attachDragger();
    hint('Правка #' + id + '. Delete — снять, Esc — закрыть.');
  }

  // --- Очередь работы -----------------------------------------------------

  // Панель обязана говорить, что делать дальше. Пустой экран карты — это
  // вопрос «а где работать?», на который модератор отвечает своей памятью, а
  // она кончается на третьем сеансе.
  function reloadTodo() {
    if (walking) { renderTodo(); return; }
    get('/api/todo' + bbox()).then(function (data) {
      const drafts = (data.drafts || []).map(function (item) {
        return { title: 'Черновик #' + item.id + ' · ' + (NAMES[item.kind] || item.kind),
                 point: item.point, draft: true, id: item.id };
      });
      const lanes = (data.lanes || []).map(function (item) {
        // Имя, если оно есть; иначе направление. Опубликованные сейчас тайлы
        // имён не содержат вовсе, и «без имени · класс 3» не говорит ничего о
        // том, что перед тобой, — а «с юга на север» говорит.
        return { title: (item.name || item.heading) + ' · класс ' + item.cls +
                        ' · ' + item.meters + ' м',
                 point: item.point };
      });
      // Черновики первыми: начатая и не законченная работа не едет никуда, и
      // забыть её проще всего.
      queue = drafts.concat(lanes);
      queueAt = -1;
      renderTodo();
    });
  }

  function renderTodo() {
    els.todo.innerHTML = '';
    els.worksum.textContent = queue.length
      ? 'Здесь работать · ' + queue.length + (coarse ? '' : '   ( ] дальше, [ назад )')
      : 'В этой рамке размечено всё';
    if (!queue.length) {
      els.todo.appendChild(node('div',
        'Отодвиньте карту — работа найдётся рядом.', 'muted'));
      return;
    }
    queue.slice(0, 12).forEach(function (item, index) {
      const row = node('button', item.title, 'todo-row' + (item.draft ? ' draft' : ''));
      // Подсветку ставит САМА перерисовка, а не переход.
      //
      // Переход двигает карту, движение карты перерисовывает список, и
      // подсветка, поставленная переходом, стиралась бы этой перерисовкой —
      // причём асинхронно, то есть иногда бы срабатывала, а иногда нет. Хуже
      // отсутствующей подсветки только мерцающая.
      if (index === queueAt) { row.classList.add('on'); }
      row.addEventListener('click', function () { goTo(index); });
      els.todo.appendChild(row);
    });
  }

  function goTo(index) {
    if (!queue.length) { return; }
    queueAt = (index + queue.length) % queue.length;
    const item = queue[queueAt];
    walking = true;
    clearTimeout(walkTimer);
    walkTimer = setTimeout(function () { walking = false; }, 1200);
    map.setCenter([item.point[1], item.point[0]], Math.max(map.getZoom(), 18));
    hint(item.title);
    renderTodo();
    if (coarse) { els.work.open = false; }
    if (item.draft) { setTimeout(function () { select(item.id); }, 400); }
  }

  // --- Рисование дороги ---------------------------------------------------
  //
  // Три действия и ни одного лишнего: щелчок ставит вершину, Enter заканчивает,
  // Esc отменяет всю линию, Backspace снимает последнюю вершину. Пока ведёшь —
  // рядом видно длину в метрах: без неё «двадцать метров» и «двести» на экране
  // выглядят одинаково, а ворота публикации считают именно метры.

  // Ближе этого конец линии считается примкнувшим к чужой дороге.
  const ATTACH_METERS = 12;

  let drawing = null;     // { points: [[lon,lat]], cls }
  let chosenVertex = -1;  // выбранная вершина: её убирает Delete
  let drawLine = null;    // нарисованная часть
  let drawDots = [];      // вершины, каждую можно тянуть

  function drawnMeters(points) {
    let total = 0;
    for (let i = 1; i < points.length; i++) {
      const a = points[i - 1], b = points[i];
      const lat = (a[1] + b[1]) / 2 * Math.PI / 180;
      total += Math.hypot((b[1] - a[1]) * 111320,
                          (b[0] - a[0]) * 111320 * Math.cos(lat));
    }
    return Math.round(total);
  }

  function startDrawing(cls) {
    closeCard();
    drawing = { points: [], cls: cls };
    hint('Щелчок — вершина, Enter — закончить, Backspace — снять последнюю, '
         + 'Esc — отменить.');
    renderDrawing();
  }

  function renderDrawing() {
    if (drawLine) { map.geoObjects.remove(drawLine); drawLine = null; }
    drawDots.forEach(function (dot) { map.geoObjects.remove(dot); });
    drawDots = [];
    if (!drawing || !drawing.points.length) { return; }

    if (drawing.points.length >= 2) {
      drawLine = new ymaps.Polyline(
        drawing.points.map(function (p) { return [p[1], p[0]]; }), {},
        { strokeColor: '#ffb020', strokeWidth: 5, strokeOpacity: 0.9, zIndex: 300 });
      map.geoObjects.add(drawLine);
    }
    // Вершины ТЯНУТСЯ. Это и есть правка ломаной: диалог «изменить точку №3»
    // объяснять пришлось бы, а перетаскивание — нет.
    drawing.points.forEach(function (point, index) {
      const dot = new ymaps.Placemark([point[1], point[0]],
        { hintContent: 'Вершина ' + (index + 1) + ' · Delete — убрать' },
        { preset: 'islands#orangeCircleDotIcon', draggable: true, zIndex: 310 });
      dot.events.add('dragend', function () {
        const at = dot.geometry.getCoordinates();
        drawing.points[index] = [at[1], at[0]];
        renderDrawing();
      });
      // Щелчок по вершине выбирает её; Delete убирает выбранную. Убирать по
      // щелчку нельзя: попасть в вершину при правке приходится часто, и
      // каждый промах стирал бы работу.
      dot.events.add('click', function (e) {
        e.stopPropagation();
        chosenVertex = index;
        hint('Вершина ' + (index + 1) + ' выбрана · Delete — убрать');
      });
      map.geoObjects.add(dot);
      drawDots.push(dot);
    });

    // Середины отрезков. Потянул — там появилась вершина.
    //
    // Это единственный способ добавить точку в готовую линию, который не
    // требует объяснений: в любом редакторе карт он такой же, и рука его уже
    // знает.
    for (let i = 1; i < drawing.points.length; i++) {
      const a = drawing.points[i - 1], b = drawing.points[i];
      const middle = [(a[1] + b[1]) / 2, (a[0] + b[0]) / 2];
      const ghost = new ymaps.Placemark(middle,
        { hintContent: 'Потянуть — добавить вершину' },
        { preset: 'islands#grayCircleDotIcon', draggable: true,
          iconOpacity: 0.55, zIndex: 305 });
      ghost.events.add('dragend', (function (at) {
        return function () {
          const to = ghost.geometry.getCoordinates();
          drawing.points.splice(at, 0, [to[1], to[0]]);
          renderDrawing();
        };
      })(i));
      map.geoObjects.add(ghost);
      drawDots.push(ghost);
    }

    // Ручка переноса всей линии.
    //
    // Отдельной ручкой, а не перетаскиванием самой линии: линия лежит поверх
    // карты, и таскать её пальцем значило бы отобрать у карты панораму — самое
    // частое движение в работе.
    if (drawing.points.length >= 2) {
      const first = drawing.points[0];
      const last = drawing.points[drawing.points.length - 1];
      const handle = new ymaps.Placemark(
        [(first[1] + last[1]) / 2, (first[0] + last[0]) / 2],
        { hintContent: 'Потянуть — перенести всю дорогу' },
        { preset: 'islands#blueCircleDotIcon', draggable: true, zIndex: 315 });
      let from = null;
      handle.events.add('dragstart', function () {
        from = handle.geometry.getCoordinates();
      });
      handle.events.add('dragend', function () {
        const to = handle.geometry.getCoordinates();
        const dLat = to[0] - from[0], dLon = to[1] - from[1];
        drawing.points = drawing.points.map(function (p) {
          return [p[0] + dLon, p[1] + dLat];
        });
        renderDrawing();
      });
      map.geoObjects.add(handle);
      drawDots.push(handle);
    }
    hint('Вершин ' + drawing.points.length + ' · ' +
         drawnMeters(drawing.points) + ' м · Enter — закончить');
  }

  // Прилипают только КОНЦЫ линии, а не каждая вершина.
  //
  // Дорога, нарисованная РЯДОМ с существующей, а не В неё, — не дорога, а
  // параллельная линия: маршрут по ней не пройдёт, а на схеме она останется
  // тупиком. Но притягивать середину нельзя: линию стянуло бы на соседние
  // улицы, и нарисовать съезд стало бы невозможно.
  function attachEnd(coords) {
    return post('/api/snap', { lat: coords[0], lon: coords[1], touch: coarse })
      .then(function (snap) {
        const near = (snap.candidates || [])[0];
        if (near && !snap.ambiguous && near.meters <= ATTACH_METERS) {
          return near.point;
        }
        return [coords[1], coords[0]];
      }, function () { return [coords[1], coords[0]]; });
  }

  function addVertex(coords) {
    if (drawing.points.length === 0) {
      attachEnd(coords).then(function (point) {
        drawing.points.push(point);
        renderDrawing();
      });
      return;
    }
    drawing.points.push([coords[1], coords[0]]);
    renderDrawing();
  }

  function finishDrawing() {
    if (!drawing || drawing.points.length < 2) {
      hint('Нужно хотя бы две вершины.');
      return;
    }
    const cls = drawing.cls;
    const last = drawing.points[drawing.points.length - 1];
    // Последнюю вершину притягиваем на выходе: пока рисуешь, неизвестно, какая
    // из них последняя.
    attachEnd([last[1], last[0]]).then(function (point) {
      const points = drawing.points.slice(0, -1).concat([point]);
      cancelDrawing(true);
      current = { kind: 'geometry', geom: points, raw: points[0],
                  props: { cls: cls }, note: '' };
      showRoadCard(points, cls);
    });
  }

  function cancelDrawing(quiet) {
    drawing = null;
    chosenVertex = -1;
    renderDrawing();
    if (!quiet) { hint('Рисование отменено.'); }
  }

  function showRoadCard(points, cls) {
    els.card.hidden = false;
    els.card.innerHTML = '';
    els.card.appendChild(node('h3', 'Своя дорога'));
    els.card.appendChild(node('div',
      'Вершин ' + points.length + ' · ' + drawnMeters(points) + ' м', 'muted'));

    const kind = document.createElement('select');
    CLASSES.forEach(function (item) {
      const option = document.createElement('option');
      option.value = item.code;
      option.textContent = item.code + ' · ' + item.name;
      if (item.code === cls) { option.selected = true; }
      kind.appendChild(option);
    });
    const kindLabel = node('label', 'Класс дороги');
    kindLabel.appendChild(kind);
    els.card.appendChild(kindLabel);

    const lanes = field('Полос всего (пусто — по классу)', 'number', '');
    els.card.appendChild(lanes.label);

    const oneway = check('Односторонняя');
    const bridge = check('Мост');
    els.card.appendChild(oneway.label);
    els.card.appendChild(bridge.label);

    // Причина обязательна и закрытым списком: свободный текст через полгода
    // превращается в «тест», «пока так» и «см. выше».
    const why = document.createElement('select');
    WHYS.forEach(function (text) {
      const option = document.createElement('option');
      option.value = text;
      option.textContent = text;
      why.appendChild(option);
    });
    const whyLabel = node('label', 'Почему дорога своя');
    whyLabel.appendChild(why);
    els.card.appendChild(whyLabel);

    const save = node('button', 'Принять');
    save.addEventListener('click', function () {
      const count = parseInt(lanes.input.value, 10);
      current.props = {
        cls: parseInt(kind.value, 10),
        oneway: oneway.input.checked,
        bridge: bridge.input.checked,
        why: why.value,
      };
      if (count >= 1 && count <= 15) { current.props.lanes = count; }
      current.status = ACCEPTED;
      post('/api/edit', current).then(function (result) {
        if (result.error) { hint(result.error); return; }
        closeCard();
        hint('Дорога принята. Публикует владелец со своей машины.');
        offerUndo('Своя дорога · ' + drawnMeters(points) + ' м', function () {
          return post('/api/edit/withdraw',
                      { id: result.id, version: result.version });
        });
        walking = false;
        reloadEdits();
      });
    });
    els.card.appendChild(save);
    const cancel = node('button', 'Отмена', 'ghost');
    cancel.addEventListener('click', closeCard);
    els.card.appendChild(cancel);
  }

  function check(caption) {
    const label = node('label', caption);
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.style.width = 'auto';
    input.style.marginRight = '8px';
    label.insertBefore(input, label.firstChild);
    return { label: label, input: input };
  }

  // --- Поиск места --------------------------------------------------------
  //
  // Три разных вопроса под одной строкой, и порядок разбора — от точного к
  // приблизительному.
  //
  // «#12» — номер правки. О ней уже говорили (в очереди изменений, в переписке),
  // и искать её глазами по карте не поиск. Ищется мимо рамки и находит даже
  // снятую: она есть, просто не едет на телефоны.
  //
  // «41.31, 69.28» — координаты. Приходят из жалобы водителя, из чужой карты,
  // из сообщения. Разбирать их отдельно надо потому, что геокодер на паре чисел
  // отвечает чем угодно, кроме нужного места.
  //
  // Всё остальное — адрес, и его знает Яндекс. Своих имён улиц у нас нет: в
  // опубликованных тайлах поле имени пустое у всех записей.

  const COORDS = /^\s*(-?\d{1,3}[.,]\d+)\s*[, ]\s*(-?\d{1,3}[.,]\d+)\s*$/;

  function showFound(items) {
    els.found.innerHTML = '';
    els.found.hidden = !items.length;
    items.slice(0, 6).forEach(function (item) {
      const row = node('button', item.title);
      row.addEventListener('click', function () {
        els.found.hidden = true;
        els.find.value = '';
        walking = false;
        map.setCenter(item.center, item.zoom || 18);
        if (item.select) { setTimeout(function () { select(item.select); }, 500); }
      });
      els.found.appendChild(row);
    });
  }

  function search(text) {
    const query = (text || '').trim();
    els.found.hidden = true;
    if (!query) { return; }

    const byId = query.match(/^#?(\d{1,9})$/);
    if (byId) {
      get('/api/edits?id=' + byId[1]).then(function (data) {
        const edit = (data.edits || [])[0];
        if (!edit) { hint('Правки #' + byId[1] + ' нет.'); return; }
        known[edit.id] = edit;
        showFound([{ title: 'Правка #' + edit.id + ' · ' +
                            (NAMES[edit.kind] || edit.kind),
                     center: [edit.geom[1], edit.geom[0]], zoom: 19,
                     select: edit.id }]);
      });
      return;
    }

    const point = query.match(COORDS);
    if (point) {
      const lat = parseFloat(point[1].replace(',', '.'));
      const lon = parseFloat(point[2].replace(',', '.'));
      if (Math.abs(lat) <= 90 && Math.abs(lon) <= 180) {
        showFound([{ title: lat.toFixed(5) + ', ' + lon.toFixed(5),
                     center: [lat, lon], zoom: 19 }]);
        return;
      }
    }

    // Адрес — через СВОЙ сервер, а не через ymaps.geocode.
    //
    // Геокодер в JS-API работает через JSONP: он подгружает с чужого хоста
    // СКРИПТ, а не данные, и ответ исполняется как код. Разрешить это в CSP
    // панели значило бы открыть выполнение чужого кода на странице, где лежит
    // сессия модератора, — ради строки поиска.
    //
    // Рамка карты идёт с запросом: «Навои» есть не в одном городе, а модератор
    // ищет ту улицу, над которой сейчас сидит.
    get('/api/geocode?q=' + encodeURIComponent(query) + '&' + bbox().slice(1))
      .then(function (data) {
        if (data.error) { hint(data.error); return; }
        const items = (data.places || []).map(function (place) {
          return { title: place.title, center: [place.lat, place.lon], zoom: 18 };
        });
        if (!items.length) { hint('Ничего не нашлось.'); return; }
        showFound(items);
      }, function () { hint('Поиск недоступен.'); });
  }

  // --- Место в адресе -----------------------------------------------------

  function placeFromHash() {
    const parts = (location.hash || '').replace('#', '').split(',');
    const lat = parseFloat(parts[0]);
    const lon = parseFloat(parts[1]);
    const zoom = parseInt(parts[2], 10);
    if (!isFinite(lat) || !isFinite(lon)) { return null; }
    return { center: [lat, lon], zoom: isFinite(zoom) ? zoom : 18 };
  }

  ymaps.ready(function () {
    // Список открыт на столе и свёрнут на телефоне: там его открывают, когда
    // ИЩУТ работу, а не когда её делают, и развёрнутым он закрывает карту.
    els.work.open = !coarse;
    const start = placeFromHash() || { center: [41.311, 69.280], zoom: 17 };
    map = new ymaps.Map('map', {
      center: start.center, zoom: start.zoom,
      controls: ['zoomControl', 'typeSelector'],
    }, { suppressMapOpenBlock: true });
    map.setType('yandex#hybrid');
    objects = new ymaps.ObjectManager({ clusterize: false });
    map.geoObjects.add(objects);

    objects.objects.events.add('click', function (e) {
      select(e.get('objectId'));
    });
    map.events.add('click', function (e) {
      if (drawing) { addVertex(e.get('coords')); return; }
      if (pointCode) { placePoint(e.get('coords'), pointCode); return; }
      if (current && current.id) { closeCard(); return; }
      place(e.get('coords'), null);
    });
    // Двойной щелчок заканчивает линию — привычка из любого редактора карт.
    map.events.add('dblclick', function (e) {
      if (drawing) { e.preventDefault(); finishDrawing(); }
    });
    // reloadEdits сам обновляет очередь: поставленная правка снимает работу
    // из списка, и звать обе вручную значило бы качать очередь дважды.
    map.events.add('boundschange', function () { drawRoads(); reloadEdits(); });
    // Зум меняет метры на пиксель, то есть ВСЮ ширину полотна. Без пересчёта
    // схема на другом масштабе врала бы о том, что увидит водитель.
    map.events.add('actionend', function () { if (schema) { renderRoads(); } });
    drawRoads();
    reloadEdits();

    window.addEventListener('hashchange', function () {
      const target = placeFromHash();
      if (target) { map.setCenter(target.center, target.zoom); }
    });

    const buttons = Array.prototype.slice.call(document.querySelectorAll('.tool'));
    buttons.forEach(function (button) {
      button.addEventListener('click', function () {
        buttons.forEach(function (b) { b.classList.remove('on'); });
        button.classList.add('on');
        kind = button.getAttribute('data-kind');
        const cls = button.getAttribute('data-cls');
        const code = button.getAttribute('data-point');
        pointCode = code ? parseInt(code, 10) : 0;
        if (cls) {
          startDrawing(parseInt(cls, 10));
        } else {
          cancelDrawing(true);
          if (pointCode) { hint('Щелчок по дороге — ' + POINTS[pointCode] + '.'); }
        }
      });
    });

    els.find.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); search(els.find.value); }
      if (e.key === 'Escape') { els.find.value = ''; els.found.hidden = true;
                                els.find.blur(); }
      // Клавиши инструментов не должны срабатывать, пока набирают адрес.
      e.stopPropagation();
    });

    document.addEventListener('keydown', function (e) {
      if (e.metaKey || e.ctrlKey) {
        if (e.key === 'z' || e.key === 'я') { e.preventDefault(); undo(); }
        return;
      }
      const inField = e.target && e.target.tagName === 'INPUT';
      // Цифры при открытом выборе дороги — это выбор, а не смена инструмента.
      if (pickLines.length && /^[1-9]$/.test(e.key)) {
        const picks = document.querySelectorAll('#card .pick');
        if (picks[Number(e.key) - 1]) { picks[Number(e.key) - 1].click(); }
        return;
      }
      if (e.key === 'Escape') {
        if (drawing) { cancelDrawing(); } else { closeCard(); }
        return;
      }
      if (drawing && e.key === 'Enter') { e.preventDefault(); finishDrawing(); return; }
      if (drawing && e.key === 'Backspace') {
        e.preventDefault();
        drawing.points.pop();
        chosenVertex = -1;
        renderDrawing();
        return;
      }
      if (drawing && e.key === 'Delete') {
        e.preventDefault();
        if (chosenVertex < 0) { hint('Сначала щёлкните по вершине.'); return; }
        if (drawing.points.length <= 2) {
          hint('В линии останется меньше двух вершин — рисовать будет нечего.');
          return;
        }
        drawing.points.splice(chosenVertex, 1);
        chosenVertex = -1;
        renderDrawing();
        return;
      }
      if (e.key === 'Delete' || e.key === 'Backspace') {
        if (!inField && current && current.id) { e.preventDefault(); withdrawCurrent(); }
        return;
      }
      if (inField) { return; }
      if (e.key === '\\' || e.key === 'ё') { toggleSchema(); return; }
      if (e.key === ']' || e.key === 'ъ') { goTo(queueAt + 1); return; }
      if (e.key === '[' || e.key === 'х') { goTo(queueAt - 1); return; }
      // Классы дорог — на буквах, а не на цифрах: цифры уже заняты видами
      // объектов, и одна клавиша на две вещи — это не экономия, а ошибка.
      const letters = { q: 3, й: 3, w: 4, ц: 4, e: 6, у: 6, r: 7, к: 7 };
      const cls = letters[e.key.toLowerCase()];
      if (cls) {
        const button = document.querySelector('.draw [data-cls="' + cls + '"]');
        if (button) { button.click(); }
        return;
      }
      // Обстановка — на соседнем ряду букв: рука не путает ряды так, как
      // путает соседние клавиши в одном.
      const marks = { a: 1, ф: 1, s: 5, ы: 5, d: 3, в: 3, f: 4, а: 4, g: 2, п: 2 };
      const code = marks[e.key.toLowerCase()];
      if (code) {
        const button = document.querySelector('[data-point="' + code + '"]');
        if (button) { button.click(); }
        return;
      }
      const index = ['1', '2', '3', '4', '5', '6', '7', '8', '9'].indexOf(e.key);
      if (index >= 0 && buttons[index]) { buttons[index].click(); }
    });
  });
})();
