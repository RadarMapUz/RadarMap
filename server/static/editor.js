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
  // Виды правок словами. Список ПОЛНЫЙ и совпадает с KIND_NAMES в
  // map_edits.py: неназванный вид показывался кодом — «point», «area», —
  // а код на экране читается как недоделка.
  const NAMES = { lanes: 'Полосы', turn_lanes: 'Направления полос',
                  u_turn: 'Разворот', geometry: 'Своя геометрия',
                  point: 'Обстановка', remove: 'Убрана дорога',
                  lock: 'Размеченная область', name: 'Название',
                  area: 'Местность' };
  // Классы дорог — те же, что у OSM: от них зависит и ширина полотна, и то,
  // как дорогу нарисует телефон.
  const CLASSES = [
    { code: 1, name: 'Магистраль' }, { code: 2, name: 'Скоростная' },
    { code: 3, name: 'Проспект' },   { code: 4, name: 'Улица' },
    { code: 5, name: 'Второстепенная' }, { code: 6, name: 'Жилая' },
    { code: 7, name: 'Проезд, двор' },
  ];
  function className(cls) {
    const found = CLASSES.filter(function (item) { return item.code === cls; })[0];
    return found ? found.name : 'дорога';
  }

  // Ширина рисуемой дороги в метрах — та же формула, что у сервера и у
  // телефона. Держать её здесь пришлось: пока линию ведут, правки ещё нет, и
  // спросить у сервера не у чего. Значения совпадают с LANE_METERS и
  // DEFAULT_LANES в map_edits.py — расхождение поймает тест раскладки.
  const LANE_METERS = { 1: 3.75, 2: 3.75, 3: 3.75, 4: 3.5, 5: 3.5, 6: 3.5, 7: 4.5 };
  const DEFAULT_LANES = { 1: 6, 2: 6, 3: 6, 4: 4, 5: 4, 6: 2, 7: 1 };

  function classWidth(cls) {
    return (DEFAULT_LANES[cls] || 2) * (LANE_METERS[cls] || 3.5);
  }

  const WHYS = ['нет в OSM', 'OSM неверен', 'временная схема'];
  const REMOVE_WHYS = ['нет в жизни', 'перекрыта', 'ошибка OSM'];
  // Виды местности — те же коды, что у слоёв из OSM.
  const AREAS = { 2: 'Зелень', 1: 'Вода', 4: 'Квартал', 6: 'Дом', 9: 'Островок' };
  // Дом обводится по одному, и порог у него свой: типовой дом в периметре —
  // сорок метров, общий порог местности выбросил бы половину нарисованных.
  const HOUSE_AREA = 6;
  // Заливка обведённого — тех же тонов, что слои местности на схеме телефона.
  const AREA_FILL = { 9: '#dfe5d677', 2: '#1d3a2455', 1: '#16324a55', 4: '#1a1d2255',
                     6: '#21243066' };
  // Обстановка. Коды те же, что у точек из OSM: панель заводит объект ТОГО ЖЕ
  // вида, а не параллельный, поэтому на телефоне он рисуется тем же кодом и
  // добавлять там нечего.
  const POINTS = { 1: 'Светофор', 2: 'Лежачий полицейский', 3: 'Стоп-линия',
                   4: 'Разворот', 5: 'Пешеходный переход' };
  const DRAFT = 0, ACCEPTED = 1, PUBLISHED = 2, WITHDRAWN = 3;
  // Направление одной полосы: значение — как в turn:lanes OSM.
  const TURNS = [['left', '↰ налево'], ['slight_left', '↖ левее'], ['through', '↑ прямо'],
                 ['slight_right', '↗ правее'], ['right', '↱ направо'],
                 ['left;through', '↰↑ налево и прямо'], ['through;right', '↑↱ прямо и направо'],
                 ['left;through;right', '↰↑↱ все'], ['reverse', '↶ разворот'],
                 ['left;reverse', '↶↰ разворот и налево'], ['none', '— без стрелки']];

  // Состояние правки — ТРЕМЯ способами сразу: цветом, штрихом и подписью.
  //
  // Одного цвета мало, и это не вкусовщина: на солнце через стекло цвет
  // умирает первым, а панель открывают и в машине. Штрих переживает солнце,
  // подпись переживает и штрих.
  //
  // Вопрос «черновик, принята или уже на телефонах» — главный, который
  // модератор задаёт своей работе, и до сих пор ответа на него на карте не
  // было вовсе: своя дорога выглядела чужой.
  const STATES = {
    0: { colour: '#8a8f98', dash: [6, 6], what: 'черновик' },
    1: { colour: '#ffb020', dash: [14, 6], what: 'принята, ждёт публикации' },
    2: { colour: '#38e58c', dash: null, what: 'опубликована' },
  };

  function stateOf(edit) {
    return STATES[edit.status] || STATES[1];
  }

  // Инструмент по умолчанию — СТРЕЛКА, как в любом редакторе. Пока выбран
  // какой-нибудь «Полосы», щелчок по улице обязан делать полосы; взять улицу
  // и потянуть можно только тогда, когда ничего другого не выбрано.
  let kind = 'select';
  let pointCode = 0;      // какой объект обстановки ставим (0 — никакой)
  let markingArea = false; // следующий щелчок размечает область
  let map = null;
  let objects = null;      // все правки в рамке
  let netLines = [];       // наши оси из тайлов
  // Своя карта — ХОЛСТ ПО УМОЛЧАНИЮ, а не второй взгляд. Конструктор
  // дорабатывает нашу схему: открывать его на чужом снимке значит показывать
  // не тот предмет, с которым работают, и прятать всю уже построенную сеть за
  // клавишей.
  let schema = true;
  let roadsInFrame = [];   // последний ответ /api/roads
  let mineShapes = [];     // своя работа на карте: линии и контуры правок
  let editsInFrame = [];   // последний ответ /api/edits
  let landInFrame = [];    // местность из тайлов: вода, зелень, дома
  let landShapes = [];     // её фигуры на карте
  let streetsInFrame = []; // склеенные улицы последнего кадра: по ним ищем щелчок
  // Дальний план приезжает КОСТЯКОМ: в наборе «f» раздельные проезжие сведены
  // в одну ось, и куски склеены через перекрёстки. Смотреть на него можно,
  // править по нему — нет: правка села бы между проезжими частями.
  let skeletonFrame = false;
  let placesInFrame = [];  // города и посёлки последнего кадра
  let pointsInFrame = [];  // обстановка: из тайлов и своя
  let markLayer = [];      // её отрисовка на подложке
  let areasInFrame = [];   // размеченные области
  // Поверхность дорог, посчитанная СБОРКОЙ: полотно, перекрёстки, фаски.
  // Пусто — значит на сервере лежат тайлы без набора «d»; тогда считаем сами,
  // как раньше. Пустая карта хуже медленной.
  let surfaceInFrame = [];
  // Кандидаты от нейросети: обводки зданий, которых в OSM ещё нет.
  //
  // Выключены по умолчанию, и это не осторожность: их сотни на кадр, и
  // включённые всегда они превратили бы схему в кашу из чужих догадок.
  // Включает их модератор тогда, когда сел обводить застройку.
  let candidatesOn = false;
  let candidatesInFrame = [];
  const SURFACE_ROAD = 7, SURFACE_JUNCTION = 8, SURFACE_MEDIAN = 9;
  let areaLayer = [];
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
    cover: document.getElementById('cover'),
    viewSchema: document.getElementById('viewschema'),
    viewSat: document.getElementById('viewsat'),
    viewDay: document.getElementById('viewday'),
  };

  let onlyMine = false;   // показывать только нарисованное руками

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

  // Ответ сервера, который НЕ ВРЁТ.
  //
  // Было так: тело ответа разбиралось как JSON, а не разобралось — считалось
  // пустым объектом. Пятисотка отдаёт HTML, значит `result.error` пуст, значит
  // панель говорила «сохранено» ровно тогда, когда сервер ничего не сохранил.
  // Это худший класс ошибки: человек уходит уверенным, что работа сделана.
  //
  // Обрыв связи — то же самое: fetch отклоняется, а необработанное отклонение
  // видно только в консоли, которую за рулём никто не открывает.
  function answer(response) {
    return response.json().catch(function () { return {}; }).then(function (body) {
      if (response.ok) { return body; }
      if (response.status === 401) {
        return { error: 'Сессия кончилась. Откройте панель заново.' };
      }
      return { error: body.error || ('Сервер ответил ' + response.status +
                                     '. Правка НЕ сохранена.') };
    });
  }

  function offline() {
    return { error: 'Нет связи с сервером. Правка НЕ сохранена.' };
  }

  function post(url, body) {
    return fetch(base + url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify(body),
    }).then(answer, offline);
  }

  function get(url, signal) {
    const options = { credentials: 'same-origin' };
    if (signal) { options.signal = signal; }
    return fetch(base + url, options)
      .then(answer, function (error) {
        // Отменённый запрос — не обрыв связи, а наше собственное решение.
        // Показывать «нет связи» на каждую отмену значит пугать модератора
        // ровно тогда, когда всё работает как задумано.
        if (error && error.name === 'AbortError') { return { aborted: true }; }
        return offline();
      })
      .then(function (body) {
        if (body && body.aborted) { return body; }
        // Чтение молчать тоже не вправе: пустой список работы неотличим от
        // «всё размечено», а пустая карта — от «здесь нет дорог».
        if (body && body.error) { hint(body.error); return {}; }
        return body;
      });
  }

  function hint(text) { els.hint.textContent = text; }

  const KEYS = [
    ['Инструменты', [
      ['V', 'выбрать дорогу'], ['1', 'полосы'], ['2', 'направления полос'],
      ['3', 'разворот'], ['Z', 'разметить область'],
    ]],
    ['Нарисовать', [
      ['Q', 'проспект'], ['W', 'улица'], ['E', 'жилая'], ['R', 'проезд'],
      ['H', 'обвести дом'],
    ]],
    ['Обстановка', [
      ['A', 'светофор'], ['S', 'пешеходный переход'], ['D', 'стоп-линия'],
      ['F', 'разворот'], ['G', 'лежачий полицейский'],
    ]],
    ['Во время рисования', [
      ['Enter', 'закончить'], ['Esc', 'отменить'],
      ['Backspace', 'убрать последнюю вершину'],
      ['Delete', 'убрать выбранную вершину'],
      ['Ctrl+D', 'не примыкать концом'],
    ]],
    ['Прочее', [
      ['\\', 'снимок в iD'], ['C', 'кандидаты нейросети'],
      ['[', 'предыдущая работа в очереди'], [']', 'следующая'],
      ['Ctrl+Z', 'отменить последнее'], ['?', 'этот список'],
    ]],
  ];

  let keysShown = false;

  function toggleKeysCard() {
    keysShown = !keysShown;
    if (!keysShown) { closeCard(); return; }
    els.card.hidden = false;
    els.card.innerHTML = '';
    els.card.appendChild(node('h3', 'Горячие клавиши'));
    KEYS.forEach(function (group) {
      els.card.appendChild(node('div', group[0], 'muted'));
      group[1].forEach(function (pair) {
        const row = document.createElement('div');
        row.style.display = 'flex';
        row.style.justifyContent = 'space-between';
        row.style.gap = '12px';
        const key = document.createElement('b');
        key.textContent = pair[0];
        const what = document.createElement('span');
        what.textContent = pair[1];
        what.className = 'muted';
        row.appendChild(key);
        row.appendChild(what);
        els.card.appendChild(row);
      });
    });
    // Буквы работают в ОБЕИХ раскладках — это уже так в коде, и об этом
    // стоит сказать: иначе человек с кириллицей решит, что клавиши не
    // работают, и вернётся к мыши навсегда.
    els.card.appendChild(node('div',
      'Буквы работают и в русской раскладке.', 'muted'));
  }

  /// Беда показывается РЯДОМ С ОБЪЕКТОМ и не исчезает сама.
  ///
  /// Строка внизу — место, где панель ГОВОРИТ: сообщение живёт несколько
  /// секунд и уходит. Для «сохранено» это верно, для «не сохранено» — нет:
  /// правка требует решения, а решение нельзя принять, если о нём успели
  /// забыть, пока смотрели на карту.
  ///
  /// Здесь же и повтор: обрыв связи — самая частая причина, и переделывать
  /// работу заново из-за неё незачем.
  function problem(text, coords, retry) {
    if (!coords || !map || !map.balloon) { hint(text); return; }
    const body = document.createElement('div');
    const line = document.createElement('div');
    line.textContent = text;
    body.appendChild(line);
    if (retry) {
      const again = document.createElement('button');
      again.textContent = 'Повторить';
      again.className = 'ghost';
      again.style.marginTop = '8px';
      again.addEventListener('click', function () {
        map.balloon.close();
        retry();
      });
      body.appendChild(again);
    }
    map.balloon.open([coords[1], coords[0]], { content: body },
                     { closeButton: true });
  }

  function boxQuery(box) {
    return '?south=' + box[0] + '&west=' + box[1] +
           '&north=' + box[2] + '&east=' + box[3];
  }

  /// Рамка ДЛЯ ОДИНОЧНОГО запроса: всегда от текущего вида, с тем же запасом.
  /// Загрузка кадра строит свою рамку сама и держит её — иначе поиск и очередь
  /// спрашивали бы о месте, где карта была минуту назад.
  function bbox() { return boxQuery(wide(map.getBounds())); }

  // --- Загрузка: с запасом, со схлопыванием и с отменой --------------------
  //
  // Раньше КАЖДОЕ движение карты слало пять запросов, без схлопывания и без
  // отмены. Проехать туда-сюда значило запустить десятки наложенных запросов,
  // и поздний ответ на старую рамку затирал свежий кадр: на экране пусто, а
  // в консоли всё «успешно». Отсюда три правила.
  //
  // Первое: просим ЗАПАС вокруг экрана и не спрашиваем ничего, пока рамка из
  // него не вышла. Движение внутри запаса не стоит ни одного запроса — тот же
  // приём, которым уже живёт холст, только для данных.
  //
  // Второе: движение схлопывается. Пока карту тянут, запрос не уходит.
  //
  // Третье: устаревший ответ отбрасывается по номеру поколения, а его запрос
  // отменяется. Данные на экране обязаны соответствовать рамке на экране.

  // Запас в долях экрана. 0.6 — компромисс замера: меньше не спасает от
  // движения туда-сюда, больше заставляет сервер отдавать вчетверо больше
  // объектов на каждый запрос.
  const MARGIN = 0.6;
  // Столько ждём тишины после движения. 180 мс — примерно инерция руки: не
  // ощущается задержкой и схлопывает всю панораму в один запрос.
  const SETTLE_MS = 180;

  let loadedBox = null;    // [юг, запад, север, восток] — что уже загружено
  let loadedZoom = -1;
  let generation = 0;      // номер поколения: поздний чужой ответ отбрасываем
  let flight = null;       // отмена запросов прошлого поколения
  let settleTimer = null;

  function wide(b) {
    const south = b[0][0], west = b[0][1], north = b[1][0], east = b[1][1];
    const dy = (north - south) * MARGIN, dx = (east - west) * MARGIN;
    return [south - dy, west - dx, north + dy, east + dx];
  }

  function inside(box, b) {
    return box && b[0][0] >= box[0] && b[0][1] >= box[1]
        && b[1][0] <= box[2] && b[1][1] <= box[3];
  }

  /// Нужен ли новый запрос. Смена зума требует его всегда: на другом масштабе
  /// сервер отдаёт другую подробность, и старые данные там не годятся.
  function needsLoad() {
    return !loadedBox || map.getZoom() !== loadedZoom
        || !inside(loadedBox, map.getBounds());
  }

  function onMapMoved() {
    if (settleTimer) { clearTimeout(settleTimer); }
    settleTimer = setTimeout(function () {
      settleTimer = null;
      if (!needsLoad()) {
        // Данных хватает — но за холстом всё равно надо следить.
        //
        // Убрать отсюда всё было ошибкой, и она видна сразу: холст
        // пересобирают actiontick и actionend, а они срабатывают только на
        // ДЕЙСТВИЯ мышью. Карта двигается и иначе — из адреса, из поиска, из
        // очереди, — и после такого перехода схема оставалась нарисованной в
        // прежнем масштабе: посреди чёрного экрана лоскут старой картинки.
        //
        // Проверка дешёвая: сравнение зума и четырёх чисел. Перерисовка идёт,
        // только если холст действительно устарел.
        placeCanvas();
        if (canvasIsStale()) { paintSchema(); }
        return;
      }
      drawRoads();
      reloadEdits();
    }, SETTLE_MS);
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

  // Полоска с двумя выходами: уточнить и отменить.
  //
  // Живёт ДО СЛЕДУЮЩЕГО ДЕЙСТВИЯ, а не десять секунд. Десяти секунд хватает,
  // чтобы отменить промах, но не хватает, чтобы решить «а полос-то там
  // четыре»: пока вспомнишь, полоска уже ушла, и уточнять станет нечего.
  function offerRefine(text, refine, undo) {
    undoStack = undo;
    els.toast.innerHTML = '';
    const label = document.createElement('span');
    label.textContent = text;
    els.toast.appendChild(label);
    const more = document.createElement('button');
    more.textContent = 'Уточнить';
    more.addEventListener('click', function () { hideToast(); refine(); });
    els.toast.appendChild(more);
    const back = document.createElement('button');
    back.textContent = 'Отменить';
    back.className = 'ghost';
    back.addEventListener('click', undo);
    els.toast.appendChild(back);
    els.toast.classList.add('on');
    clearTimeout(toastTimer);
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
    keysShown = false;
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

    const noteInput = field('Почему', 'text', current.note || '');
    const lanesInput = field('Полос всего', 'number', lanes);
    // Enter в поле полос СОХРАНЯЕТ.
    //
    // Правка полос стоила четырёх действий: инструмент, щелчок по дороге,
    // ввод числа, нажатие «Сохранить». Четвёртое ничего не решает — число уже
    // введено, и других полей у этой правки нет. Модератор, размечающий
    // полосы час подряд, платил этим щелчком за каждую дорогу.
    lanesInput.input.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter') { return; }
      e.preventDefault();
      commit(parseInt(lanesInput.input.value, 10), noteInput.input.value, turnsNow());
    });
    els.card.appendChild(lanesInput.label);

    // Направления полос — по одной на полосу, слева направо по ходу, как
    // turn:lanes в OSM. Сборка ставит по ним ряд стрелок перед стоп-линией
    // подхода. Раньше карточка спрашивала только число полос, и нарисованные
    // направления до карты не доезжали (06.10.2026).
    let turnPickers = [];
    const turnRow = node('div', '', 'turnrow');
    function drawTurns() {
      const count = Math.max(0, Math.min(8, parseInt(lanesInput.input.value, 10) || 0));
      const before = turnPickers.map(function (p) { return p.value; });
      const saved = ((current.props && current.props.turns) || '').split('|');
      turnRow.innerHTML = '';
      turnPickers = [];
      for (let i = 0; i < count; i += 1) {
        const pick = document.createElement('select');
        TURNS.forEach(function (t) {
          const option = document.createElement('option');
          option.value = t[0];
          option.textContent = t[1];
          pick.appendChild(option);
        });
        pick.value = before[i] || saved[i] || 'through';
        pick.title = 'Полоса ' + (i + 1) + ' слева';
        turnRow.appendChild(pick);
        turnPickers.push(pick);
      }
    }
    function turnsNow() {
      return current.kind === 'turn_lanes'
        ? turnPickers.map(function (p) { return p.value; }).join('|') : null;
    }
    if (current.kind === 'turn_lanes') {
      els.card.appendChild(node('div', 'Направления, слева направо по ходу', 'muted'));
      els.card.appendChild(turnRow);
      lanesInput.input.addEventListener('input', drawTurns);
      drawTurns();
    }
    els.card.appendChild(noteInput.label);

    const save = node('button', current.id ? 'Сохранить' : 'Принять');
    save.addEventListener('click', function () {
      commit(parseInt(lanesInput.input.value, 10), noteInput.input.value, turnsNow());
    });
    els.card.appendChild(save);

    // Полосы — свойство УЛИЦЫ, а не куска.
    //
    // Сборка режет дороги по перекрёсткам, чтобы получился граф, и это верно
    // на своём месте. Но размечать проспект пятнадцатью правками значит
    // платить пятнадцать раз за один ответ: замерено на центре Ташкента —
    // сто самых длинных улиц это 808 правок поштучно и 100 целиком.
    if (!current.id && current.kind === 'lanes' && current.raw) {
      const whole = node('button', 'На всю улицу', 'ghost');
      whole.addEventListener('click', function () {
        const lanes = parseInt(lanesInput.input.value, 10);
        if (!(lanes >= 1 && lanes <= 15)) { hint('Полос от 1 до 15.'); return; }
        whole.disabled = true;
        post('/api/edit/street', { lat: current.raw[1], lon: current.raw[0],
                                   lanes: lanes })
          .then(function (result) {
            whole.disabled = false;
            if (result.error) {
              problem('Улица НЕ размечена: ' + result.error, current.raw, null);
              return;
            }
            closeCard();
            // Говорим и о том, что НЕ получилось: молчаливая половина работы
            // выглядит как сделанная целиком.
            hint('«' + (result.name || 'улица') + '»: размечено кусков '
                 + result.made + ' из ' + result.pieces
                 + (result.failed ? ' · не село ' + result.failed : '')
                 + '. Публикует владелец со своей машины.');
            reloadEdits();
          });
      });
      els.card.appendChild(whole);
    }

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

  function commit(lanes, note, turns) {
    if (!(lanes >= 1 && lanes <= 15)) { hint('Полос от 1 до 15.'); return; }
    const before = current.id ? known[current.id] : null;
    const props = { lanes: lanes };
    if (turns) { props.turns = turns; }
    const payload = {
      kind: current.kind, geom: current.geom, raw: current.raw,
      anchor: current.anchor, fingerprint: current.fingerprint,
      props: props, note: note || '', status: ACCEPTED,
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
          if (result.error) {
            problem(POINTS[code] + ' НЕ поставлен: ' + result.error,
                    coords, function () { placePoint(coords, code); });
            return;
          }
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
      // Стрелка берёт дорогу целиком, а не сажает на неё объект. Работает и
      // на спутнике, где полотна для щелчка нет вовсе, — иначе взять улицу в
      // правку можно было бы только на своей схеме.
      if (kind === 'select' && !existing) {
        if (snap.ambiguous) { offerChoice(coords, list, snap, existing, signature(list)); return; }
        askReshape(list[0]);
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
    // Выбор из двух улиц стрелкой заканчивается тем же: улицу берут в правку.
    if (kind === 'select' && !existing) { askReshape(candidate); return; }
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

  /// Потолок обязан о себе сообщать.
  ///
  /// Молчащий потолок читается как «здесь нет дорог» — худшая из подписей под
  /// пустым экраном. Их было два, и оба молчали: шесть файлов на набор и две
  /// тысячи дорог в ответе. Модератор видел лоскут посреди черноты и не мог
  /// узнать, это конец данных или начало обрезки.
  let limitSaid = '';

  function sayLimits(limits) {
    if (!limits) { return; }
    const bits = [];
    if (limits.skipped) { bits.push('файлов пропущено ' + limits.skipped); }
    if (limits.thinned) {
      bits.push('мелких дорог скрыто ' + limits.thinned
                + ' (масштаб: до класса ' + limits.worstClass + ')');
    }
    if (limits.cut) { bits.push('список обрезан по числу объектов'); }

    if (!bits.length) {
      // Предупреждение ГАСНЕТ, когда скрывать стало нечего.
      //
      // Иначе оно остаётся на экране после приближения и врёт ровно наоборот:
      // говорит «показано не всё» там, где показано всё. Замечено на себе —
      // на зуме 16 сервер отвечал «скрыто 0», а надпись висела от прошлого,
      // городского кадра.
      //
      // Гасим ТОЛЬКО свою надпись: между делом там могло появиться «правка
      // сохранена», и стирать чужое сообщение мы не вправе.
      if (limitSaid && els.hint.textContent === limitSaid) { hint(''); }
      limitSaid = '';
      return;
    }
    limitSaid = 'Показано не всё: ' + bits.join(' · ') + '. Приблизьтесь.';
    hint(limitSaid);
  }

  function drawRoads() {
    // Новое поколение: всё, что прилетит от прошлого, отбрасываем.
    if (flight) { flight.abort(); }
    flight = window.AbortController ? new AbortController() : null;
    const signal = flight ? flight.signal : undefined;
    const mine = ++generation;
    loadedBox = wide(map.getBounds());
    loadedZoom = map.getZoom();
    // Охват экрана — отдельным числом: рамку мы просим с запасом, а
    // подробность обязана считаться по тому, что видит человек.
    // Подробность решает МАСШТАБ, а не охват.
    //
    // Полосы считались по размеру рамки в градусах, и на большом мониторе тот
    // же зум давал вдвое больший охват — панель прятала дворовые проезды на
    // семнадцатом зуме, где по ним и работают. Метров на пиксель от размера
    // окна не зависит.
    // Имя НЕ «wide»: так зовут функцию, которая раздувает рамку, и она
    // вызывается двумя строками выше. Своя переменная её перекрывала, и
    // drawRoads падал на первой же строке — карта оставалась чёрной.
    const seen = map.getBounds();
    const spanSeen = Math.max(seen[1][0] - seen[0][0], seen[1][1] - seen[0][1]);
    const box = boxQuery(loadedBox)
              + '&span=' + spanSeen
              + '&mpp=' + metersPerPixel().toFixed(3);

    function fresh(body) {
      // Ответ чужого поколения — не данные, а эхо прошлой рамки.
      return mine === generation && body && !body.aborted;
    }

    get('/api/roads' + box, signal).then(function (data) {
      if (!fresh(data)) { return; }
      sayLimits(data.limits);
      skeletonFrame = !!(data.limits && data.limits.skeleton);
      roadsInFrame = data.roads || [];
      renderRoads();
      renderCoverage();
    });
    // Названия населённых пунктов. Нужны ровно там, где улиц уже не
    // подписывают: на охвате района и области. Своей ручкой, потому что мест
    // мало, а ответ на «где я» они дают быстрее любой геометрии.
    get('/api/places' + box, signal).then(function (data) {
      if (!fresh(data)) { return; }
      placesInFrame = data.places || [];
      repaintSoon();
    });
    // Обстановка — вторая половина картинки. Без неё схема врёт: дорога есть,
    // а перекрёсток на ней ничем не отличается от прямого участка.
    get('/api/areas' + box, signal).then(function (data) {
      if (!fresh(data)) { return; }
      const all = data.areas || [];
      const isSurface = function (a) {
        return a.kind === SURFACE_ROAD || a.kind === SURFACE_JUNCTION
            || a.kind === SURFACE_MEDIAN;
      };
      landInFrame = all.filter(function (a) { return !isSurface(a); });
      surfaceInFrame = all.filter(isSurface);
      renderLand();
    });
    if (candidatesOn) {
      get('/api/candidates' + box, signal).then(function (data) {
        if (!fresh(data)) { return; }
        candidatesInFrame = data.houses || [];
        renderLand();
        hint(candidatesInFrame.length
             ? 'Кандидатов в кадре: ' + candidatesInFrame.length
               + '. Щёлкните по контуру, чтобы принять.'
             : 'Кандидатов здесь нет — либо всё уже обведено.');
      }, function () { hint('Кандидаты недоступны.'); });
    } else {
      candidatesInFrame = [];
    }
    get('/api/points' + box, signal).then(function (data) {
      if (!fresh(data)) { return; }
      pointsInFrame = data.points || [];
      renderMarks();
      renderCoverage();
    });
  }

  // Как обстановка выглядит на подложке. Не пиктограммы приложения — их здесь
  // и не нужно: на карте важно ГДЕ объект и какого он вида, а не как он
  // нарисован на приборке.
  // Как выглядит обстановка. `paint` — не значок, а КРАСКА на асфальте: то же
  // деление, что на телефоне (SketchPoint.Kind.isPaint).
  //
  // Разница не косметическая, и она видна только на настоящих данных: в одном
  // кадре центра 939 переходов и 254 светофора, и одинаковыми кругами они
  // закрывают дороги целиком — то есть ровно то, ради чего на схему смотрят.
  // Краска лежит поперёк проезжей части тонкой чертой и не спорит за внимание
  // со значком.
  const MARK_LOOK = {
    1: { color: '#ff4d4d', size: 6, name: 'Светофор' },
    2: { color: '#ffb020', size: 5, name: 'Лежачий' },
    3: { color: '#e8e8e8', size: 4, name: 'Стоп-линия', paint: true },
    4: { color: '#9b7bff', size: 5, name: 'Разворот' },
    5: { color: '#ffffff', size: 4, name: 'Переход', paint: true },
    6: { color: '#7bd3ff', size: 4, name: 'Стрелки полос', paint: true },
  };

  // Ближе этого охвата обстановка видна, дальше — нет. На двухстах метрах на
  // экран попадает четверть тысячи объектов, и схема превращается в сыпь.
  const MARKS_MAX_METERS_PER_PIXEL = 1.2;

  // Значки — ТЕ ЖЕ, что на телефоне (SketchGlyphs.swift) и в палитре слева.
  //
  // Один объект не должен выглядеть в двух местах по-разному: модератор,
  // поставивший «красный кружок», не знает, что увидит водитель, — а он
  // увидит корпус с тремя линзами. Кружок вместо значка — это панель,
  // врущая о результате собственной работы.
  //
  // Форма важнее цвета: на солнце через лобовое стекло цвет умирает первым,
  // и объект опознаётся силуэтом. Поэтому светофор вертикальный, лежачий —
  // горб, разворот — стрелка.
  const GLYPHS = {
    1: '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="26" '
       + 'viewBox="0 0 18 26"><rect x="3" y="1" width="12" height="24" rx="3" '
       + 'fill="#12151b" stroke="#3a4250" stroke-width="1.2"/>'
       + '<circle cx="9" cy="7" r="2.6" fill="#ff4d4f"/>'
       + '<circle cx="9" cy="13" r="2.6" fill="#ffb020"/>'
       + '<circle cx="9" cy="19" r="2.6" fill="#38e58c"/></svg>',
    2: '<svg xmlns="http://www.w3.org/2000/svg" width="22" height="14" '
       + 'viewBox="0 0 22 14"><path d="M2 12a9 6 0 0 1 18 0z" fill="#ffb020" '
       + 'stroke="#0d1116" stroke-width="1.2"/>'
       + '<path d="M2 12h18" stroke="#0d1116" stroke-width="1.4"/></svg>',
    4: '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" '
       + 'viewBox="0 0 20 20"><path d="M6 18V9a4 4 0 0 1 8 0v6" fill="none" '
       + 'stroke="#9b7bff" stroke-width="2.2" stroke-linecap="round"/>'
       + '<path d="M10.5 14l3.5 5 3.5-5z" fill="#9b7bff"/></svg>',
  };

  function glyphIcon(kind) {
    const body = GLYPHS[kind];
    if (!body) { return null; }
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(body);
  }

  // Сколько в кадре нашего.
  //
  // Вести свою карту вслепую нельзя: на третьем сеансе никто не помнит, какие
  // перекрёстки уже размечены, и работа начинает ходить по кругу. Считаем по
  // тому, что и так загружено, — отдельной ручки для этого не нужно.
  function renderCoverage() {
    const total = roadsInFrame.length;
    const drawn = roadsInFrame.filter(function (r) { return r.drawn; }).length;
    const measured = roadsInFrame.filter(function (r) { return r.measured; }).length;
    const mine = pointsInFrame.filter(function (p) { return p.mine; }).length;
    if (!total) { els.cover.textContent = 'В этой рамке дорог нет.'; return; }
    const share = Math.round(measured / total * 100);
    els.cover.innerHTML = '';
    els.cover.appendChild(node('div',
      'Размечено ' + share + '% · дорог ' + total +
      ' · нарисовано нами ' + drawn +
      ' · обстановки нашей ' + mine +
      ' · размеченных областей ' + areasInFrame.length, 'muted'));
    const only = node('button', onlyMine ? 'Показать всё' : 'Только наше', 'ghost');
    only.style.width = '100%';
    only.addEventListener('click', function () {
      onlyMine = !onlyMine;
      renderRoads();
      renderCoverage();
    });
    els.cover.appendChild(only);
  }

  // Краска на асфальте: поперёк дороги и во всю её ширину.
  //
  // Данных для этого хватало с самой первой сборки точек: азимут лежит в
  // младших битах записи, ширина проезжей части — в следующих шести. Панель
  // рисовала вместо этого кружок «здесь переход» — то есть значок вместо
  // того, что на асфальте действительно нарисовано.
  //
  // Зебра шире на проспекте, чем во дворе, потому что там шире дорога. Это и
  // есть разница между «отметкой на карте» и схемой: у чужих навигаторов
  // зебра одинаковая везде, у нас — измеренная.
  function renderMarks() {
    // Обстановка живёт НА ХОЛСТЕ целиком: и значки, и краска в метрах.
    //
    // Замерено на живой панораме: renderMarks занимал 112,9 мс — больше, чем
    // весь холст со всеми слоями. Причина та же, что когда-то была у дорог:
    // по геообъекту на объект, а каждая зебра это ещё и ПЯТЬ полос. В кадре
    // района зебр под тысячу — до пяти тысяч объектов на пересборку.
    //
    // Объектом обстановке быть незачем: она не интерактивна, у всех её видов
    // стоял interactivityModel 'transparent'. Свои объекты правятся через
    // метки правок, а опубликованный светофор молча съедал бы щелчок по
    // перекрёстку — там, где их и ставят.
    markLayer.forEach(function (item) { map.geoObjects.remove(item); });
    markLayer = [];
    if (!schema) { return; }
    paintSchema();
  }

  // Метров в пикселе на текущем зуме. Ширина проезжей части приходит с сервера
  // В МЕТРАХ — иначе панель рисовала бы одно, а телефон другое, — и перевести
  // её в пиксели можно только здесь.
  function metersPerPixel() {
    const lat = map.getCenter()[0] * Math.PI / 180;
    return 156543.03392 * Math.cos(lat) / Math.pow(2, map.getZoom());
  }

  // Палитра ЗАВИСИТ ОТ МАСШТАБА, и это не украшение.
  //
  // Замерено по формуле относительной яркости, фон карты #0e1013: квартал
  // #12151b даёт контраст 1,04 — то есть невидим. Отсюда и «город еле виден»
  // на охвате области: застройка, которая должна давать городу массу, не
  // отличается от пустой земли ни на глаз, ни по числу.
  //
  // Поднять её на всех масштабах нельзя: на близком плане дорога идёт ПО
  // кварталу, и при контрасте квартала 1,51 дворовый проезд к нему — 1,15,
  // то есть исчезает внутри застройки. Замерено, а не предположено.
  //
  // Поэтому две палитры и переход между ними. Вблизи, где дорога широкая, —
  // тёмная застройка и спокойный асфальт. Вдали, где дорога вырождается в
  // полуторапиксельную нить, — застройка светлее и асфальт ярче, чтобы сеть
  // осталась поверх неё:
  //
  //          вблизи        вдали     к фону   дорога к кварталу
  //   квартал #12151b  →  #2c3342   1,04→1,51
  //   улица   #525252  →  #6c6c6c            1,62→2,41
  //   проезд  #3c3c3c  →  #595959            1,15→1,81
  const FAR_FROM = 4, FAR_TO = 16;   // метров на пиксель
  let farNow = 0;

  function farShare(perPixel) {
    if (perPixel <= FAR_FROM) { return 0; }
    if (perPixel >= FAR_TO) { return 1; }
    return (perPixel - FAR_FROM) / (FAR_TO - FAR_FROM);
  }

  function blend(near, far, share) {
    if (share <= 0) { return near; }
    if (share >= 1) { return far; }
    let out = '#';
    for (let i = 1; i < 7; i += 2) {
      const a = parseInt(near.substr(i, 2), 16);
      const b = parseInt(far.substr(i, 2), 16);
      out += ('0' + Math.round(a + (b - a) * share).toString(16)).slice(-2);
    }
    return out;
  }

  // Две шкуры: ночная и дневная.
  //
  // Днём у окна тёмная схема нечитаема вовсе — на телефоне дневной режим есть
  // с апреля, в панели его не было. Это не перекраска: днём меняются РОЛИ.
  // Ночью асфальт светлее земли, днём — наоборот, и работу по разделению
  // дороги и застройки берёт на себя кайма.
  //
  // Дневные цвета подобраны по контрасту, а не на глаз (земля #f4f6f9):
  //
  //   квартал вблизи 1,12   вдали 1,45      зелень 1,26   вода 1,30
  //   белая дорога к кварталу вдали 1,57    кайма к дороге 1,61
  //   кайма вдали #a3abbd: к кварталу 1,47, к дороге 2,30
  //
  // Кайма тоже двухступенчатая: та, что хороша вблизи, на дальнем плане
  // сливается с кварталом (1,02) и дорога теряет края.
  const SKIN = {
    night: {
      ground: '#0e1013',
      casing: '#04060a', casingFar: '#04060a',
      kerb: '#5c5b57', median: '#12151b',
      lane: '#e0d9b8', laneWide: '#d8d3c4',
      label: '#d7dae0', labelHalo: 'rgba(6, 8, 12, 0.85)',
      asphalt: [
        { upto: 2, near: '#6b6a63', far: '#8a8981' },
        { upto: 3, near: '#5e5d58', far: '#7d7c75' },
        { upto: 4, near: '#525252', far: '#6c6c6c' },
        { upto: 6, near: '#464646', far: '#606060' },
        { upto: 9, near: '#3c3c3c', far: '#595959' },
      ],
      land: {
        1: { fill: '#16324a', far: '#1d4262', line: '#295176', width: 5, metres: 9 },
        2: { fill: '#152a1b', far: '#23462d', line: '#1f4227', width: 2 },
        3: { fill: '#2a2723', far: '#3f3b35', line: '#4a463e', width: 2, metres: 5 },
        4: { fill: '#12151b', far: '#2c3342', line: '#191d25', width: 1 },
        5: { fill: '#1b1f26', line: '#2b313b', width: 1.4, dash: [1.4, 3.2] },
        6: { fill: '#1f232c', far: '#353b4b', line: '#2b303a', width: 1 },
      },
    },
    day: {
      ground: '#f4f6f9',
      casing: '#c7ccd7', casingFar: '#a3abbd',
      kerb: '#b7bcc6', median: '#dfe3ea',
      lane: '#b7bcc6', laneWide: '#a8aeb9',
      label: '#1d2129', labelHalo: 'rgba(255, 255, 255, 0.9)',
      asphalt: [
        { upto: 2, near: '#ffffff', far: '#ffffff' },
        { upto: 3, near: '#fcfcfd', far: '#fcfcfd' },
        { upto: 4, near: '#f6f7f9', far: '#f6f7f9' },
        { upto: 6, near: '#eff1f4', far: '#eff1f4' },
        { upto: 9, near: '#e9ebef', far: '#e9ebef' },
      ],
      land: {
        1: { fill: '#c5dcf0', far: '#a9cbe8', line: '#8fb8dc', width: 5, metres: 9 },
        2: { fill: '#d0e3c1', far: '#bcd7a8', line: '#a3c88c', width: 2 },
        3: { fill: '#ded8cd', far: '#cbc3b3', line: '#b0a794', width: 2, metres: 5 },
        4: { fill: '#d2d9e7', far: '#b6c2d6', line: '#c0c9db', width: 1 },
        5: { fill: '#e4e8ef', line: '#cfd6e0', width: 1.4, dash: [1.4, 3.2] },
        6: { fill: '#c2cbdb', far: '#aeb9cd', line: '#aab5c9', width: 1 },
      },
    },
  };

  const DAY_KEY = 'rm.editor.day';
  let skin = SKIN.night;
  try {
    if (window.localStorage.getItem(DAY_KEY) === '1') { skin = SKIN.day; }
  } catch (error) { skin = SKIN.night; }

  function daylight() { return skin === SKIN.day; }

  function setDaylight(on) {
    skin = on ? SKIN.day : SKIN.night;
    try { window.localStorage.setItem(DAY_KEY, on ? '1' : '0'); } catch (error) { }
    if (painted) { painted = null; }
    paintSchema();
  }

  // Цвет асфальта по классу — те же тона, что на схеме телефона.
  function asphalt(cls) {
    const table = skin.asphalt;
    for (let i = 0; i < table.length; i++) {
      if (cls <= table[i].upto) {
        return blend(table[i].near, table[i].far, farNow);
      }
    }
    return blend(table[table.length - 1].near, table[table.length - 1].far, farNow);
  }

  /// Кайма дороги: вблизи одна, вдали другая. Та, что хороша вблизи, на
  /// дальнем плане сливается с кварталом, и дорога теряет края.
  function casing() {
    return blend(skin.casing, skin.casingFar, farNow);
  }

  function line(points, options) {
    const shape = new ymaps.Polyline(
      points.map(function (p) { return [p[1], p[0]]; }), {}, options);
    map.geoObjects.add(shape);
    netLines.push(shape);
    return shape;
  }

  // Местность под дорогами: вода, зелень, рельсы, кварталы, тротуары, дома.
  //
  // Без неё панель показывает не схему, а чертёж — серые линии на чёрном.
  // Именно так она и выглядела: наборы собираются давно, а читались только
  // дороги, и на вопрос «почему тут ничего нет» ответить было нечем.
  // `metres` — настоящая ширина объекта. Незамкнутая вода и рельсы рисовались
  // ПОСТОЯННОЙ толщиной в пять и два пункта на любом масштабе, и на охвате
  // области арык шириной восемь метров выходил на карте шириной в сто сорок:
  // город тонул в синей сетке каналов, а сам был еле виден. Толщина в метрах
  // с полом в один пункт эту ложь убирает и на близком плане ничего не меняет.

  const LAND_ORDER = [4, 6, 2, 1, 3, 5];

  // --- Холст схемы -------------------------------------------------------
  //
  // Сеть и местность рисуются в ОДИН canvas, а не геообъектами ymaps.
  //
  // Замерено, и это не вкусовщина. Прежний способ создавал и уничтожал 5 916
  // объектов на КАЖДОЕ движение карты: 4 000 каймы и полотна, 1 904
  // разделительных. Худший кадр при панораме — 583 мс, шестнадцать кадров из
  // сорока медленнее 16,7 мс. Это не «подтормаживает», это остановка картинки.
  //
  // Тот же кадр в canvas 2D: 7,4 мс медиана, 17,6 мс худший — на холсте
  // 2400×1400, то есть уже с запасом шире экрана. В семьдесят девять раз
  // лучше по худшему кадру, и это при ПОЛНОЙ перерисовке.
  //
  // WebGL сюда не нужен, и это тоже арифметика: он превратил бы 7,4 мс в
  // примерно одну, разницу за пределами частоты экрана, — а стоил бы
  // триангуляции, тесселяции линий, пунктира в шейдере и своего конвейера.
  // У Яндекса WebGL потому, что они рисуют весь город с подписями и
  // коллизиями; у нас в кадре тысячи линий, а не миллионы.
  //
  // Объектами ymaps остаётся только то, с чем ВЗАИМОДЕЙСТВУЮТ: метки правок,
  // вершины рисуемой линии, ручки. Их десятки.

  let canvas = null;
  let brush = null;
  /// Пиксельная опора холста: глобальные пиксели левого верхнего угла и зум,
  /// на которых он нарисован. По ним же считается сдвиг при панораме.
  let painted = null;

  function ensureCanvas() {
    if (canvas) { return; }
    canvas = document.createElement('canvas');
    canvas.style.position = 'absolute';
    canvas.style.left = '0';
    canvas.style.top = '0';
    // Сквозной для мыши: щёлкают по карте, а холст — картинка над ней.
    canvas.style.pointerEvents = 'none';
    // Место холста — ВНУТРИ стопки панелей ymaps, сразу над подложечной.
    //
    // Снаружи стопки он не работает ни с какой стороны: приклеенный последним
    // накрывает собой метки, вершины и обстановку — работать с картой нечем;
    // приклеенный первым сам уходит под непрозрачный фон карты, и схема
    // пропадает целиком. Оба варианта были проверены.
    //
    // Внутри стопки порядок правильный сам собой: плитки под ним, всё
    // интерактивное — над.
    const host = document.getElementById('map');
    const ground = host.querySelector('ymaps[class$="ground-pane"]');
    if (ground && ground.parentNode) {
      ground.parentNode.insertBefore(canvas, ground.nextSibling);
    } else {
      host.appendChild(canvas);
    }
    brush = canvas.getContext('2d');
  }

  /// Перевести координату в пиксели холста.
  function atPixel(lon, lat) {
    const global = map.options.get('projection')
      .toGlobalPixels([lat, lon], painted.zoom);
    return [global[0] - painted.left, global[1] - painted.top];
  }

  function paintSchema() {
    ensureCanvas();
    const size = map.container.getSize();
    const zoom = map.getZoom();
    const centre = map.getGlobalPixelCenter();
    // Холст ШИРЕ экрана: панорама в пределах запаса не стоит перерисовки —
    // готовая картинка просто сдвигается. Тот же приём, что у растра схемы на
    // телефоне, и он там уже проверен.
    // Запас вокруг экрана. Полтора экрана вместо четверти — это про ЗУМ.
    //
    // При отдалении готовая картинка масштабируется, а не рисуется заново, и
    // с запасом в четверть она перестаёт покрывать экран уже на одном шаге
    // зума: вокруг остаётся чернота до конца движения. Полтора экрана
    // покрывают два шага отдаления.
    //
    // Платим пикселями, и эти пиксели у нас есть: плотность холста ограничена
    // полутора вместо двух, то есть на 44 % меньше точек на ту же площадь.
    // Запас вокруг экрана — по ПЛОЩАДИ, а не кратностью.
    //
    // Кратность выглядела безобидной и на большом мониторе дала холст
    // 11280 × 5377: шестьдесят миллионов точек, четверть гигабайта на одну
    // картинку. Браузер такое либо не выделяет вовсе, либо рисует так долго,
    // что карта кажется незагруженной.
    //
    // Двенадцать миллионов точек — это примерно два с половиной экрана
    // ноутбука и полтора большого монитора: запас есть, а памяти нет.
    const BUDGET = 12e6;
    // Плотность тоже входит в бюджет. На большом мониторе один экран при
    // полуторной плотности — уже десять миллионов точек, и никакого запаса не
    // остаётся; там честнее рисовать точка в точку, чем не рисовать вовсе.
    let ratioNow = Math.min(1.5, window.devicePixelRatio || 1);
    while (ratioNow > 1 && size[0] * size[1] * ratioNow * ratioNow > BUDGET) {
      ratioNow -= 0.25;
    }
    const roomy = Math.sqrt(BUDGET / (size[0] * size[1] * ratioNow * ratioNow));
    // Запас может ужаться до десятой доли экрана, но не до нуля: без него
    // панорама упирается в край на первом же движении.
    //
    // На дальнем плане запас ограничен ОТДЕЛЬНО, и не пикселями, а весом
    // ответа. Замерено на боевых тайлах, зум 11: запас в 0,75 экрана даёт
    // рамку в шесть площадей экрана и шесть мегабайт местности за один кадр.
    // Пикселей на такой холст хватает — не хватает провода. А польза от
    // запаса там мала: одно движение мыши на дальнем плане — это десятки
    // километров, за край запаса уходишь всё равно.
    // Порог — три метра на пиксель, а не восемь.
    //
    // Замерено на боевых тайлах: на пятнадцатом зуме (4,8 м/пкс) запас в
    // 0,75 экрана давал 9 МБ на кадр — рамка выходила шире тридцати
    // километров ради экрана в четырнадцать. Прореживание вершин здесь не
    // помогает: у дорог они и так реже метра на пиксель (замерено: 100 %
    // остаются). Помогает только не просить лишнюю землю.
    const far = metersPerPixel() > 3 ? 0.15 : 0.75;
    const margin = Math.max(0.1, Math.min(far, (roomy - 1) / 2));
    const width = Math.round(size[0] * (1 + margin * 2));
    const height = Math.round(size[1] * (1 + margin * 2));
    // Плотность пикселей ограничена ПОЛУТОРА, а не двумя.
    //
    // Замерено: при запасе в четверть экрана и удвоении под retina холст
    // выходил на одиннадцать миллионов пикселей, и один проход по нему стоил
    // около ста миллисекунд — это и был худший кадр, который я по очереди
    // приписывал то пересборке слоёв, то геообъектам обстановки. Полтора
    // против двух — это на 44 % меньше пикселей, а разницы на схеме, где
    // самая тонкая линия толщиной в полтора пункта, не видно.
    const ratio = ratioNow;

    painted = { zoom: zoom,
                left: centre[0] - width / 2,
                top: centre[1] - height / 2,
                width: width, height: height, ratio: ratio };

    if (canvas.width !== width * ratio || canvas.height !== height * ratio) {
      canvas.width = width * ratio;
      canvas.height = height * ratio;
    }
    canvas.style.width = width + 'px';
    canvas.style.height = height + 'px';
    brush.setTransform(ratio, 0, 0, ratio, 0, 0);
    placeCanvas();

    // Пересборка идёт ПО КАДРАМ, а не одним куском.
    //
    // Замерено на живой панораме: медиана кадра 8,3 мс, девять из десяти
    // укладываются в 8,8 — но шесть кадров из пяти тысяч заняли до 126 мс.
    // Все шесть — это пересборка холста: рамка вышла за поля запаса, и
    // картинка рисовалась заново целиком в одном кадре.
    //
    // Работы меньше не станет, а стойка исчезнет: слои рисуются по одному за
    // кадр. Холст при этом уже очищен и залит землёй, поэтому промежуточные
    // кадры выглядят «карта достраивается», а не «карта пропала».
    // Один проход по холсту вместо двух: clearRect и следом fillRect по той
    // же площади — это одиннадцать миллионов пикселей дважды. На спутнике
    // холст обязан быть прозрачным, там чистим; на схеме заливаем землёй, и
    // заливка сама стирает прежнее.
    // Доля дальнего плана — один раз на пересборку. Спрашивать масштаб у
    // карты на каждый объект значит звать getCenter и getZoom по двадцать
    // тысяч раз за кадр.
    farNow = farShare(metersPerPixel());
    if (schema) {
      brush.fillStyle = skin.ground;
      brush.fillRect(0, 0, width, height);
    } else {
      brush.clearRect(0, 0, width, height);
    }
    const passes = schema
      ? [paintLand, paintNet, paintMarks, paintNames, paintCandidates]
      : [paintThinNet, paintCandidates];
    runPasses(passes);
  }

  let painting = 0;

  /// Следующий слой — по кадру ИЛИ по таймеру, что придёт раньше.
  ///
  /// Голого requestAnimationFrame мало: у окна, закрытого другим окном, кадры
  /// не приходят ВООБЩЕ. Поймано на себе — и не догадкой, а следом в консоли:
  /// кадр заказан (id 2, 3, 4), таймер на 300 мс сработал трижды, а сам кадр
  /// не пришёл ни разу. Холст оставался залитым землёй с одной местностью:
  /// ни сети, ни обстановки, ни подписей. Открытая в соседнем окне панель
  /// показывала пустую карту и молчала о причине.
  ///
  /// Гонка честная: кто пришёл первым, тот и отменяет второго.
  function soon(work) {
    let done = false;
    const frame = window.requestAnimationFrame(function () {
      if (done) { return; }
      done = true;
      window.clearTimeout(timer);
      work();
    });
    const timer = window.setTimeout(function () {
      if (done) { return; }
      done = true;
      window.cancelAnimationFrame(frame);
      work();
    }, 40);
  }

  /// Слои по одному за кадр. Новая пересборка отменяет незаконченную: рисовать
  /// вчерашнюю рамку поверх сегодняшней незачем.
  function runPasses(passes) {
    const mine = ++painting;
    let at = 0;
    function step() {
      if (mine !== painting || at >= passes.length) { return; }
      passes[at++]();
      soon(step);
    }
    // Первый слой — сразу, без ожидания кадра: иначе при быстром движении
    // холст остаётся пустым на один кадр дольше нужного.
    step();
  }

  /// Поставить холст на место: сдвиг относительно текущего центра карты.
  /// Только это и происходит при панораме — ни одной перерисовки.
  function placeCanvas() {
    if (!canvas || !painted) { return; }
    const size = map.container.getSize();
    const centre = map.getGlobalPixelCenter();
    const dx = painted.left - (centre[0] - size[0] / 2);
    const dy = painted.top - (centre[1] - size[1] / 2);
    const scale = Math.pow(2, map.getZoom() - painted.zoom);
    canvas.style.transformOrigin = '0 0';
    canvas.style.transform = 'translate(' + dx + 'px,' + dy + 'px) scale(' + scale + ')';
  }

  let repaintTimer = null;

  /// Пересборка на затишье: во время движения она нужна, но не шестьдесят раз
  /// в секунду. Четверть секунды — столько длится пауза между шагами зума.
  function repaintSoon() {
    if (repaintTimer) { return; }
    repaintTimer = setTimeout(function () {
      repaintTimer = null;
      if (canvasIsStale()) { paintSchema(); }
    }, 250);
  }

  /// Пора ли перерисовывать: ушли за поля запаса или сменился зум.
  function canvasIsStale() {
    if (!painted) { return true; }
    if (map.getZoom() !== painted.zoom) { return true; }
    const size = map.container.getSize();
    const centre = map.getGlobalPixelCenter();
    const left = centre[0] - size[0] / 2;
    const top = centre[1] - size[1] / 2;
    return left < painted.left || top < painted.top
        || left + size[0] > painted.left + painted.width
        || top + size[1] > painted.top + painted.height;
  }

  function strokePath(points, colour, width, dashPattern) {
    if (points.length < 2 || width <= 0) { return; }
    brush.beginPath();
    for (let i = 0; i < points.length; i++) {
      const at = atPixel(points[i][0], points[i][1]);
      if (i === 0) { brush.moveTo(at[0], at[1]); } else { brush.lineTo(at[0], at[1]); }
    }
    brush.strokeStyle = colour;
    brush.lineWidth = width;
    brush.lineJoin = 'round';
    brush.lineCap = 'butt';
    brush.setLineDash(dashPattern || []);
    brush.stroke();
    brush.setLineDash([]);
  }

  function paintThinNet() {
    // Поверх спутника — только тонкие оси: подложка занята снимком, а
    // показать надо, к чему прилипнет магнит.
    roadsInFrame.forEach(function (road) {
      if (onlyMine && !road.drawn) { return; }
      brush.globalAlpha = road.drawn ? 0.9 : 0.45;
      strokePath(road.points, road.drawn ? '#ffb020' : '#38bdf8',
                 road.drawn ? 4 : 2);
    });
    brush.globalAlpha = 1;
  }

  function paintLand() {
    const perPixel = metersPerPixel();
    LAND_ORDER.forEach(function (kind) {
      const look = skin.land[kind];
      if (!look) { return; }
      const thick = look.metres
        ? Math.max(1, Math.min(look.width, look.metres / perPixel))
        : look.width;
      landInFrame.forEach(function (area) {
        if (area.kind !== kind || area.points.length < 2) { return; }
        if (area.closed) {
          brush.beginPath();
          area.points.forEach(function (p, i) {
            const at = atPixel(p[0], p[1]);
            if (i === 0) { brush.moveTo(at[0], at[1]); } else { brush.lineTo(at[0], at[1]); }
          });
          brush.closePath();
          brush.fillStyle = look.far ? blend(look.fill, look.far, farNow) : look.fill;
          brush.fill();
          brush.strokeStyle = look.line;
          brush.lineWidth = 1;
          brush.stroke();
        } else {
          // Тротуар — пунктиром: сплошная лента любой толщины читается
          // проезжей частью, и вдоль проспекта выглядела дублёром. Тот же
          // приём, что на телефоне, — панель обязана показывать то же.
          strokePath(area.points, look.line, thick, look.dash);
        }
      });
    });
  }


  // --- Подписи улиц ---------------------------------------------------------
  //
  // До этого в файле не было НИ ОДНОГО вызова fillText: карта была безымянной,
  // и улица называлась только после щелчка, в карточке правки. Модератор водил
  // глазами по сетке и опознавал место по форме перекрёстка.
  //
  // Правила те же, что на телефоне и в панели MapLibre, и они не про красоту:
  //
  //   * подпись идёт ВДОЛЬ улицы и никогда вверх ногами;
  //   * одна подпись на склеенную улицу, а не на кусок: кусков у одной улицы в
  //     кадре бывает пятнадцать, и пятнадцать подписей подряд — это шум;
  //   * подпись не рисуется, если не помещается в видимую часть улицы: обрезок
  //     названия хуже его отсутствия;
  //   * подписи не налезают друг на друга — держим занятые прямоугольники;
  //   * бюджет на кадр, ближние к середине первыми.
  //
  // Раскладку в canvas приходится писать руками: ни коллизий, ни автоматики
  // там нет. Поэтому бюджет и порядок важнее шрифта.
  const NAME_BUDGET = 40;
  const NAME_MIN_METERS = 60;      // короче — подпись длиннее самой улицы
  const NAME_FAR_MPP = 8;          // дальше улицы уже не подписывают

  // Города подписываются РАНЬШЕ улиц и переживают их: на дальнем плане имя
  // улицы не нужно и не помещается, а «Чирчик» отвечает на вопрос «где я»
  // одним словом.
  const PLACE_LOOK = {
    1: { size: 17, weight: 700, up: 12 },
    2: { size: 15, weight: 600, up: 10 },
    3: { size: 13, weight: 600, up: 9 },
    4: { size: 12, weight: 500, up: 8 },
    5: { size: 12, weight: 500, up: 8 },
    6: { size: 11, weight: 500, up: 7 },
  };

  function paintPlaces() {
    if (!placesInFrame.length) { return; }
    brush.save();
    brush.textAlign = 'center';
    brush.textBaseline = 'middle';
    brush.lineJoin = 'round';
    const taken = [];
    placesInFrame.forEach(function (place) {
      const look = PLACE_LOOK[place.rank] || PLACE_LOOK[6];
      const at = atPixel(place.point[0], place.point[1]);
      if (at[0] < 0 || at[1] < 0 || at[0] > painted.width || at[1] > painted.height) {
        return;
      }
      brush.font = look.weight + ' ' + look.size + 'px system-ui, sans-serif';
      const width = brush.measureText(place.name).width;
      const box = { x: at[0] - width / 2, y: at[1] - look.up - look.size / 2,
                    w: width, h: look.size };
      for (let i = 0; i < taken.length; i++) {
        const other = taken[i];
        if (box.x < other.x + other.w && box.x + box.w > other.x
            && box.y < other.y + other.h && box.y + box.h > other.y) {
          return;
        }
      }
      taken.push(box);
      // Точка под именем: без неё подпись висит над пустотой и непонятно, к
      // чему она относится.
      brush.beginPath();
      brush.arc(at[0], at[1], place.rank <= 2 ? 3.5 : 2.5, 0, Math.PI * 2);
      brush.fillStyle = skin.label;
      brush.fill();
      brush.strokeStyle = skin.labelHalo;
      brush.lineWidth = 3.5;
      brush.strokeText(place.name, at[0], at[1] - look.up);
      brush.fillStyle = skin.label;
      brush.fillText(place.name, at[0], at[1] - look.up);
    });
    brush.restore();
  }

  function paintNames() {
    paintPlaces();
    const perPixel = metersPerPixel();
    const named = streetsInFrame.filter(function (street) {
      return street.name && street.points.length >= 2;
    });
    if (perPixel > NAME_FAR_MPP) { return; }
    if (!named.length) { return; }

    const middle = [painted.width / 2, painted.height / 2];
    const ranked = named.map(function (street) {
      const at = atPixel(street.points[0][0], street.points[0][1]);
      return { street: street,
               gap: Math.hypot(at[0] - middle[0], at[1] - middle[1]) };
    }).sort(function (a, b) { return a.gap - b.gap; });

    brush.save();
    brush.textAlign = 'center';
    brush.textBaseline = 'middle';
    brush.lineJoin = 'round';
    const taken = [];
    const already = {};
    let drawn = 0;
    for (let i = 0; i < ranked.length && drawn < NAME_BUDGET; i++) {
      if (placeName(ranked[i].street, perPixel, taken, already)) { drawn++; }
    }
    brush.restore();
  }

  /// Самый длинный ПОЧТИ ПРЯМОЙ ход улицы в пикселях: на нём подпись не гнётся.
  ///
  /// Считать по одному отрезку было мало: на семнадцатом зуме у улицы
  /// пятнадцать вершин, самый длинный отрезок между ними — тридцать пикселей,
  /// а название занимает сто двадцать. Подписей не появлялось вовсе именно на
  /// том масштабе, где по улицам и работают.
  ///
  /// Поэтому копим ПОДРЯД идущие отрезки, пока улица не свернула больше чем на
  /// STRAIGHT_TURN: у прямой улицы, разбитой вершинами, ход собирается целиком.
  const STRAIGHT_TURN = 20 * Math.PI / 180;

  function straightRun(points) {
    let best = null, bestLength = 0;
    let start = atPixel(points[0][0], points[0][1]);
    let last = start, runLength = 0, runAngle = null;
    for (let i = 1; i < points.length; i++) {
      const next = atPixel(points[i][0], points[i][1]);
      const step = Math.hypot(next[0] - last[0], next[1] - last[1]);
      if (step < 0.5) { continue; }
      const angle = Math.atan2(next[1] - last[1], next[0] - last[0]);
      let turn = runAngle === null ? 0 : Math.abs(angle - runAngle);
      if (turn > Math.PI) { turn = 2 * Math.PI - turn; }
      if (runAngle !== null && turn > STRAIGHT_TURN) {
        start = last;
        runLength = 0;
      }
      runAngle = angle;
      runLength += step;
      last = next;
      if (runLength > bestLength) {
        bestLength = runLength;
        best = [start, next];
      }
    }
    return best ? { from: best[0], to: best[1], length: bestLength } : null;
  }

  // Одно имя на кадр — если только оно не далеко.
  //
  // Улица приезжает несколькими склеенными лентами: у проспекта с дублёром
  // разные классы, а склейка идёт по классу. На кадре центра «Mustaqillik
  // shoh ko'chasi» так подписывалась пять раз подряд, и две подписи стояли
  // впритык одна над другой. Длинная улица имеет право на повтор — но не
  // ближе, чем через полэкрана.
  const NAME_REPEAT = 600;

  function placeName(street, perPixel, taken, already) {
    const run = straightRun(street.points);
    if (!run || run.length < NAME_MIN_METERS / perPixel) { return false; }

    const size = street.cls <= 3 ? 13 : 11;
    brush.font = '600 ' + size + 'px system-ui, -apple-system, sans-serif';
    const text = street.name;
    const width = brush.measureText(text).width;
    // Не помещается — молчим. Обрезанное название читается как сбой.
    if (width + 12 > run.length) { return false; }

    let from = run.from, to = run.to;
    // Никогда вверх ногами: если участок идёт справа налево, разворачиваем его,
    // а не текст.
    if (to[0] < from[0]) { const swap = from; from = to; to = swap; }
    const angle = Math.atan2(to[1] - from[1], to[0] - from[0]);
    const centre = [(from[0] + to[0]) / 2, (from[1] + to[1]) / 2];

    const box = { x: centre[0] - width / 2, y: centre[1] - size / 2,
                  w: width, h: size };
    const twin = already[text];
    if (twin && Math.hypot(centre[0] - twin[0], centre[1] - twin[1]) < NAME_REPEAT) {
      return false;
    }
    if (box.x < 0 || box.y < 0
        || box.x + box.w > painted.width || box.y + box.h > painted.height) {
      return false;
    }
    for (let i = 0; i < taken.length; i++) {
      const other = taken[i];
      if (box.x < other.x + other.w && box.x + box.w > other.x
          && box.y < other.y + other.h && box.y + box.h > other.y) {
        return false;
      }
    }
    taken.push(box);
    already[text] = centre;

    brush.translate(centre[0], centre[1]);
    brush.rotate(angle);
    // Обводка тёмным: подпись лежит на асфальте, а он светлее фона.
    brush.strokeStyle = skin.labelHalo;
    brush.lineWidth = 3;
    brush.strokeText(text, 0, 0);
    brush.fillStyle = skin.label;
    brush.fillText(text, 0, 0);
    brush.setTransform(painted.ratio, 0, 0, painted.ratio, 0, 0);
    return true;
  }

  // Трапеция подхода: от обычной ширины в восьми метрах от узла к расширенной
  // у самого узла.
  const FLARE_METERS = 8;

  function paintFlare(end, inner, width, flare, colour, perPixel) {
    const scale = Math.cos(end[1] * Math.PI / 180);
    let dx = (end[0] - inner[0]) * scale, dy = end[1] - inner[1];
    const length = Math.hypot(dx, dy);
    if (length === 0) { return; }
    dx /= length; dy /= length;
    // Точка в FLARE_METERS от узла вглубь улицы.
    const back = FLARE_METERS / 111320;
    const from = [end[0] - dx * back / scale, end[1] - dy * back];
    // Нормаль к направлению улицы.
    const nx = -dy, ny = dx;
    const halfNarrow = (width / 2) / 111320;
    const halfWide = (width / 2 + flare) / 111320;

    const corner = function (point, half) {
      return [[point[0] + nx * half / scale, point[1] + ny * half],
              [point[0] - nx * half / scale, point[1] - ny * half]];
    };
    const near = corner(from, halfNarrow);
    const wide = corner(end, halfWide);

    brush.beginPath();
    [near[0], wide[0], wide[1], near[1]].forEach(function (p, i) {
      const at = atPixel(p[0], p[1]);
      if (i === 0) { brush.moveTo(at[0], at[1]); } else { brush.lineTo(at[0], at[1]); }
    });
    brush.closePath();
    brush.fillStyle = colour;
    brush.fill();
  }

  // Выпуклая оболочка точек (обход Эндрю). Нужна перекрёстку: его асфальт —
  // это площадь между кромками всех сходящихся дорог.
  function convexHull(points) {
    if (points.length < 3) { return points; }
    const sorted = points.slice().sort(function (a, b) {
      return a[0] - b[0] || a[1] - b[1];
    });
    const cross = function (o, a, b) {
      return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
    };
    const half = function (list) {
      const out = [];
      list.forEach(function (p) {
        while (out.length >= 2
               && cross(out[out.length - 2], out[out.length - 1], p) <= 0) {
          out.pop();
        }
        out.push(p);
      });
      out.pop();
      return out;
    };
    return half(sorted).concat(half(sorted.slice().reverse()));
  }

  // Кромка полотна — бордюр.
  //
  // Делает для «настоящести» больше, чем любой подбор оттенков: без неё
  // асфальт сливается с землёй и читается плоским пятном, а не поверхностью,
  // у которой есть край. На телефоне бордюр уже есть — панель обязана
  // показывать то же самое.


  function fillRing(points, colour, kerb) {
    if (points.length < 3) { return; }
    brush.beginPath();
    points.forEach(function (p, i) {
      const at = atPixel(p[0], p[1]);
      if (i === 0) { brush.moveTo(at[0], at[1]); } else { brush.lineTo(at[0], at[1]); }
    });
    brush.closePath();
    brush.fillStyle = colour;
    brush.fill();
    if (!kerb) { return; }
    brush.strokeStyle = kerb;
    brush.lineWidth = 1;
    brush.lineJoin = 'round';
    brush.stroke();
  }

  // Картинки значков грузятся один раз и живут в кэше: создавать Image на
  // каждый светофор в каждом кадре значило бы вернуть ту же беду, только в
  // другом месте.
  const glyphImages = {};

  function glyphImage(kind) {
    if (glyphImages[kind] !== undefined) { return glyphImages[kind]; }
    const src = glyphIcon(kind);
    if (!src) { glyphImages[kind] = null; return null; }
    const image = new Image();
    // Пока картинка грузится, рисовать нечего; когда загрузится — просим
    // перерисовку, иначе значки появятся только на следующем движении.
    image.addEventListener('load', function () { paintSchema(); });
    image.src = src;
    glyphImages[kind] = image;
    return image;
  }

  /// Краска поперёк дороги — НА ХОЛСТЕ.
  ///
  /// Каждая зебра — пять полос, и раньше каждая полоса была отдельным
  /// геообъектом ymaps. Зебр в кадре района под тысячу, то есть под пять
  /// тысяч объектов на пересборку — ровно та беда, которую мы победили для
  /// дорог и не заметили у обстановки. Замерено: 100,9 мс на кадр.
  function paintAcrossCanvas(mark, look) {
    const lat = mark.point[1], lon = mark.point[0];
    const half = mark.width / 2;
    const across = (mark.azimuth + 90) * Math.PI / 180;
    const dLat = Math.cos(across) * half / 111320;
    const dLon = Math.sin(across) * half / (111320 * Math.cos(lat * Math.PI / 180));
    const perPixel = metersPerPixel();
    const inPoints = function (metres) { return Math.max(1.5, metres / perPixel); };
    const colour = mark.mine ? '#ffb020' : look.color;

    function bar(shift, width, opacity) {
      const along = mark.azimuth * Math.PI / 180;
      const oLat = Math.cos(along) * shift / 111320;
      const oLon = Math.sin(along) * shift / (111320 * Math.cos(lat * Math.PI / 180));
      brush.globalAlpha = opacity;
      strokePath([[lon - dLon + oLon, lat - dLat + oLat],
                  [lon + dLon + oLon, lat + dLat + oLat]], colour, width);
      brush.globalAlpha = 1;
    }

    if (mark.kind === 5) {
      // Длина зебры вдоль дороги постоянная — около четырёх метров, как в
      // жизни: считанная от ширины, она превращала переход в площадь.
      for (let i = 0; i < 5; i++) { bar((i - 2) * 0.8, inPoints(0.4), 0.9); }
      return;
    }
    if (mark.kind === 3) {
      // Стоп-линия — сплошная полоса в сорок сантиметров поперёк подхода.
      bar(0, inPoints(0.4), 0.95);
      return;
    }
    bar(0, inPoints(0.25), 0.8);
  }

  function paintMarks() {
    if (!schema) { return; }
    const close = metersPerPixel() <= MARKS_MAX_METERS_PER_PIXEL;
    pointsInFrame.forEach(function (mark) {
      const look = MARK_LOOK[mark.kind];
      if (!look) { return; }
      if (!close && !mark.mine) { return; }
      if (look.paint) {
        if (mark.width) { paintAcrossCanvas(mark, look); }
        return;
      }
      const image = glyphImage(mark.kind);
      const at = atPixel(mark.point[0], mark.point[1]);
      if (image && image.complete && image.naturalWidth) {
        // Значок стоит ПРЯМО и не растёт с зумом — как на телефоне.
        brush.drawImage(image, at[0] - 9, at[1] - 26, 18, 26);
      } else {
        brush.beginPath();
        brush.arc(at[0], at[1], look.size, 0, Math.PI * 2);
        brush.fillStyle = look.color;
        brush.fill();
      }
      if (mark.mine) {
        // Своё обведено: видно, что уже уехало на телефоны, а что ещё ждёт
        // публикации.
        brush.beginPath();
        brush.arc(at[0], at[1] - 13, look.size + 6, 0, Math.PI * 2);
        brush.strokeStyle = '#ffb020';
        brush.lineWidth = 2;
        brush.stroke();
      }
    });
  }

  function paintCandidates() {
    if (!candidatesOn) { return; }
    // Пунктиром и янтарём: кандидат обязан отличаться от нарисованного нами с
    // первого взгляда. Сплошной серый контур читался бы домом, и модератор
    // принимал бы за данные то, что ещё никто не смотрел.
    candidatesInFrame.forEach(function (house) {
      const ring = house.points.concat([house.points[0]]);
      strokePath(ring, '#ffb020', 1.2, [3, 3]);
    });
  }

  function insideRing(ring, coords) {
    // Луч вправо: нечётное число пересечений — точка внутри.
    const y = coords[0], x = coords[1];
    let inside = false;
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const xi = ring[i][0], yi = ring[i][1];
      const xj = ring[j][0], yj = ring[j][1];
      if ((yi > y) !== (yj > y)
          && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  function candidateUnder(coords) {
    for (let i = 0; i < candidatesInFrame.length; i++) {
      if (insideRing(candidatesInFrame[i].points, coords)) {
        return candidatesInFrame[i];
      }
    }
    return null;
  }

  function acceptCandidate(house) {
    // Принятый кандидат становится ОБЫЧНОЙ правкой и проходит ту же проверку,
    // что нарисованное мышью: машина предлагает, решает человек.
    const ring = house.points.slice();
    post('/api/edit', {
      kind: 'area', geom: ring, raw: ring[0],
      props: { area: HOUSE_AREA, source: 'ml' }, status: ACCEPTED,
    }).then(function (result) {
      if (result.error) { hint(result.error); return; }
      candidatesInFrame = candidatesInFrame.filter(function (other) {
        return other !== house;
      });
      renderLand();
      offerRefine('Дом принят · адрес?',
        function () { askAddress(result, ring); },
        function () {
          return post('/api/edit/withdraw',
                      { id: result.id, version: result.version });
        });
      reloadEdits();
    });
  }

  function paintSurface() {
    // Поверхность приехала готовой — заливаем и не считаем ничего.
    //
    // Склейка кусков, ширина, оболочка перекрёстка и трапеции фасок — это
    // ГЕОМЕТРИЯ, а не отрисовка: она одинакова для всех, не зависит от зума и
    // не меняется, пока не пересобраны тайлы. Считать её на каждое движение
    // карты неверно в любом движке; теперь она считается в сборке раз в
    // неделю. Здесь остаётся заливка.
    surfaceInFrame.forEach(function (area) {
      if (area.kind !== SURFACE_ROAD) { return; }
      fillRing(area.points, asphalt(area.road || 6), skin.kerb);
    });
    surfaceInFrame.forEach(function (area) {
      if (area.kind !== SURFACE_JUNCTION) { return; }
      fillRing(area.points, asphalt(4));
    });
    // Разделительная — ПОВЕРХ асфальта: она его разрезает. Земля, а не
    // краска: на проспекте потоки разделены газоном или отбойником.
    surfaceInFrame.forEach(function (area) {
      // У островка бордюр есть в жизни; без него полоса читается провалом в
      // асфальте, а не поднятой землёй. У площади перекрёстка бордюра нет —
      // обведи её, и поперёк проезжей части появился бы контур.
      if (area.kind !== SURFACE_MEDIAN) { return; }
      fillRing(area.points, skin.median, skin.kerb);
    });
  }

  function paintNet() {
    const perPixel = metersPerPixel();
    const shown = mergeStreets(onlyMine
      ? roadsInFrame.filter(function (r) { return r.drawn; })
      : roadsInFrame);
    // Чем ближе к экрану дороги, тем позже они рисуются: мост обязан лечь
    // ПОВЕРХ того, что под ним, иначе развязка читается перекрёстком.
    const ordered = shown.slice().sort(function (a, c) { return a.level - c.level; });
    streetsInFrame = ordered;

    // Готовая поверхность заменяет ЧЕТЫРЕ прохода: кайму, полотно, оболочку
    // перекрёстка и фаски. Своя нарисованная дорога в тайлы ещё не попала —
    // её по-прежнему рисуем сами, иначе конструктор перестанет показывать
    // результат до ближайшей пересборки. При «только моё» считаем всё сами:
    // сборка о фильтре не знает.
    const haveSurface = surfaceInFrame.length > 0 && !onlyMine;
    if (haveSurface) {
      paintSurface();
      ordered.forEach(function (road) {
        if (!road.drawn) { return; }
        const width = Math.max(1.5, road.width / perPixel);
        strokePath(road.points, casing(), width + 3);
        strokePath(road.points, asphalt(road.cls), width);
      });
    }

    if (!haveSurface) {
      // Проходами, а не по улице: сперва ВСЕ каймы, потом ВСЕ полотна. Иначе
      // кайма одной улицы ложится поверх полотна соседней, и каждый перекрёсток
      // рассекается швами.
      ordered.forEach(function (road) {
        const width = Math.max(1.5, road.width / perPixel);
        strokePath(road.points, casing(), width + 3);
      });
      ordered.forEach(function (road) {
        const width = Math.max(1.5, road.width / perPixel);
        strokePath(road.points, asphalt(road.cls), width);
      });

      // Заглушки узлов: три конца и больше — перекрёсток. Два — продолжение
      // улицы следующим куском, и круг там делает наплыв, а не закрывает шов.
      const nodes = {};
      shown.forEach(function (road) {
        const points = road.points;
        [[points[0], points[1]],
         [points[points.length - 1], points[points.length - 2]]]
          .forEach(function (pair) {
            const end = pair[0], inner = pair[1];
            if (!end || !inner) { return; }
            const key = end[0].toFixed(5) + ' ' + end[1].toFixed(5);
            const found = nodes[key] || (nodes[key] = {
              point: end, ends: 0, width: road.width,
              color: asphalt(road.cls), edges: [] });
            found.ends += 1;
            if (road.width > found.width) {
              found.width = road.width;
              found.color = asphalt(road.cls);
            }
            // Кромки дороги в узле: центр ± половина ширины поперёк её
            // направления. Из этих точек и складывается площадь перекрёстка.
            const scale = Math.cos(end[1] * Math.PI / 180);
            let dx = (end[0] - inner[0]) * scale, dy = end[1] - inner[1];
            const length = Math.hypot(dx, dy);
            if (length === 0) { return; }
            dx /= length; dy /= length;
            const half = (road.width / 2) / 111320;
            found.edges.push([end[0] - dy * half / scale, end[1] + dx * half]);
            found.edges.push([end[0] + dy * half / scale, end[1] - dx * half]);
          });
      });
      // ПЛОЩАДЬ перекрёстка, а не круг самой широкой дороги.
      //
      // Круг закрывал только то, что укладывалось в его радиус, а перекрёсток —
      // не круг: когда четыре дороги разной ширины сходятся под разными углами,
      // между их кромками остаются чёрные клинья. Замерено на живом кадре: 133
      // настоящих перекрёстка и 42 стыка кусков с разной шириной, наибольший
      // скачок — восемь метров.
      //
      // Проверено и отвергнуто: круглые торцы вместо срезанных клинья не
      // закрывают (31 дырка против 30 — в пределах шума). Дело не в торцах.
      //
      // Правильная фигура — выпуклая оболочка КРОМОК всех сходящихся дорог:
      // каждая приходит в узел своей шириной, и площадь между их краями и есть
      // асфальт перекрёстка. Ровно её и заливаем.
      Object.keys(nodes).forEach(function (key) {
        const node = nodes[key];
        if (node.ends < 3 || !node.edges || node.edges.length < 3) { return; }
        const hull = convexHull(node.edges.map(function (p) {
          return atPixel(p[0], p[1]);
        }));
        if (hull.length < 3) { return; }
        brush.beginPath();
        hull.forEach(function (p, i) {
          if (i === 0) { brush.moveTo(p[0], p[1]); } else { brush.lineTo(p[0], p[1]); }
        });
        brush.closePath();
        brush.fillStyle = node.color;
        brush.fill();
      });

      // Фаска входа в перекрёсток.
      //
      // В жизни улица расширяется перед перекрёстком: полоса поворота,
      // скруглённый бордюр, карман. На схеме без этого улица втыкается в
      // проспект прямоугольным торцом — и перекрёсток читается стыком двух
      // лент, а не местом, куда сворачивают. Это самое заметное, чем наш
      // перекрёсток отличался от чужого.
      //
      // Рисуем трапецией по последним восьми метрам: от обычной ширины к
      // расширенной у самого узла. Расширение — полтора метра на сторону, но
      // не больше четверти ширины: иначе дворовый проезд у проспекта
      // раздувается вдвое и выглядит съездом с развязки.
      ordered.forEach(function (road) {
        const points = road.points;
        if (points.length < 2) { return; }
        [[points[points.length - 1], points[points.length - 2]],
         [points[0], points[1]]].forEach(function (pair) {
          const end = pair[0], inner = pair[1];
          const key = end[0].toFixed(5) + ' ' + end[1].toFixed(5);
          const node = nodes[key];
          if (!node || node.ends < 3) { return; }
          // Фаска не шире самого узла: она подводит улицу к нему, а не
          // выпирает наружу.
          const flare = Math.min(1.5, road.width / 4,
                                 Math.max(0, (node.width - road.width) / 2));
          if (flare <= 0.2) { return; }
          paintFlare(end, inner, road.width, flare, asphalt(road.cls), perPixel);
        });
      });
    }

    // Разметка: ритм три метра штрих, девять промежуток — по нашим правилам.
    // Именно по нему дорога и опознаётся дорогой.
    const stroke = Math.max(2, 3 / perPixel);
    const gap = Math.max(4, 9 / perPixel);
    ordered.forEach(function (road) {
      if (road.oneWay || road.cls > 4) { return; }
      if (road.width / perPixel < 8) { return; }
      brush.globalAlpha = 0.42;
      strokePath(road.points, skin.lane, 1.3, [stroke, gap]);
      brush.globalAlpha = 1;
    });

    // Разделительные — тем же приёмом «полосами», что и на телефоне: широкий
    // штрих цветом разметки, поверх чуть более узкий цветом асфальта.
    // Остаётся ровно кромка, то есть сама разделительная.
    ordered.forEach(function (road) {
      if (!road.measured || road.lanes < 2) { return; }
      const width = road.width / perPixel;
      if (width < 20) { return; }
      const lane = width / road.lanes;
      for (let i = 1; i < road.lanes; i++) {
        if (i === road.lanes / 2) { continue; }
        const band = Math.abs((i - road.lanes / 2) * lane) * 2;
        brush.globalAlpha = 0.34;
        strokePath(road.points, skin.laneWide, band + 1.2, [stroke, gap]);
        brush.globalAlpha = 1;
        strokePath(road.points, asphalt(road.cls), band - 1.2);
      }
    });
  }

  function renderLand() {
    // Местность рисуется на холсте вместе с сетью: разделять их незачем, а
    // порядок слоёв важнее, чем возможность перерисовать одно без другого.
    landShapes.forEach(function (shape) { map.geoObjects.remove(shape); });
    landShapes = [];
    paintSchema();
  }

  function renderLandUnused() {
    if (!schema) { return; }
    // Порядок слоёв тот же, что на телефоне: квартал закрывает пустоту между
    // улицами, дом ложится на него, вода и зелень поверх, тротуар последним.
    LAND_ORDER.forEach(function (kind) {
      landInFrame.forEach(function (area) {
        if (area.kind !== kind) { return; }
        const look = skin.land[kind];
        if (!look) { return; }
        const path = area.points.map(function (p) { return [p[1], p[0]]; });
        const zIndex = 100 + LAND_ORDER.indexOf(kind);
        const shape = area.closed
          ? new ymaps.Polygon([path], {}, {
              fillColor: look.fill, strokeColor: look.line, strokeWidth: 1,
              zIndex: zIndex, interactivityModel: 'default#transparent' })
          : new ymaps.Polyline(path, {}, {
              strokeColor: look.line, strokeWidth: look.width,
              zIndex: zIndex, interactivityModel: 'default#transparent' });
        map.geoObjects.add(shape);
        landShapes.push(shape);
      });
    });
  }

  // Склейка кусков в улицы — ПЕРЕД отрисовкой.
  //
  // Сборка режет дороги по перекрёсткам, чтобы получился граф, и это правильно
  // на своём месте. Но рисовать надо улицу, а не куски: замерено на живом
  // кадре — 413 кусков это ВОСЕМЬ улиц, по пятнадцать кусков на улицу, и у
  // каждой из восьми в одном кадре две-три разные ширины. Отсюда «сосиски»:
  // круглые торцы посреди проезжей части, ступени по ширине и тёмные просветы
  // на стыках.
  //
  // У телефона этой беды нет — там перед отрисовкой работает склейка
  // (RoadGeneralise.merge_ways). Здесь тот же приём.
  const JOIN_EPSILON = 1e-5;   // шаг координат в тайле, ~1,1 м

  function sameSpot(a, b) {
    return Math.abs(a[0] - b[0]) < JOIN_EPSILON
        && Math.abs(a[1] - b[1]) < JOIN_EPSILON;
  }

  function mergeStreets(roads) {
    // Склеиваем только куски ОДНОГО класса и одного имени: совпало имя — мало,
    // «Мустакиллик» есть в каждом районе, поэтому конец одного обязан
    // совпадать с началом другого.
    const groups = {};
    roads.forEach(function (road) {
      const key = road.cls + '|' + (road.name || '') + '|' + (road.oneWay ? 1 : 0)
                  + '|' + road.level;
      (groups[key] = groups[key] || []).push(road);
    });

    const out = [];
    Object.keys(groups).forEach(function (key) {
      const pieces = groups[key].slice();
      while (pieces.length) {
        const first = pieces.shift();
        const chain = { points: first.points.slice(), cls: first.cls,
                        name: first.name, oneWay: first.oneWay,
                        level: first.level, lanes: first.lanes,
                        width: first.width, measured: first.measured,
                        drawn: first.drawn, pieces: [first] };
        let grew = true;
        while (grew) {
          grew = false;
          for (let i = 0; i < pieces.length; i++) {
            const next = pieces[i];
            const head = chain.points[0];
            const tail = chain.points[chain.points.length - 1];
            const from = next.points[0];
            const to = next.points[next.points.length - 1];
            let joined = null;
            if (sameSpot(tail, from)) { joined = next.points.slice(1); }
            else if (sameSpot(tail, to)) { joined = next.points.slice().reverse().slice(1); }
            if (joined) {
              chain.points = chain.points.concat(joined);
            } else {
              let ahead = null;
              if (sameSpot(head, to)) { ahead = next.points.slice(0, -1); }
              else if (sameSpot(head, from)) { ahead = next.points.slice().reverse().slice(0, -1); }
              if (!ahead) { continue; }
              chain.points = ahead.concat(chain.points);
            }
            // Ширина — ОДНА на улицу. Улица в жизни не меняет ширину
            // пятнадцать раз на километр; берём наибольшую измеренную, а если
            // измеренных нет — наибольшую по классу.
            if (next.measured && (!chain.measured || next.width > chain.width)) {
              chain.measured = true;
              chain.width = next.width;
              chain.lanes = next.lanes;
            } else if (!chain.measured && next.width > chain.width) {
              chain.width = next.width;
              chain.lanes = next.lanes;
            }
            chain.drawn = chain.drawn || next.drawn;
            chain.pieces.push(next);
            pieces.splice(i, 1);
            grew = true;
            break;
          }
        }
        out.push(chain);
      }
    });
    return out;
  }

  // Какой кусок улицы под щелчком. Склейка — дело отрисовки; правка остаётся
  // за куском, потому что именно кусок лежит в тайле.
  // Какая улица под щелчком. null — мимо всех.
  //
  // Порог — половина ширины полотна плюс три метра на промах пальцем: щелчок
  // по асфальту обязан попадать в дорогу, а щелчок рядом с ней — в карту.
  function streetUnder(coords) {
    if (skeletonFrame) {
      hint('На этом масштабе показан костяк сети — приблизьтесь, чтобы править.');
      return null;
    }
    const lat = coords[0], lon = coords[1];
    const scale = Math.cos(lat * Math.PI / 180);
    let best = null, bestMeters = Infinity;
    streetsInFrame.forEach(function (street) {
      const points = street.points;
      for (let i = 1; i < points.length; i++) {
        const metres = pointToSegment(lon, lat, points[i - 1], points[i], scale);
        const reach = street.width / 2 + 3;
        if (metres <= reach && metres < bestMeters) {
          bestMeters = metres;
          best = street;
        }
      }
    });
    return best;
  }

  function pointToSegment(lon, lat, from, to, scale) {
    const ax = (lon - from[0]) * scale * 111320;
    const ay = (lat - from[1]) * 111320;
    const bx = (to[0] - from[0]) * scale * 111320;
    const by = (to[1] - from[1]) * 111320;
    const length = bx * bx + by * by;
    const share = length > 0 ? Math.max(0, Math.min(1, (ax * bx + ay * by) / length)) : 0;
    return Math.hypot(ax - bx * share, ay - by * share);
  }

  function nearestPiece(street, coords) {
    const pieces = street.pieces || [street];
    if (pieces.length === 1) { return pieces[0]; }
    const lat = coords[0], lon = coords[1];
    let best = pieces[0], bestDistance = Infinity;
    pieces.forEach(function (piece) {
      piece.points.forEach(function (p) {
        const d = Math.hypot(p[0] - lon, p[1] - lat);
        if (d < bestDistance) { bestDistance = d; best = piece; }
      });
    });
    return best;
  }

  function renderRoads() {
    netLines.forEach(function (shape) { map.geoObjects.remove(shape); });
    netLines = [];
    paintSchema();
  }

  // Взять существующую дорогу в правку.
  //
  // Вершины становятся тянущимися СРАЗУ, по одному щелчку. Это и есть работа
  // конструктора: улицу поправляют, взявшись за неё, а не выбрав пункт в
  // карточке, — а карточка остаётся рядом для того, что мышью не делается:
  // назвать и убрать.
  //
  // Геометрия копируется в рисовалку как есть. При сохранении старая уходит:
  // модератор, поправивший улицу, ждёт, что на схеме останется ОДНА дорога, а
  // не две в нескольких метрах.
  function askReshape(road) {
    const points = road.points.map(function (p) { return [p[0], p[1]]; });
    drawing = { points: points, cls: road.cls, replace: true,
                lanes: road.lanes, oneWay: road.oneWay, joined: {},
                joins: points.map(function (p) { return heldAt(p, road.points); }) };
    chosenVertex = -1;
    renderDrawing();
    const nodes = drawing.joins.filter(function (j) { return j.length; }).length;
    hint('Тяни вершины · середину отрезка — добавить · Enter — сохранить'
         + (nodes ? ' · узлов ' + nodes + ': соседние улицы поедут вместе' : ''));
    els.card.hidden = false;
    els.card.innerHTML = '';
    els.card.appendChild(node('h3', 'Дорога класса ' + road.cls));
    els.card.appendChild(node('div',
      (road.name || 'без имени') + ' · ' + road.lanes + ' полос · ' +
      road.width + ' м', 'muted'));
    // «Убрать» — второй способ распрощаться с чужой линией. Улицу бывает нужно
    // просто убрать: перекрыли, снесли, застроили, — и рисовать ради этого
    // фиктивную дорогу нелепо.
    const why = document.createElement('select');
    REMOVE_WHYS.forEach(function (text) {
      const option = document.createElement('option');
      option.value = text;
      option.textContent = text;
      why.appendChild(option);
    });
    const whyLabel = node('label', 'Если убрать — почему');
    whyLabel.appendChild(why);
    els.card.appendChild(whyLabel);

    // Название. Единственное, что человек знает лучше OSM всегда: он там был.
    const title = field('Название (пусто — не менять)', 'text', road.name || '');
    els.card.appendChild(title.label);
    const rename = node('button', 'Назвать');
    rename.addEventListener('click', function () {
      const text = title.input.value.trim();
      if (!text) { hint('Введите название.'); return; }
      post('/api/edit', {
        kind: 'name', geom: road.points[Math.floor(road.points.length / 2)],
        raw: road.points[0], props: { name: text }, status: ACCEPTED,
      }).then(function (result) {
        if (result.error) { hint(result.error); return; }
        // Дорога была взята в правку одним щелчком; назвали — значит с
        // геометрией ничего не делали, и висящие вершины сбивали бы с толку.
        cancelDrawing(true);
        closeCard();
        hint('Название сохранено: ' + text);
        offerUndo('Название · ' + text, function () {
          return post('/api/edit/withdraw',
                      { id: result.id, version: result.version });
        });
        walking = false;
        reloadEdits();
      });
    });
    els.card.appendChild(rename);

    const drop = node('button', 'Убрать дорогу', 'ghost');
    drop.addEventListener('click', function () {
      post('/api/edit', {
        kind: 'remove', geom: road.points, raw: road.points[0],
        props: { why: why.value, cls: road.cls }, status: ACCEPTED,
      }).then(function (result) {
        if (result.error) { hint(result.error); return; }
        cancelDrawing(true);
        closeCard();
        hint('Дорога убрана. На схеме её не будет после публикации.');
        offerUndo('Убрана дорога класса ' + road.cls, function () {
          return post('/api/edit/withdraw',
                      { id: result.id, version: result.version });
        });
        walking = false;
        reloadEdits();
      });
    });

    const save = node('button', 'Сохранить геометрию');
    save.addEventListener('click', finishDrawing);
    els.card.appendChild(save);
    els.card.appendChild(drop);
    const cancel = node('button', 'Отмена', 'ghost');
    cancel.addEventListener('click', function () {
      cancelDrawing(true);
      closeCard();
    });
    els.card.appendChild(cancel);
  }

  // --- Размеченная область -------------------------------------------------
  //
  // Заявление «здесь разбирались руками». Внутри неё воскресная пересборка
  // смотрит и докладывает, но НИЧЕГО НЕ ДВИГАЕТ. Без этого правила своя карта
  // невозможна: каждая пересборка отчасти обесценивает предыдущую неделю
  // работы, причём молча.

  function markArea(coords) {
    post('/api/edit', {
      kind: 'lock', geom: [coords[1], coords[0]], raw: [coords[1], coords[0]],
      props: { radius: 120 }, status: ACCEPTED,
    }).then(function (result) {
      if (result.error) { hint(result.error); return; }
      hint('Область размечена: автоматика здесь больше ничего не двигает.');
      offerUndo('Размеченная область', function () {
        return post('/api/edit/withdraw',
                    { id: result.id, version: result.version });
      });
      walking = false;
      reloadEdits();
    });
  }

  function renderAreas() {
    areaLayer.forEach(function (item) { map.geoObjects.remove(item); });
    areaLayer = [];
    areasInFrame.forEach(function (area) {
      const circle = new ymaps.Circle(
        [[area.point[1], area.point[0]], area.radius],
        { hintContent: 'Размечено руками · автоматика здесь не двигает' },
        { fillColor: '#ffb02022', strokeColor: '#ffb020', strokeWidth: 2,
          strokeStyle: 'shortdash', zIndex: 150,
          // Область СКВОЗНАЯ для щелчка. Она бывает в сотни метров шириной и
          // накрывает как раз то место, где идёт ручная работа; ловя щелчки на
          // себя, она не давала ни поставить вершину, ни выбрать дорогу —
          // ровно там, где это нужнее всего.
          interactivityModel: 'default#transparent' });
      map.geoObjects.add(circle);
      areaLayer.push(circle);
    });
  }

  function showView(wanted) {
    if (schema !== wanted) { toggleSchema(); }
  }

  function markView() {
    if (!els.viewSchema) { return; }
    els.viewSchema.classList.toggle('on', schema);
    els.viewSat.classList.toggle('on', !schema);
    if (els.viewDay) {
      els.viewDay.classList.toggle('on', daylight());
      els.viewDay.textContent = daylight() ? 'День' : 'Ночь';
    }
  }

  // Снимок — только в iD. Обводить дороги по спутнику Яндекса для своей
  // карты нельзя (их условия; docs/plan_vector_stack.md), а в iD снимки Bing и
  // Esri разрешены правообладателями именно для правок OSM. Правка в OSM
  // доезжает до карты воскресной сборкой — законно и для всех.
  function toggleSchema() {
    const centre = map.getCenter();
    const zoom = Math.max(17, Math.round(map.getZoom()));
    window.open('https://www.openstreetmap.org/edit?editor=id#map=' + zoom + '/' +
                centre[0].toFixed(6) + '/' + centre[1].toFixed(6), '_blank', 'noopener');
    hint('Снимок открыт в iD (Bing/Esri): там правка уходит в OSM и вернётся воскресной сборкой.');
  }

  // Своя работа на карте.
  //
  // Нарисованная дорога показывается ДОРОГОЙ — тем же полотном своей ширины,
  // что и пришедшая из OSM, только поверх и с пунктиром «наше». Иначе между
  // «нарисовал» и «увидел» лежит неделя: схема берётся из тайлов, а тайлы
  // пересобираются в воскресенье. Работать в таком инструменте нельзя.
  function renderMine() {
    mineShapes.forEach(function (shape) { map.geoObjects.remove(shape); });
    mineShapes = [];
    const perPixel = metersPerPixel();
    const edits = editsInFrame;

    function add(shape) { map.geoObjects.add(shape); mineShapes.push(shape); }
    function path(points) {
      return points.map(function (p) { return [p[1], p[0]]; });
    }

    edits.forEach(function (edit) {
      const drawn = edit.draw || {};
      if (drawn.shape === 'line' && edit.kind === 'geometry') {
        const width = Math.max(2, (drawn.width || 6) / perPixel);
        const state = stateOf(edit);
        add(new ymaps.Polyline(path(edit.geom), {}, {
          strokeColor: casing(), strokeWidth: width + 3, zIndex: 320,
          interactivityModel: 'default#transparent' }));
        add(new ymaps.Polyline(path(edit.geom), {
          hintContent: 'Своя дорога · класс ' + (drawn.cls || '?') + ' · ' +
                       (drawn.lanes || '?') + ' полос · ' + state.what,
        }, { strokeColor: asphalt(drawn.cls || 6), strokeWidth: width,
             zIndex: 321, interactivityModel: 'default#transparent' }));
        // Кайма состояния поверх полотна: цвет говорит что, штрих — то же
        // самое вторым способом. Опубликованная идёт сплошной: она уже часть
        // карты, и отличать её надо мягче, чем ждущую решения.
        add(new ymaps.Polyline(path(edit.geom), {}, {
          strokeColor: state.colour, strokeWidth: 2,
          strokeStyle: state.dash ? state.dash.join(' ') : 'solid',
          zIndex: 322, interactivityModel: 'default#transparent' }));
        // Пунктир поверх полотна — единственное, чем своё отличается от
        // чужого. Через месяц работы отличить их иначе будет нельзя.
        add(new ymaps.Polyline(path(edit.geom), {}, {
          strokeColor: '#ffb020', strokeWidth: 2, strokeStyle: 'shortdash',
          strokeOpacity: 0.9, zIndex: 322,
          interactivityModel: 'default#transparent' }));
        return;
      }
      if (drawn.shape === 'line') {
        // Убранная дорога. Показываем ту самую линию, которую убрали: решение
        // проверяют по тому, ТА ли это дорога, а по точке этого не видно.
        add(new ymaps.Polyline(path(edit.geom), {
          hintContent: 'Убрана · ' + ((edit.props || {}).why || ''),
        }, { strokeColor: '#ff4d4f', strokeWidth: 4, strokeStyle: 'shortdash',
             strokeOpacity: 0.85, zIndex: 320,
             interactivityModel: 'default#transparent' }));
        return;
      }
      if (drawn.shape === 'ring') {
        const code = (edit.props || {}).area;
        add(new ymaps.Polygon([path(edit.geom)], {
          hintContent: (AREAS[code] || 'Местность') + ' · ещё не опубликована',
        }, { fillColor: AREA_FILL[code] || '#38e58c33',
             strokeColor: '#ffb020', strokeWidth: 2, strokeStyle: 'shortdash',
             zIndex: 180, interactivityModel: 'default#transparent' }));
      }
    });
  }

  function reloadEdits() {
    const mine = generation;
    get('/api/edits' + (loadedBox ? boxQuery(loadedBox) : bbox())).then(function (data) {
      if (mine !== generation || (data && data.aborted)) { return; }
      known = {};
      const edits = data.edits || [];
      areasInFrame = edits
        .filter(function (e) { return e.kind === 'lock'; })
        .map(function (e) {
          return { point: e.geom, radius: (e.props || {}).radius || 120 };
        });
      renderAreas();
      editsInFrame = edits.filter(function (e) { return e.kind !== 'lock'; });
      renderMine();
      objects.removeAll();
      objects.add({
        type: 'FeatureCollection',
        features: edits.filter(function (edit) {
          // У линии и контура своя отрисовка; метка на них — только ручка,
          // за которую правку берут, и она стоит на первой вершине.
          return edit.kind !== 'lock' && edit.draw && edit.draw.point;
        }).map(function (edit) {
          known[edit.id] = edit;
          const lanes = edit.props && edit.props.lanes;
          const at = edit.draw.point;
          return {
            type: 'Feature',
            id: edit.id,
            geometry: { type: 'Point', coordinates: [at[1], at[0]] },
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

  // Что уже сделано в этой рамке.
  //
  // «А что я успел» — вопрос, который задают на третьем сеансе, и отвечать на
  // него памятью нельзя. Показываем своё же, но отдельно от работы: сделанное
  // не должно притворяться недоделанным.
  function renderDone() {
    const mine = editsInFrame.filter(function (edit) {
      return edit.draw && edit.draw.point;
    });
    if (!mine.length) { return; }
    els.todo.appendChild(node('div', 'Сделано здесь · ' + mine.length, 'muted'));
    mine.slice(-8).reverse().forEach(function (edit) {
      const drawn = edit.draw;
      const what = edit.kind === 'geometry'
        ? className(drawn.cls) + ' · ' + drawn.lanes + ' полос'
        : (NAMES[edit.kind] || edit.kind);
      const row = node('button', '#' + edit.id + ' · ' + what, 'todo-row done');
      row.addEventListener('click', function () {
        map.setCenter([drawn.point[1], drawn.point[0]],
                      Math.max(map.getZoom(), 18));
        select(edit.id);
      });
      els.todo.appendChild(row);
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
      renderDone();
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
    renderDone();
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

  // Что примкнуло последним: куда ставил человек и куда посадил магнит.
  let lastAttach = null;

  // Ближе этого две вершины считаются ОДНИМ узлом.
  //
  // Порог не выдуман: координаты в тайле лежат с шагом 1e-5°, это чуть больше
  // метра, и после генерализации сошедшиеся концы отличаются в последнем
  // знаке. Два метра ловят именно их и не хватают соседнюю улицу — ближайшая
  // проезжая часть на перекрёстке начинается метрах в десяти.
  const JOIN_METERS = 2;

  function metersApart(a, b) {
    const lat = (a[1] + b[1]) / 2 * Math.PI / 180;
    return Math.hypot((b[1] - a[1]) * 111320,
                      (b[0] - a[0]) * 111320 * Math.cos(lat));
  }

  // Кто ещё держится за эту точку.
  //
  // В нашей схеме перекрёсток — это не объект, а общий конец нескольких
  // отрезков: сборка режет дороги по общим вершинам. Поэтому сдвинуть один
  // отрезок и не тронуть остальные — значит разорвать перекрёсток молча:
  // на схеме останется щель, а маршрут через неё не пройдёт.
  function heldAt(point, own) {
    const out = [];
    roadsInFrame.forEach(function (road) {
      if (road.points === own) { return; }
      road.points.forEach(function (p, at) {
        if (metersApart(p, point) <= JOIN_METERS) { out.push({ road: road, at: at }); }
      });
    });
    return out;
  }

  // Соседи, которых тянут вместе с узлом. Копия, а не сама дорога: отказ от
  // правки не должен оставить схему сдвинутой.
  function heldCopy(road) {
    const key = road.points.map(function (p) { return p[0] + ',' + p[1]; }).join(';');
    if (!drawing.joined[key]) {
      drawing.joined[key] = {
        cls: road.cls, oneWay: road.oneWay, name: road.name,
        points: road.points.map(function (p) { return [p[0], p[1]]; }),
      };
    }
    return drawing.joined[key];
  }

  // Подвинуть узел: вершина едет, и с ней ВСЕ, кто за неё держится.
  function weld(index, to) {
    const was = drawing.points[index];
    (drawing.joins[index] || []).forEach(function (hold) {
      heldCopy(hold.road).points[hold.at] = [to[0], to[1]];
    });
    drawing.points[index] = [to[0], to[1]];
    return was;
  }

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

  function startDrawing(cls, areaCode) {
    closeCard();
    drawing = { points: [], cls: cls, area: areaCode || 0, joined: {},
                joins: [] };
    hint(areaCode
      ? 'Обведите контур: щелчок — вершина, Enter — замкнуть, Esc — отменить.'
      : 'Щелчок — вершина, Enter — закончить, Backspace — снять последнюю, '
        + 'Esc — отменить.');
    renderDrawing();
  }

  function renderDrawing() {
    if (drawLine) { map.geoObjects.remove(drawLine); drawLine = null; }
    drawDots.forEach(function (dot) { map.geoObjects.remove(dot); });
    drawDots = [];
    if (!drawing || !drawing.points.length) { return; }

    // Соседи по узлу — на экране. Иначе «поехали вместе» остаётся обещанием
    // в подсказке: человек видит сдвинутой одну улицу и не знает, тронулись
    // ли остальные, пока не опубликует.
    Object.keys(drawing.joined || {}).forEach(function (key) {
      const held = drawing.joined[key];
      const shape = new ymaps.Polyline(
        held.points.map(function (p) { return [p[1], p[0]]; }), {},
        { strokeColor: '#ffb020', strokeWidth: 3, strokeOpacity: 0.65,
          strokeStyle: 'shortdash', zIndex: 295 });
      map.geoObjects.add(shape);
      drawDots.push(shape);
    });

    if (drawing.points.length >= 2) {
      const path = drawing.points.map(function (p) { return [p[1], p[0]]; });
      // Контур показываем ЗАМКНУТЫМ уже во время рисования: иначе до самого
      // конца непонятно, что получится, и площадь приходится воображать.
      if (drawing.area) { path.push(path[0]); }
      if (drawing.area) {
        drawLine = new ymaps.Polyline(path, {},
          { strokeColor: '#38e58c', strokeWidth: 5, strokeOpacity: 0.9,
            zIndex: 300 });
        map.geoObjects.add(drawLine);
      } else {
        // Дорога ведётся ПОЛОТНОМ своего класса, а не одинаковой ниткой.
        // Проезд и магистраль на экране должны отличаться с первой вершины:
        // иначе «какую дорогу я делал» — вопрос без ответа до самой карточки.
        const lanes = drawing.lanes;
        const meters = lanes ? lanes * (LANE_METERS[drawing.cls] || 3.5)
                             : classWidth(drawing.cls);
        const width = Math.max(3, meters / metersPerPixel());
        [[width + 3, casing(), 298], [width, asphalt(drawing.cls), 299]]
          .forEach(function (layer) {
            const band = new ymaps.Polyline(path, {},
              { strokeColor: layer[1], strokeWidth: layer[0],
                strokeOpacity: 0.95, zIndex: layer[2] });
            map.geoObjects.add(band);
            drawDots.push(band);
          });
        drawLine = new ymaps.Polyline(path, {},
          { strokeColor: '#ffb020', strokeWidth: 2, strokeStyle: 'shortdash',
            strokeOpacity: 0.9, zIndex: 300 });
        map.geoObjects.add(drawLine);
      }
    }
    // Вершины ТЯНУТСЯ. Это и есть правка ломаной: диалог «изменить точку №3»
    // объяснять пришлось бы, а перетаскивание — нет.
    drawing.points.forEach(function (point, index) {
      const held = (drawing.joins[index] || []).length;
      const dot = new ymaps.Placemark([point[1], point[0]],
        { hintContent: held
            ? 'Узел · за него держатся ещё ' + held + ' · поедут вместе'
            : 'Вершина ' + (index + 1) + ' · Delete — убрать' },
        { preset: held ? 'islands#violetCircleDotIcon'
                       : 'islands#orangeCircleDotIcon',
          draggable: true, zIndex: 310 });
      dot.events.add('dragend', function () {
        const at = dot.geometry.getCoordinates();
        weld(index, [at[1], at[0]]);
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
          // Новая вершина ничей не узел: список держащихся обязан ехать
          // вместе с точками, иначе он начнёт указывать не на те.
          drawing.joins.splice(at, 0, []);
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
        // Через weld, а не напрямую: перенос улицы целиком тоже обязан
        // тащить за собой перекрёстки, за которые она держится.
        drawing.points.forEach(function (p, index) {
          weld(index, [p[0] + dLon, p[1] + dLat]);
        });
        renderDrawing();
      });
      map.geoObjects.add(handle);
      drawDots.push(handle);
    }
    hint((drawing.area ? AREAS[drawing.area] : className(drawing.cls)) +
         ' · вершин ' + drawing.points.length + ' · ' +
         drawnMeters(drawing.points) + ' м · Enter — готово');
  }

  // Прилипают только КОНЦЫ линии, а не каждая вершина.
  //
  // Дорога, нарисованная РЯДОМ с существующей, а не В неё, — не дорога, а
  // параллельная линия: маршрут по ней не пройдёт, а на схеме она останется
  // тупиком. Но притягивать середину нельзя: линию стянуло бы на соседние
  // улицы, и нарисовать съезд стало бы невозможно.
  function attachEnd(coords) {
    const asIs = [coords[1], coords[0]];
    return post('/api/snap', { lat: coords[0], lon: coords[1], touch: coarse })
      .then(function (snap) {
        const near = (snap.candidates || [])[0];
        if (near && !snap.ambiguous && near.meters <= ATTACH_METERS) {
          // Прилипание НАЗЫВАЕТСЯ вслух. Оно правильное — дорога, нарисованная
          // рядом с существующей, а не в неё, не дорога, — но невидимое
          // читается как «панель поставила точку сама, а я исправляй».
          lastAttach = { at: asIs, to: near.point };
          hint('Конец примкнул к «' + (near.name || 'дороге класса ' + near.cls)
               + '», ' + near.meters + ' м · Ctrl+D — не примыкать');
          return near.point;
        }
        lastAttach = null;
        return asIs;
      }, function () { lastAttach = null; return asIs; });
  }

  // Отменить ТОЛЬКО прилипание, не трогая линию.
  //
  // Раньше отмена была одна и убирала всю работу: чтобы не примкнуть, надо
  // было стереть нарисованное и начать заново.
  function detachEnd() {
    if (!lastAttach || !drawing || !drawing.points.length) {
      hint('Нечего откреплять: последний конец никуда не примыкал.');
      return;
    }
    const stuck = lastAttach;
    for (let i = drawing.points.length - 1; i >= 0; i--) {
      const p = drawing.points[i];
      if (p[0] === stuck.to[0] && p[1] === stuck.to[1]) {
        drawing.points[i] = [stuck.at[0], stuck.at[1]];
        lastAttach = null;
        renderDrawing();
        hint('Конец откреплён и стоит там, где вы его поставили.');
        return;
      }
    }
    hint('Этот конец уже подвинули — откреплять нечего.');
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
    if (drawing && drawing.area) {
      if (drawing.points.length < 3) {
        hint('Для контура нужно хотя бы три вершины.');
        return;
      }
      const ring = drawing.points.slice();
      const code = drawing.area;
      cancelDrawing(true);
      post('/api/edit', {
        kind: 'area', geom: ring, raw: ring[0],
        props: { area: code }, status: ACCEPTED,
      }).then(function (result) {
        if (result.error) {
          problem(AREAS[code] + ' НЕ сохранён: ' + result.error, ring[0], null);
          return;
        }
        hint(AREAS[code] + ' обведён. Публикует владелец со своей машины.');
        // Дому предлагаем адрес — но не требуем. Контур без адреса всё равно
        // застройка на схеме, а требование номера ради обводки дало бы
        // выдуманные номера.
        if (code === HOUSE_AREA) {
          offerRefine(AREAS[code] + ' обведён · адрес?',
            function () { askAddress(result, ring); },
            function () {
              return post('/api/edit/withdraw',
                          { id: result.id, version: result.version });
            });
        } else {
          offerUndo(AREAS[code], function () {
            return post('/api/edit/withdraw',
                        { id: result.id, version: result.version });
          });
        }
        walking = false;
        reloadEdits();
      });
      return;
    }
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
      const was = drawing;
      cancelDrawing(true);
      current = { kind: 'geometry', geom: points, raw: points[0],
                  props: { cls: cls }, note: '' };
      // Сохраняем СРАЗУ. Класс выбран в палитре, причина следует из ситуации,
      // полосы считаются по классу, мост и односторонняя выключены — четыре
      // вопроса из пяти уже имеют ответ, и спрашивать их на каждой дороге
      // значит брать плату за то, что и так известно. Уточнение — после, и
      // только когда оно нужно.
      saveRoad(points, cls, was, {
        cls: cls, oneway: false, bridge: false,
        why: was && was.replace ? 'OSM неверен' : 'нет в OSM',
      });
    });
  }

  // Адрес нарисованного дома.
  //
  // Он едет в тот же адресный файл, что и адреса из OSM: дом, обведённый
  // руками, обязан находиться поиском ровно так же, как пришедший из экстракта
  // — телефон не знает и не должен знать, откуда взялся дом.
  function askAddress(made, ring) {
    els.card.hidden = false;
    els.card.innerHTML = '';
    els.card.appendChild(node('h3', 'Адрес дома'));
    els.card.appendChild(node('div',
      'Без адреса дом всё равно будет на схеме — просто его не найдёт поиск.',
      'muted'));
    const street = field('Улица', 'text', '');
    const house = field('Номер', 'text', '');
    els.card.appendChild(street.label);
    els.card.appendChild(house.label);
    const save = node('button', 'Сохранить адрес');
    save.addEventListener('click', function () {
      const name = street.input.value.trim();
      const number = house.input.value.trim();
      if (!name || !number) { hint('Нужны и улица, и номер.'); return; }
      post('/api/edit', {
        id: made.id, version: made.version, kind: 'area',
        geom: ring, raw: ring[0],
        props: { area: HOUSE_AREA, street: name, house: number },
        status: ACCEPTED,
      }).then(function (result) {
        if (result.error) { hint(result.error); return; }
        closeCard();
        hint('Адрес сохранён: ' + name + ', ' + number);
        walking = false;
        reloadEdits();
      });
    });
    els.card.appendChild(save);
    const skip = node('button', 'Без адреса', 'ghost');
    skip.addEventListener('click', closeCard);
    els.card.appendChild(skip);
  }

  function cancelDrawing(quiet) {
    drawing = null;
    chosenVertex = -1;
    renderDrawing();
    if (!quiet) { hint('Рисование отменено.'); }
  }

  // Сохранить дорогу и предложить уточнить.
  //
  // Одна дорога — одно движение: нарисовал, Enter, готово. Полоска внизу
  // держит два выхода — «Уточнить» для десятого случая из десяти и «Отменить»
  // для промаха, — и живёт до следующего действия, а не десять секунд:
  // «уточнить» через десять секунд после сохранения уже невозможно.
  function saveRoad(points, cls, was, props) {
    const held = Object.keys((was && was.joined) || {});
    if (was && was.replace) { props.replace = true; }
    current.props = props;
    current.status = ACCEPTED;
    post('/api/edit', current).then(function (result) {
      if (result.error) {
        // Геометрия рисовалась руками и стоила десятка щелчков — потерять её
        // из-за обрыва связи нельзя. Повтор шлёт ровно то же самое.
        problem('Дорога НЕ сохранена: ' + result.error, points[0],
                function () { saveRoad(points, cls, was, props); });
        return;
      }
      const also = held.map(function (key) {
        const road = was.joined[key];
        return post('/api/edit', {
          kind: 'geometry', geom: road.points, raw: road.points[0],
          props: { cls: road.cls, oneway: !!road.oneWay, bridge: false,
                   why: 'OSM неверен', replace: true },
          status: ACCEPTED,
        });
      });
      Promise.all(also).then(function (results) {
        const made = [result].concat(results.filter(function (r) {
          return r && !r.error;
        }));
        const lost = results.filter(function (r) { return !r || r.error; });
        closeCard();
        hint(lost.length
          ? className(cls) + ' сохранён, но ' + lost.length + ' соседних по '
            + 'узлу не сохранились. Проверьте перекрёсток.'
          : className(cls) + ' · ' + drawnMeters(points) + ' м · сохранено'
            + (made.length > 1 ? ', с узлами: ' + made.length : '')
            + '. Публикует владелец со своей машины.');
        offerRefine(className(cls) + ' · ' + drawnMeters(points) + ' м',
          function () { refineRoad(result, points, cls, props); },
          function () {
            return Promise.all(made.map(function (item) {
              return post('/api/edit/withdraw',
                          { id: item.id, version: item.version });
            }));
          });
        walking = false;
        reloadEdits();
      });
    });
  }

  // Уточнение уже сохранённой дороги: та самая карточка с пятью полями, но
  // после факта и по желанию.
  function refineRoad(result, points, cls, props) {
    current = { id: result.id, version: result.version, kind: 'geometry',
                geom: points, raw: points[0], props: props, note: '' };
    showRoadCard(points, cls, props.replace ? { replace: true } : null, props);
  }

  function showRoadCard(points, cls, was, filled) {
    const reshaping = !!(was && was.replace);
    const known = filled || {};
    els.card.hidden = false;
    els.card.innerHTML = '';
    els.card.appendChild(node('h3', className(cls) + ' · уточнить'));
    els.card.appendChild(node('div',
      'Дорога уже сохранена. Здесь — то, что нужно редко: полосы, '
      + 'односторонняя, мост.', 'muted'));
    if (reshaping) {
      els.card.appendChild(node('div',
        'Старая линия уйдёт со схемы при публикации.', 'muted'));
    }
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

    const lanes = field('Полос всего (пусто — по классу)', 'number',
                        known.lanes || '');
    els.card.appendChild(lanes.label);

    const oneway = check('Односторонняя');
    const bridge = check('Мост');
    oneway.input.checked = !!known.oneway;
    bridge.input.checked = !!known.bridge;
    els.card.appendChild(oneway.label);
    els.card.appendChild(bridge.label);

    // Причина обязательна и закрытым списком: свободный текст через полгода
    // превращается в «тест», «пока так» и «см. выше».
    const why = document.createElement('select');
    WHYS.forEach(function (text) {
      const option = document.createElement('option');
      option.value = text;
      option.textContent = text;
      // Перерисованная улица В OSM ЕСТЬ — её только что оттуда и взяли.
      // Причина по умолчанию «нет в OSM» была бы неправдой в каждой такой
      // правке, а ворота публикации спрашивают именно её.
      if (text === (known.why || (reshaping ? 'OSM неверен' : 'нет в OSM'))) {
        option.selected = true;
      }
      why.appendChild(option);
    });
    const whyLabel = node('label', 'Почему дорога своя');
    whyLabel.appendChild(why);
    els.card.appendChild(whyLabel);

    const save = node('button', 'Сохранить уточнение');
    save.addEventListener('click', function () {
      const count = parseInt(lanes.input.value, 10);
      current.props = {
        cls: parseInt(kind.value, 10),
        oneway: oneway.input.checked,
        bridge: bridge.input.checked,
        why: why.value,
      };
      if (reshaping) { current.props.replace = true; }
      if (count >= 1 && count <= 15) { current.props.lanes = count; }
      current.status = ACCEPTED;
      // Класс запоминаем ДО отправки: closeCard обнуляет current, и чтение
      // current.props после него роняло обработчик молча — внутри промиса
      // такое исключение не видно нигде.
      const saved = className(current.props.cls);
      // Правка УЖЕ существует: current несёт её номер и версию, и тот же
      // адрес обновляет её, а не заводит вторую рядом.
      post('/api/edit', current).then(function (result) {
        if (result.error) { hint(result.error); return; }
        closeCard();
        hint(saved + ' уточнён.');
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
    // На телефоне свёрнуто ВСЁ, кроме текущего инструмента: развёрнутые
    // списки занимают экран целиком и закрывают карту — то есть ровно то,
    // ради чего панель открыли. На столе места хватает, и прятать нечего.
    ['work', 'drawbox', 'pointbox', 'areabox', 'landbox'].forEach(function (id) {
      const box = document.getElementById(id);
      if (box) { box.open = !coarse; }
    });
    const start = placeFromHash() || { center: [41.311, 69.280], zoom: 17 };
    // Своя карта — это ПУСТОЙ холст, а не чужая схема с нашими линиями
    // поверх. Прозрачный тайл вместо подложки: под нашей сетью не должно
    // просвечивать ничего чужого, ни цветом, ни подписью, ни улицей, которой у
    // нас нет. Заодно чужие тайлы перестают качаться там, где их не видно.
    // Тип карты БЕЗ СЛОЁВ вовсе. Не «слой с пустым тайлом»: слой, у которого
    // плитки нет, рисует вместо неё свою светлую заглушку, и на девятнадцатом
    // масштабе ночная схема выходила чёрным по белому. Земля здесь — фон
    // подложечной панели, он задан в CSS страницы.
    ymaps.mapType.storage.add('rm#own', new ymaps.MapType('Своя карта', []));
    map = new ymaps.Map('map', {
      center: start.center, zoom: start.zoom,
      // Выбор подложки — наш собственный, наверху панели. Родной «Слои» знает
      // только про чужие типы и про нашу карту сказать ничего не может.
      controls: ['zoomControl'],
    }, { suppressMapOpenBlock: true });
    map.setType('rm#own');
    // Двойной щелчок НЕ приближает. Контур обводят быстрыми щелчками подряд, и
    // поведение по умолчанию съедало каждую вторую вершину, попутно меняя
    // масштаб: человек ставил четыре угла, а получал два и другой зум.
    map.behaviors.disable('dblClickZoom');
    objects = new ymaps.ObjectManager({ clusterize: false });
    map.geoObjects.add(objects);

    objects.objects.events.add('click', function (e) {
      select(e.get('objectId'));
    });
    map.events.add('click', function (e) {
      if (drawing) { addVertex(e.get('coords')); return; }
      if (candidatesOn && !markingArea && !pointCode) {
        const house = candidateUnder(e.get('coords'));
        if (house) { acceptCandidate(house); return; }
      }
      // Дорога больше не объект — она нарисована на холсте, и щелчок по ней
      // ловим сами: координата → ближайшая улица в загруженном списке. Это
      // тот же расчёт, что делает магнит на сервере, только локально, и он
      // дешевле, чем шесть тысяч обработчиков на объектах.
      if (schema && kind === 'select' && !markingArea && !pointCode) {
        const street = streetUnder(e.get('coords'));
        if (street) { askReshape(nearestPiece(street, e.get('coords'))); return; }
      }
      // Инструмент НЕ сбрасывается после одного объекта — так же, как
      // обстановка. Области размечают подряд, и возвращаться к плитке после
      // каждой значило бы платить щелчком за каждую следующую.
      if (markingArea) { markArea(e.get('coords')); return; }
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
    map.events.add('boundschange', onMapMoved);
    // Панорама — СДВИГ готового холста, а не перерисовка. Перерисовываем
    // только когда ушли за поля запаса или сменился зум: ровно ради этого
    // холст и строится шире экрана.
    map.events.add('actiontick', function () {
      // ПОКА ТЯНУТ И ЗУМЯТ — только сдвиг и масштаб готовой картинки.
      //
      // Здесь стояла ещё и пересборка «если холст устарел». При зуме зум
      // меняется НА КАЖДОМ КАДРЕ анимации, то есть холст объявлялся
      // устаревшим шестьдесят раз в секунду и перерисовывался целиком
      // столько же — карта вставала колом ровно во время зума.
      //
      // Сдвиг и масштаб — это один transform, он бесплатен.
      placeCanvas();
      // Но ждать КОНЦА движения нельзя: при долгой панораме или двух шагах
      // зума картинка кончается, и по краям остаётся чернота. Пересобираем не
      // на каждый кадр, а на затишье — не чаще раза в четверть секунды.
      if (canvasIsStale()) { repaintSoon(); }
    });
    map.events.add('sizechange', function () { paintSchema(); });
    // Зум меняет метры на пиксель, то есть ВСЮ ширину полотна. Без пересчёта
    // схема на другом масштабе врала бы о том, что увидит водитель.
    map.events.add('actionend', function () {
      // Зум меняет метры на пиксель, то есть ширину полотна — и у чужих дорог,
      // и у своих. Своя дорога, нарисованная в прежнем масштабе, иначе
      // осталась бы шире или уже соседней того же класса.
      placeCanvas();
      renderMine();
      // renderMarks сам просит пересборку холста: значки и краска живут там.
      // Отдельный paintSchema рядом означал бы двойную работу на каждое
      // движение карты.
      renderMarks();
    });
    drawRoads();
    reloadEdits();

    window.addEventListener('hashchange', function () {
      const target = placeFromHash();
      if (target) { map.setCenter(target.center, target.zoom); }
    });

    if (els.viewSchema) {
      els.viewSchema.addEventListener('click', function () { showView(true); });
      els.viewSat.addEventListener('click', function () { showView(false); });
      if (els.viewDay) {
        els.viewDay.addEventListener('click', function () {
          setDaylight(!daylight());
          markView();
        });
      }
      markView();
    }

    const buttons = Array.prototype.slice.call(document.querySelectorAll('.tool'));

    /// Инструмент, которым работали в прошлый раз, — возвращается сам.
    ///
    /// Список плиток одинаков всегда, и модератор, размечающий полосы час
    /// подряд, каждый раз ищет ту же плитку среди двадцати. Порядок при этом
    /// НЕ меняем: переставлять плитки под руку значит ломать привычку
    /// каждого следующего дня. Меняется только то, что выбрано при открытии.
    const LAST_TOOL = 'radarmap.tool';

    function rememberTool(button) {
      try {
        window.localStorage.setItem(LAST_TOOL, button.dataset.tool
          || button.getAttribute('data-kind') || '');
      } catch (e) { /* приватное окно — просто не помним */ }
    }

    function restoreTool() {
      let want = '';
      try { want = window.localStorage.getItem(LAST_TOOL) || ''; }
      catch (e) { return; }
      if (!want) { return; }
      const found = buttons.filter(function (b) {
        return (b.dataset.tool || b.getAttribute('data-kind') || '') === want;
      })[0];
      // «Выбрать» возвращать незачем — это и так состояние по умолчанию.
      if (found && want !== 'select') { found.click(); }
    }

    buttons.forEach(function (button) {
      // Метка инструмента — одна строка на все виды плиток: у них разные
      // атрибуты, и сравнивать их по одному значило бы завести четыре ветки
      // там, где нужна одна.
      button.dataset.tool = [button.getAttribute('data-kind'),
                             button.getAttribute('data-cls'),
                             button.getAttribute('data-area'),
                             button.getAttribute('data-point')]
                            .filter(Boolean).join(':');
      button.addEventListener('click', function () {
        rememberTool(button);
        buttons.forEach(function (b) { b.classList.remove('on'); });
        button.classList.add('on');
        kind = button.getAttribute('data-kind');
        const cls = button.getAttribute('data-cls');
        const area = button.getAttribute('data-area');
        const code = button.getAttribute('data-point');
        pointCode = code ? parseInt(code, 10) : 0;
        markingArea = button.getAttribute('data-kind') === 'lock';
        if (markingArea) {
          cancelDrawing(true);
          hint('Щелчок — разметить область: автоматика здесь перестанет двигать.');
        }
        if (area) {
          startDrawing(6, parseInt(area, 10));
        } else if (cls) {
          startDrawing(parseInt(cls, 10));
        } else {
          cancelDrawing(true);
          if (pointCode) { hint('Щелчок по дороге — ' + POINTS[pointCode] + '.'); }
        }
      });
    });
    restoreTool();

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
        if (e.key === 'd' || e.key === 'в') { e.preventDefault(); detachEnd(); }
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
        drawing.joins.pop();
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
        // Узел не удаляется вместе с вершиной. За него держатся другие улицы,
        // и убрать его здесь значило бы оставить их концы висеть в воздухе —
        // причём молча, потому что чужие правки отсюда не видны.
        if ((drawing.joins[chosenVertex] || []).length) {
          hint('Это узел: за него держатся другие улицы. Сдвинуть можно, '
               + 'убрать — нет.');
          return;
        }
        drawing.points.splice(chosenVertex, 1);
        drawing.joins.splice(chosenVertex, 1);
        chosenVertex = -1;
        renderDrawing();
        return;
      }
      if (e.key === 'Delete' || e.key === 'Backspace') {
        if (!inField && current && current.id) { e.preventDefault(); withdrawCurrent(); }
        return;
      }
      if (inField) { return; }

      // Экран горячих клавиш по «?».
      //
      // Их полтора десятка, и узнать о них было неоткуда: подсказка в углу
      // говорит о текущем инструменте, а первая же карточка её закрывает.
      // Клавиша, о которой не знают, не существует.
      if (e.key === '?' || e.key === '/' || e.key === ',') {
        e.preventDefault();
        toggleKeysCard();
        return;
      }
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
      if (e.key.toLowerCase() === 'h' || e.key.toLowerCase() === 'р') {
        const button = document.querySelector('[data-area="6"]');
        if (button) { button.click(); }
        return;
      }
      if (e.key.toLowerCase() === 'i' || e.key.toLowerCase() === 'ш') {
        const button = document.querySelector('[data-area="9"]');
        if (button) { button.click(); }
        return;
      }
      if (e.key.toLowerCase() === 'c' || e.key.toLowerCase() === 'с') {
        candidatesOn = !candidatesOn;
        hint(candidatesOn ? 'Кандидаты нейросети включены.'
                          : 'Кандидаты выключены.');
        drawRoads();
        return;
      }
      if (e.key.toLowerCase() === 'z' || e.key.toLowerCase() === 'я') {
        const button = document.querySelector('[data-kind="lock"]');
        if (button) { button.click(); }
        return;
      }
      const marks = { a: 1, ф: 1, s: 5, ы: 5, d: 3, в: 3, f: 4, а: 4, g: 2, п: 2 };
      const code = marks[e.key.toLowerCase()];
      if (code) {
        const button = document.querySelector('[data-point="' + code + '"]');
        if (button) { button.click(); }
        return;
      }
      // Клавиша привязана к ВИДУ инструмента, а не к его месту в списке.
      // По порядку это ломалось от каждой новой плитки: на плитке написано
      // «1», а нажатие выбирало соседнюю.
      const kinds = { '1': 'lanes', '2': 'turn_lanes', '3': 'u_turn',
                      v: 'select', м: 'select' };
      const wanted = kinds[e.key] || kinds[e.key.toLowerCase()];
      if (wanted) {
        const button = document.querySelector('[data-kind="' + wanted + '"]');
        if (button) { button.click(); }
      }
    });
  });
})();
