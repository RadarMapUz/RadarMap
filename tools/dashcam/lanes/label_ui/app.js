// Разметка полос: ломаные (линии разметки, бордюры) и рамки машин поверх кадра.
// Координаты разметки — пиксели кадра JPEG 1280×529; вид (V) только масштабирует.
'use strict';

const W = 1280, H = 529;
const LINE_CLS = { solid: 'сплошная', dashed: 'прерывистая', double: 'двойная', curb: 'бордюр' };
const BOX_CLS = { car_parked: 'припаркованная', car_moving: 'движущаяся' };
const COLOR = { solid: '#ffffff', dashed: '#4da3ff', double: '#ffc800', curb: '#ff4040',
                car_parked: '#c040c0', car_moving: '#00dcdc' };
const KEY_CLS = { '1': 'solid', '2': 'dashed', '3': 'double', '4': 'curb', '5': 'car_parked', '6': 'car_moving' };
const IDLE_CAP = 20;   // с: пауза дольше не считается временем разметки

const cv = document.getElementById('cv');
const ctx = cv.getContext('2d');
const img = new Image();
let S = null;          // ответ /api/item
let lines = [], boxes = [], undo = [];
let sel = null;        // {t: 'line'|'box', i}
let mode = 'edit';     // edit | draw | box
let lineCls = 'dashed', boxCls = 'car_parked';
let drawing = null, drag = null, boxStart = null;
let zoom = true, hide = false, origin = 'prefill';
let active = 0, lastEv = performance.now();
let statusArr = [];

// ── вид ──
function view() {
  return zoom ? { y0: 330, y1: H } : { y0: 0, y1: H };
}
function resize() {
  const v = view();
  cv.height = Math.round((v.y1 - v.y0) * (zoom ? 2 : 1));
  cv.width = W;
  draw();
}
function toImg(ev) {
  const r = cv.getBoundingClientRect(), v = view();
  const x = (ev.clientX - r.left) / r.width * W;
  const y = v.y0 + (ev.clientY - r.top) / r.height * (v.y1 - v.y0);
  return [x, y];
}
function toCv(p) {
  const v = view();
  return [p[0], (p[1] - v.y0) * cv.height / (v.y1 - v.y0)];
}
function pxScale() { return cv.getBoundingClientRect().width / W; }

// ── время ──
function tick() {
  const now = performance.now();
  active += Math.min((now - lastEv) / 1000, IDLE_CAP);
  lastEv = now;
}
setInterval(() => {
  const now = performance.now();
  const cur = active + Math.min((now - lastEv) / 1000, IDLE_CAP);
  document.getElementById('timer').textContent = cur.toFixed(0);
}, 500);

// ── состояние ──
function snapshot() { undo.push(JSON.stringify({ lines, boxes })); if (undo.length > 100) undo.shift(); }
function restore() {
  if (!undo.length) return;
  const s = JSON.parse(undo.pop()); lines = s.lines; boxes = s.boxes; sel = null; draw();
}
function clone(x) { return JSON.parse(JSON.stringify(x)); }
function msg(t) { document.getElementById('msg').textContent = t || ''; }

async function load(i) {
  const r = await fetch('api/item?i=' + i);
  if (!r.ok) { msg('нет кадра ' + i); return; }
  S = await r.json();
  if (S.label) {
    lines = clone(S.label.lines); boxes = clone(S.label.boxes || []); origin = S.label.origin || 'manual';
  } else {
    lines = clone(S.prefill); boxes = []; origin = 'prefill';
  }
  undo = []; sel = null; mode = 'edit'; drawing = null;
  active = 0; lastEv = performance.now();
  const it = S.item;
  document.getElementById('pos').textContent = (S.i + 1) + ' / ' + S.n;
  document.getElementById('meta').textContent = it.key + ' · ' + it.trip + ' · ' +
    (it.src === 'window' ? 'окно, круг ' + (it.round + 1) : 'кадр БД') +
    (S.label ? (S.label.skip ? ' · ПРОПУЩЕН' : ' · размечен') : '') +
    (S.transfer ? ' · есть перенос (T) с ' + S.transfer.from + ', ' + S.transfer.dt + ' с' : '');
  msg('');
  img.onload = draw;
  img.src = 'img?i=' + i;
  history.replaceState(null, '', '#' + i);
}

async function stats(st) {
  if (!st) st = await (await fetch('api/stats')).json();
  document.getElementById('done').textContent = st.done;
  document.getElementById('total').textContent = st.total;
  document.getElementById('skipped').textContent = st.skipped;
  document.getElementById('mean').textContent = st.mean_s ?? '–';
  document.getElementById('median').textContent = st.median_s ?? '–';
  statusArr = st.status;
  const strip = document.getElementById('strip');
  strip.innerHTML = '';
  st.status.forEach((s, j) => {
    const e = document.createElement('i');
    e.className = (s === 1 ? 'd' : s === 2 ? 's' : '') + (S && j === S.i ? ' c' : '');
    e.title = j + 1; e.onclick = () => load(j);
    strip.appendChild(e);
  });
}

async function save(skip) {
  tick();
  const body = { key: S.item.key, lines, boxes, skip: !!skip, seconds: active, origin };
  const r = await fetch('api/save', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                      body: JSON.stringify(body) });
  const st = await r.json();
  if (!r.ok) { msg('не сохранено: ' + st.error); return false; }
  await stats(st);
  return true;
}

function nextUnlabeled(from) {
  for (let k = 1; k <= statusArr.length; k++) {
    const j = (from + k) % statusArr.length;
    if (statusArr[j] === 0) return j;
  }
  return null;
}

// ── рисование ──
function draw() {
  const v = view();
  ctx.clearRect(0, 0, cv.width, cv.height);
  if (img.complete && img.naturalWidth)
    ctx.drawImage(img, 0, v.y0, W, v.y1 - v.y0, 0, 0, cv.width, cv.height);
  if (hide) return;
  const lw = Math.max(1.5, 2 / pxScale());
  if (S && S.transfer) {
    ctx.setLineDash([6, 6]);
    for (const l of S.transfer.lines) poly(l.pts, COLOR[l.cls], lw, 0.8);
    ctx.setLineDash([]);
  }
  boxes.forEach((b, i) => {
    const [x0, y0] = toCv([b.box[0], b.box[1]]), [x1, y1] = toCv([b.box[2], b.box[3]]);
    ctx.strokeStyle = COLOR[b.cls]; ctx.lineWidth = (sel && sel.t === 'box' && sel.i === i) ? lw * 2 : lw;
    ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
  });
  lines.forEach((l, i) => {
    const on = sel && sel.t === 'line' && sel.i === i;
    poly(l.pts, COLOR[l.cls], on ? lw * 2.2 : lw, 1);
    if (l.cls === 'double') { ctx.save(); ctx.translate(3, 0); poly(l.pts, COLOR[l.cls], lw, 0.6); ctx.restore(); }
    for (const p of l.pts) node(p, COLOR[l.cls], on);
  });
  if (drawing) {
    poly(drawing.pts, COLOR[drawing.cls], lw, 1);
    for (const p of drawing.pts) node(p, COLOR[drawing.cls], true);
  }
  if (boxStart && boxStart.cur) {
    const [x0, y0] = toCv(boxStart.p), [x1, y1] = toCv(boxStart.cur);
    ctx.strokeStyle = COLOR[boxCls]; ctx.lineWidth = lw; ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
  }
  bar();
}
function poly(pts, color, w, a) {
  if (pts.length < 1) return;
  ctx.globalAlpha = a; ctx.strokeStyle = color; ctx.lineWidth = w; ctx.beginPath();
  pts.forEach((p, k) => { const c = toCv(p); k ? ctx.lineTo(c[0], c[1]) : ctx.moveTo(c[0], c[1]); });
  ctx.stroke(); ctx.globalAlpha = 1;
}
function node(p, color, big) {
  const c = toCv(p), r = (big ? 5 : 3.5) / pxScale();
  ctx.fillStyle = color; ctx.strokeStyle = '#000'; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.arc(c[0], c[1], r, 0, 7); ctx.fill(); ctx.stroke();
}
function bar() {
  const b = document.getElementById('bar');
  const cur = sel && sel.t === 'line' ? lines[sel.i].cls : sel && sel.t === 'box' ? boxes[sel.i].cls : null;
  b.innerHTML = '';
  for (const [k, c] of Object.entries(KEY_CLS)) {
    const e = document.createElement('span');
    e.className = 'cls' + ((cur ? cur === c : (c === lineCls || c === boxCls)) ? ' on' : '');
    e.style.color = COLOR[c];
    e.textContent = k + ' ' + (LINE_CLS[c] || BOX_CLS[c]);
    e.onclick = () => setCls(c);
    b.appendChild(e);
  }
  const m = document.createElement('span');
  m.className = 'cls'; m.textContent = { edit: 'правка', draw: 'новая линия', box: 'рамка' }[mode] +
    ' · ' + ({ prefill: 'предзаполнение', transfer: 'перенос', manual: 'вручную' }[origin] || origin);
  b.appendChild(m);
}

// ── поиск под курсором ──
function distSeg(p, a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1], L = dx * dx + dy * dy;
  let t = L ? ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L : 0;
  t = Math.max(0, Math.min(1, t));
  return [Math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy), t];
}
function tolerance() { return 8 / pxScale(); }   // px кадра по горизонтали; по вертикали в V вдвое меньше
function hitNode(p) {
  const tol = tolerance();
  for (let i = lines.length - 1; i >= 0; i--)
    for (let k = 0; k < lines[i].pts.length; k++) {
      const q = lines[i].pts[k];
      if (Math.abs(q[0] - p[0]) < tol && Math.abs(q[1] - p[1]) < tol / (zoom ? 2 : 1)) return { i, k };
    }
  return null;
}
function hitLine(p) {
  const tol = tolerance();
  let best = null;
  lines.forEach((l, i) => {
    for (let k = 0; k + 1 < l.pts.length; k++) {
      const [d] = distSeg(p, l.pts[k], l.pts[k + 1]);
      if (d < tol && (!best || d < best.d)) best = { i, k, d };
    }
  });
  return best;
}
function hitBox(p) {
  for (let i = boxes.length - 1; i >= 0; i--) {
    const [x0, y0, x1, y1] = boxes[i].box;
    if (p[0] >= x0 && p[0] <= x1 && p[1] >= y0 && p[1] <= y1) return i;
  }
  return null;
}

// ── мышь ──
cv.addEventListener('mousedown', ev => {
  tick(); const p = toImg(ev);
  if (mode === 'draw') { drawing.pts.push(p); draw(); return; }
  if (mode === 'box') { boxStart = { p, cur: null }; return; }
  const n = hitNode(p);
  if (n) { snapshot(); sel = { t: 'line', i: n.i }; drag = { type: 'node', ...n }; draw(); return; }
  const l = hitLine(p);
  if (l) {
    sel = { t: 'line', i: l.i };
    if (ev.shiftKey) {
      snapshot(); lines[l.i].pts.splice(l.k + 1, 0, p);
      drag = { type: 'node', i: l.i, k: l.k + 1 };
    }
    draw(); return;
  }
  const b = hitBox(p);
  if (b !== null) {
    snapshot(); sel = { t: 'box', i: b };
    const bx = boxes[b].box;
    // ближайший угол тянем, середину — двигаем рамку целиком
    const corners = [[0, 1], [2, 1], [0, 3], [2, 3]];
    let best = null;
    corners.forEach(([xi, yi]) => {
      const d = Math.hypot(bx[xi] - p[0], bx[yi] - p[1]);
      if (!best || d < best.d) best = { d, xi, yi };
    });
    drag = best.d < tolerance() * 2 ? { type: 'corner', i: b, xi: best.xi, yi: best.yi }
                                    : { type: 'box', i: b, last: p };
    draw(); return;
  }
  sel = null; draw();
});
cv.addEventListener('mousemove', ev => {
  const p = toImg(ev);
  if (mode === 'box' && boxStart) { boxStart.cur = p; draw(); return; }
  if (!drag) return;
  tick();
  if (drag.type === 'node') lines[drag.i].pts[drag.k] = [p[0], p[1]];
  else if (drag.type === 'corner') { boxes[drag.i].box[drag.xi] = p[0]; boxes[drag.i].box[drag.yi] = p[1]; }
  else if (drag.type === 'box') {
    const dx = p[0] - drag.last[0], dy = p[1] - drag.last[1]; drag.last = p;
    const b = boxes[drag.i].box; b[0] += dx; b[2] += dx; b[1] += dy; b[3] += dy;
  }
  draw();
});
window.addEventListener('mouseup', () => {
  if (mode === 'box' && boxStart) {
    if (boxStart.cur) {
      const [a, b] = [boxStart.p, boxStart.cur];
      if (Math.abs(a[0] - b[0]) > 4 && Math.abs(a[1] - b[1]) > 4) {
        snapshot();
        boxes.push({ cls: boxCls, box: [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[0], b[0]), Math.max(a[1], b[1])] });
        sel = { t: 'box', i: boxes.length - 1 };
      }
    }
    boxStart = null; mode = 'edit'; draw(); return;
  }
  if (drag && drag.type === 'corner') {
    const b = boxes[drag.i].box;
    boxes[drag.i].box = [Math.min(b[0], b[2]), Math.min(b[1], b[3]), Math.max(b[0], b[2]), Math.max(b[1], b[3])];
  }
  drag = null;
});
cv.addEventListener('dblclick', ev => {
  if (mode !== 'edit') return;
  const n = hitNode(toImg(ev));
  if (!n) return;
  snapshot();
  if (lines[n.i].pts.length > 2) lines[n.i].pts.splice(n.k, 1);
  else { lines.splice(n.i, 1); sel = null; }
  draw();
});

function setCls(c) {
  if (LINE_CLS[c]) {
    lineCls = c;
    if (sel && sel.t === 'line') { snapshot(); lines[sel.i].cls = c; }
    if (drawing) drawing.cls = c;
  } else {
    boxCls = c;
    if (sel && sel.t === 'box') { snapshot(); boxes[sel.i].cls = c; }
  }
  draw();
}
function finishDraw() {
  if (drawing && drawing.pts.length >= 2) {
    snapshot(); lines.push(drawing); sel = { t: 'line', i: lines.length - 1 };
  }
  drawing = null; mode = 'edit'; draw();
}

// ── клавиши ──
window.addEventListener('keydown', async ev => {
  if (ev.metaKey && ev.key !== 'z') return;
  tick();
  const k = ev.key;
  if (KEY_CLS[k]) { setCls(KEY_CLS[k]); return; }
  switch (k.toLowerCase()) {
    case 'n':
      if (mode === 'draw') finishDraw();
      else { mode = 'draw'; drawing = { cls: lineCls, pts: [] }; sel = null; draw(); }
      return;
    case 'enter':
      if (mode === 'draw') { finishDraw(); return; }
      break;
    case 'escape':
      drawing = null; boxStart = null; mode = 'edit'; sel = null; draw(); return;
    case 'b': mode = 'box'; sel = null; draw(); return;
    case 'delete': case 'backspace':
      if (!sel) return;
      ev.preventDefault(); snapshot();
      if (sel.t === 'line') lines.splice(sel.i, 1); else boxes.splice(sel.i, 1);
      sel = null; draw(); return;
    case 'z': ev.preventDefault(); restore(); return;
    case 'r': snapshot(); lines = clone(S.prefill); boxes = []; origin = 'prefill'; sel = null; draw(); return;
    case 't':
      if (!S.transfer) { msg('переносить не с чего: в этом окне нет размеченного соседа'); return; }
      snapshot(); lines = clone(S.transfer.lines); origin = 'transfer'; sel = null; draw(); return;
    case 'v': zoom = !zoom; resize(); return;
    case 'h': hide = !hide; draw(); return;
    case 'x':
      if (await save(true)) { const j = nextUnlabeled(S.i); if (j !== null) load(j); }
      return;
    case ' ':
      ev.preventDefault();
      if (mode === 'draw') { finishDraw(); return; }
      if (await save(false)) {
        const j = nextUnlabeled(S.i);
        if (j !== null) load(j); else msg('всё размечено');
      }
      return;
    case 'arrowright': load(Math.min(S.n - 1, S.i + 1)); return;
    case 'arrowleft': load(Math.max(0, S.i - 1)); return;
  }
});

// Любая правка после предзаполнения/переноса остаётся с этим происхождением:
// «origin» говорит, с чего человек начал, а секунды — сколько правил.
(async () => {
  await stats();
  const h = parseInt(location.hash.slice(1), 10);
  const start = Number.isFinite(h) ? h : (nextUnlabeled(-1) ?? 0);
  await load(start);
  await stats();
  resize();
})();
window.addEventListener('resize', draw);
