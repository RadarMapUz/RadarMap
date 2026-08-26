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
  const DRAFT = 0, ACCEPTED = 1, WITHDRAWN = 3;

  let kind = 'lanes';
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
      if (current && current.id) { closeCard(); return; }
      place(e.get('coords'), null);
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
      });
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
      if (e.key === 'Escape') { closeCard(); return; }
      if (e.key === 'Delete' || e.key === 'Backspace') {
        if (!inField && current && current.id) { e.preventDefault(); withdrawCurrent(); }
        return;
      }
      if (inField) { return; }
      if (e.key === '\\' || e.key === 'ё') { toggleSchema(); return; }
      if (e.key === ']' || e.key === 'ъ') { goTo(queueAt + 1); return; }
      if (e.key === '[' || e.key === 'х') { goTo(queueAt - 1); return; }
      const index = ['1', '2', '3', '4', '5', '6', '7', '8', '9'].indexOf(e.key);
      if (index >= 0 && buttons[index]) { buttons[index].click(); }
    });
  });
})();
