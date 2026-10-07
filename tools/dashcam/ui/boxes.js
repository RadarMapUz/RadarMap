'use strict';
// «Разбор видео»: разметка рамкой — камеры фиксации на кадрах их проездов.
let boxItem = null, boxes = [], drag = null;
const cv = $('l-canvas');

function boxMode() { return tab === 'label' && $('l-task').value === 'camera'; }
function syncMode() {
  const on = $('l-task').value === 'camera';
  $('labeler').classList.toggle('boxmode', on);
  $('l-task-help').hidden = !on;
  $('l-cls').hidden = on;
  $('b-btns').hidden = !on;
  document.querySelector('#labeler .l-btns').hidden = on;
  cv.hidden = !on;
  if (on) nextBox(); else nextLabel();
}
$('l-task').onchange = syncMode;

async function nextBox() {
  boxes = [];
  boxItem = await api('/api/boxes/next');
  if (boxItem.done) {
    $('l-q').textContent = `Все кадры размечены (${boxItem.labeled} из ${boxItem.total})`;
    $('l-img').removeAttribute('src');
    return;
  }
  $('l-q').textContent = `Где камера фиксации ${boxItem.camera_id ?? ''}? (до неё ~${boxItem.dist_m} м)`;
  $('l-meta').textContent = `размечено ${boxItem.labeled} из ${boxItem.total}`;
  $('l-img').src = boxItem.url;
}
$('l-img').addEventListener('load', () => { if (boxMode()) drawBoxes(); });

function imgScale() {
  const img = $('l-img');
  return { kx: img.naturalWidth / img.clientWidth, ky: img.naturalHeight / img.clientHeight };
}
function drawBoxes() {
  const img = $('l-img');
  cv.width = img.clientWidth; cv.height = img.clientHeight;
  const g = cv.getContext('2d'), s = imgScale();
  g.clearRect(0, 0, cv.width, cv.height);
  g.lineWidth = 2; g.strokeStyle = '#ff00ff';
  for (const b of boxes) g.strokeRect(b[0] / s.kx, b[1] / s.ky, b[2] / s.kx, b[3] / s.ky);
  if (drag && drag.cur) {
    g.setLineDash([4, 3]);
    g.strokeRect(Math.min(drag.x, drag.cur.x), Math.min(drag.y, drag.cur.y),
      Math.abs(drag.cur.x - drag.x), Math.abs(drag.cur.y - drag.y));
    g.setLineDash([]);
  }
}
function pos(e) { const r = cv.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
cv.addEventListener('mousedown', (e) => { drag = pos(e); });
cv.addEventListener('mousemove', (e) => { if (drag) { drag.cur = pos(e); drawBoxes(); } });
window.addEventListener('mouseup', (e) => {
  if (!drag) return;
  const p = drag.cur || pos(e), s = imgScale();
  const w = Math.abs(p.x - drag.x), h = Math.abs(p.y - drag.y);
  if (w > 3 && h > 3) boxes.push([Math.min(p.x, drag.x) * s.kx, Math.min(p.y, drag.y) * s.ky, w * s.kx, h * s.ky]);
  drag = null; drawBoxes();
});
async function saveBoxes(none) {
  if (!boxItem || boxItem.done) return;
  await api('/api/boxes', { frame_id: boxItem.frame_id, boxes: none ? [] : boxes, none: !!none || !boxes.length });
  nextBox();
}
$('b-save').onclick = () => saveBoxes(false);
$('b-none').onclick = () => saveBoxes(true);
$('b-undo').onclick = () => { boxes.pop(); drawBoxes(); };
document.addEventListener('keydown', (e) => {
  if (!boxMode()) return;
  if (e.key === 'Enter') saveBoxes(false);
  else if (e.key.toLowerCase() === 'n' || e.key.toLowerCase() === 'т') saveBoxes(true);
  else if (e.key === 'Backspace') { boxes.pop(); drawBoxes(); }
  else return;
  e.preventDefault(); e.stopImmediatePropagation();
}, true);
// при входе во вкладку «Разметка» — нужный режим
const _setTab2 = setTab;
setTab = function (t) { _setTab2(t); if (t === 'label' && $('l-task').value === 'camera') syncMode(); };
cv.hidden = true;
