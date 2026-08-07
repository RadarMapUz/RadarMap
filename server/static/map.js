// Перенос камеры мышью. Единственный скрипт во всей панели — отсюда и
// требование к нему: он не «приложение», а один экран, поэтому без сборки,
// без зависимостей и целиком читается за минуту.
//
// Отдельным файлом, а не внутри страницы, намеренно: так CSP остаётся строгой
// (`script-src 'self'` вместо разрешения выполнять любой встроенный код), и
// внедрить сюда чужой скрипт через данные камеры невозможно.
'use strict';

ymaps.ready(function () {
  const data = JSON.parse(document.getElementById('data').textContent);
  const latField = document.getElementById('lat');
  const lonField = document.getElementById('lon');
  const distText = document.getElementById('dist');
  const coordsText = document.getElementById('coords');
  const saveButton = document.getElementById('save');

  const map = new ymaps.Map('map', {
    center: data.start,
    zoom: 18,
    // Спутник + подписи: положение камеры проверяют по снимку — на схеме
    // ни столба, ни рамки над дорогой не видно.
    type: 'yandex#hybrid',
    controls: ['zoomControl', 'typeSelector', 'fullscreenControl'],
  });

  // Исходная точка и предел переноса. Круг рисуется всегда: он объясняет
  // отказ раньше, чем человек упрётся в него мышью.
  map.geoObjects.add(new ymaps.Circle([data.origin, data.maxMeters], {}, {
    fillColor: '#3cdcff10', strokeColor: '#3cdcff', strokeWidth: 1,
  }));
  map.geoObjects.add(new ymaps.Placemark(data.origin, {
    hintContent: 'Где камера стоит сейчас',
  }, { preset: 'islands#grayDotIcon' }));

  // Соседние камеры — чтобы не подвинуть точку на место другой камеры.
  data.neighbours.forEach(function (item) {
    map.geoObjects.add(new ymaps.Placemark([item[0], item[1]], {
      hintContent: item[2],
    }, { preset: 'islands#grayCircleDotIcon' }));
  });

  const marker = new ymaps.Placemark(data.start, { hintContent: 'Тянуть сюда' },
    { preset: 'islands#redIcon', draggable: true });
  map.geoObjects.add(marker);

  function distance(a, b) {
    return ymaps.coordSystem.geo.getDistance(a, b);
  }

  function update() {
    const point = marker.geometry.getCoordinates();
    const moved = distance(data.origin, point);
    distText.textContent = Math.round(moved);
    distText.className = moved > data.maxMeters ? 'far' : '';
    coordsText.textContent = point[0].toFixed(6) + ', ' + point[1].toFixed(6);
    latField.value = point[0].toFixed(6);
    lonField.value = point[1].toFixed(6);
    // Кнопка неактивна и когда не двигали, и когда ушли за предел: приложение
    // такую правку всё равно отвергнет, и узнать об этом лучше здесь.
    saveButton.disabled = moved < 1 || moved > data.maxMeters;
    saveButton.textContent = moved > data.maxMeters
      ? 'Слишком далеко — больше ' + data.maxMeters + ' м'
      : 'Сохранить перенос';
  }

  marker.events.add(['drag', 'dragend'], update);
  document.getElementById('reset').addEventListener('click', function () {
    marker.geometry.setCoordinates(data.origin);
    update();
  });
  update();
});
