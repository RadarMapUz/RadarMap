// Рендер кадров стиля движком MapLibre Native (тем же, что в приложении), без браузера и сервера.
// Тайлы, шрифты и спрайт читаются с диска по адресам local://…
//   node render.js jobs.json
// jobs.json: {"roots": {"omt": dir, "mvt": dir, "glyphs": dir, "sprite": dir},
//             "jobs": [{"style": file, "zoom", "lat", "lon", "w", "h", "pitch", "bearing", "ratio", "out"}]}
const mbgl = require('@maplibre/maplibre-gl-native');
const { PNG } = require('pngjs');
const fs = require('fs');
const path = require('path');

const spec = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const roots = spec.roots;

function localPath(url) {
  const m = url.match(/^local:\/*(?:v\/[^/]+\/)?(omt|mvt|glyphs|sprite)\/(.*)$/);
  if (!m) return null;
  return path.join(roots[m[1]], decodeURIComponent(m[2]));
}

function render(job) {
  return new Promise((resolve) => {
    const ratio = job.ratio || 1;
    const map = new mbgl.Map({
      ratio,
      request: (req, cb) => {
        const file = localPath(req.url);
        if (file && fs.existsSync(file)) cb(null, { data: fs.readFileSync(file) });
        else cb(null, {});
      },
    });
    map.load(JSON.parse(fs.readFileSync(job.style, 'utf8')));
    map.render({ zoom: job.zoom, center: [job.lon, job.lat], width: job.w, height: job.h,
                 pitch: job.pitch || 0, bearing: job.bearing || 0 }, (err, buffer) => {
      if (err) { console.error('fail', job.out, err.message); map.release(); resolve(false); return; }
      const png = new PNG({ width: job.w * ratio, height: job.h * ratio });
      png.data = Buffer.from(buffer);
      fs.mkdirSync(path.dirname(job.out), { recursive: true });
      fs.writeFileSync(job.out, PNG.sync.write(png));
      map.release();
      resolve(true);
    });
  });
}

(async () => {
  let ok = 0;
  for (const job of spec.jobs) if (await render(job)) ok += 1;
  console.log(`ok ${ok}/${spec.jobs.length}`);
})();
