// Модерация положения камер: одна карта на всю страну.
//
// Прежний экран стоил семи действий и двух перезагрузок на одну камеру —
// список, страница камеры, перетаскивание, возврат. Здесь работа идёт на
// месте: клик выбирает, перетаскивание двигает, сохранение не перезагружает
// страницу, и район, в котором работаешь, никуда не уезжает.
//
// Без сборки и зависимостей: это один экран, а не приложение. ObjectManager
// Яндекса взят намеренно — 3467 точек он кластеризует сам и рисует только
// видимое, тогда как отдельные метки на такой объём кладут вкладку.
'use strict';

ymaps.ready(function () {
  // Состояния камеры = цвета. Цвет и есть очередь работы: отдельный список
  // не нужен, если видно, где чинить.
  const PRESET = [
    'islands#grayCircleDotIcon',    // 0 обычная
    'islands#yellowCircleDotIcon',  // 1 снап под вопросом
    'islands#redCircleDotIcon',     // 2 жалоба «стоит не там»
    'islands#greenCircleDotIcon',   // 3 перенесена, ждёт публикации
  ];
  const STATE_DECIDED = 3;

  const map = new ymaps.Map('map', {
    center: [41.311, 69.279], zoom: 11, type: 'yandex#hybrid',
    controls: ['zoomControl', 'typeSelector', 'fullscreenControl'],
  });

  const objects = new ymaps.ObjectManager({
    clusterize: true, gridSize: 64,
    clusterIconLayout: 'default#pieChart',
  });
  map.geoObjects.add(objects);

  const side = document.getElementById('side');
  const els = {
    title: document.getElementById('s-title'),
    profile: document.getElementById('s-profile'),
    complaints: document.getElementById('s-complaints'),
    dist: document.getElementById('s-dist'),
    coords: document.getElementById('s-coords'),
    save: document.getElementById('s-save'),
    reset: document.getElementById('s-reset'),
    close: document.getElementById('s-close'),
    toast: document.getElementById('toast'),
    toastText: document.getElementById('toast-text'),
    toastUndo: document.getElementById('toast-undo'),
    query: document.getElementById('q'),
    found: document.getElementById('found'),
  };

  let editor = null;     // перетаскиваемая метка выбранной камеры
  let circle = null;     // предел переноса
  let current = null;    // подробности выбранной камеры
  let lastSaved = null;  // для отмены

  // --- загрузка ------------------------------------------------------------

  function load() {
    fetch('/api/cameras', { credentials: 'same-origin' })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        objects.add({
          type: 'FeatureCollection',
          features: data.cameras.map(function (c) {
            return {
              type: 'Feature', id: c[0],
              geometry: { type: 'Point', coordinates: [c[1], c[2]] },
              properties: { state: c[3] },
              options: { preset: PRESET[c[3]] },
            };
          }),
        });
        const hash = parseInt(location.hash.slice(1), 10);
        if (hash) select(hash, true);
      });
  }

  // --- выбор ---------------------------------------------------------------

  objects.objects.events.add('click', function (e) {
    select(e.get('objectId'), false);
  });

  function select(id, fly) {
    fetch('/api/camera/' + id, { credentials: 'same-origin' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        if (!data) return;
        current = data;
        const at = data.moved || data.origin;
        els.title.textContent = data.title;
        els.profile.textContent = data.profile;
        els.complaints.textContent = data.complaints
          ? 'жалоб «стоит не там»: ' + data.complaints : '';
        side.classList.add('on');
        if (fly) map.setCenter(at, 18);

        clearEditor();
        // Метка становится подвижной ТОЛЬКО после выбора: иначе случайное
        // протаскивание по карте с тремя тысячами точек двигало бы камеры.
        editor = new ymaps.Placemark(at, { hintContent: 'Тянуть' },
          { preset: 'islands#redIcon', draggable: true });
        editor.events.add(['drag', 'dragend'], refresh);
        map.geoObjects.add(editor);
        circle = new ymaps.Circle([data.origin, data.maxMeters], {}, {
          fillColor: '#3cdcff10', strokeColor: '#3cdcff', strokeWidth: 1,
        });
        map.geoObjects.add(circle);
        objects.objects.setObjectOptions(id, { iconOpacity: 0.25 });
        refresh();
      });
  }

  function clearEditor() {
    if (editor) { map.geoObjects.remove(editor); editor = null; }
    if (circle) { map.geoObjects.remove(circle); circle = null; }
    if (current) { objects.objects.setObjectOptions(current.id, { iconOpacity: 1 }); }
  }

  function close() {
    clearEditor();
    current = null;
    side.classList.remove('on');
  }

  function refresh() {
    if (!current || !editor) return;
    const point = editor.geometry.getCoordinates();
    const moved = ymaps.coordSystem.geo.getDistance(current.origin, point);
    els.dist.textContent = Math.round(moved);
    els.dist.className = moved > current.maxMeters ? 'far' : '';
    els.coords.textContent = point[0].toFixed(6) + ', ' + point[1].toFixed(6);
    els.save.disabled = moved < 1 || moved > current.maxMeters;
    els.save.textContent = moved > current.maxMeters
      ? 'Дальше ' + current.maxMeters + ' м нельзя' : 'Сохранить';
  }

  // --- сохранение и отмена -------------------------------------------------

  function save() {
    if (!current || !editor || els.save.disabled) return;
    const point = editor.geometry.getCoordinates();
    const id = current.id;
    post('/api/move', { id: id, lat: point[0], lon: point[1] }, function (data) {
      if (data.error) { toast(data.error, false); return; }
      objects.objects.setObjectOptions(id, {
        preset: PRESET[STATE_DECIDED], iconOpacity: 1,
      });
      objects.objects.setObjectGeometry(id, { type: 'Point', coordinates: point });
      setPending(data.pending);
      lastSaved = id;
      toast('перенесено на ' + data.moved + ' м', true);
      close();
    });
  }

  function undo() {
    if (!lastSaved) return;
    const id = lastSaved;
    post('/api/undo', { id: id }, function (data) {
      if (data.origin && data.origin[0]) {
        objects.objects.setObjectGeometry(id, {
          type: 'Point', coordinates: data.origin,
        });
      }
      objects.objects.setObjectOptions(id, { preset: PRESET[0] });
      setPending(data.pending);
      lastSaved = null;
      els.toast.classList.remove('on');
    });
  }

  function post(url, body, done) {
    fetch(url, {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(function (r) { return r.json(); })
      .then(done)
      .catch(function () { toast('не сохранилось: нет связи', false); });
  }

  let toastTimer = null;
  function toast(text, undoable) {
    els.toastText.textContent = text;
    els.toastUndo.style.display = undoable ? '' : 'none';
    els.toast.classList.add('on');
    clearTimeout(toastTimer);
    // Пять секунд на отмену: промах мышью неизбежен при работе по сотне точек,
    // и заметить его надо сразу, а не при публикации.
    toastTimer = setTimeout(function () { els.toast.classList.remove('on'); }, 5000);
  }

  function setPending(count) {
    const chip = document.querySelector('[data-filter="done"]');
    if (chip && typeof count === 'number') chip.textContent = 'Правки · ' + count;
  }

  // --- фильтры и поиск -----------------------------------------------------

  document.querySelectorAll('.chip').forEach(function (chip) {
    chip.addEventListener('click', function () {
      document.querySelectorAll('.chip').forEach(function (c) { c.classList.remove('on'); });
      chip.classList.add('on');
      const filter = chip.dataset.filter;
      objects.setFilter(function (obj) {
        const state = obj.properties.state;
        if (filter === 'work') return state === 1 || state === 2;
        if (filter === 'done') return state === 3;
        return true;
      });
    });
  });

  let searchTimer = null;
  els.query.addEventListener('input', function () {
    clearTimeout(searchTimer);
    const value = els.query.value.trim();
    if (value.length < 2) { els.found.style.display = 'none'; return; }
    searchTimer = setTimeout(function () {
      fetch('/api/search?q=' + encodeURIComponent(value), { credentials: 'same-origin' })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          els.found.innerHTML = '';
          data.found.forEach(function (item) {
            const row = document.createElement('div');
            row.textContent = item.title;
            row.addEventListener('click', function () {
              els.found.style.display = 'none';
              els.query.value = '';
              map.setCenter(item.point, 18);
              select(item.id, true);
            });
            els.found.appendChild(row);
          });
          els.found.style.display = data.found.length ? 'block' : 'none';
        });
    }, 250);
  });

  // --- управление ----------------------------------------------------------

  els.save.addEventListener('click', save);
  els.close.addEventListener('click', close);
  els.reset.addEventListener('click', function () {
    if (!current || !editor) return;
    editor.geometry.setCoordinates(current.origin);
    refresh();
  });
  els.toastUndo.addEventListener('click', undo);
  // Клавиши: при потоковой работе они экономят больше, чем кажется.
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') close();
    if (e.key === 'Enter' && !els.save.disabled && side.classList.contains('on')) save();
  });

  load();
});
