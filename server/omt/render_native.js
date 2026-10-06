// Проверочный рендер стиля движком MapLibre Native (тем же, что в приложении), без браузера.
// Headless Chrome не дорисовывает подложку; этот — рисует всё.
//   Node 22 (у пакета нет сборок под 25) + npm install @maplibre/maplibre-gl-native pngjs
//   node render_native.js http://127.0.0.1:8770/st_light_full.json 18 41.3265 69.2345 out.png [w h pitch bearing]
const mbgl = require('@maplibre/maplibre-gl-native');
const { PNG } = require('pngjs');
const http = require('http');
const fs = require('fs');
const [styleUrl, zoom, lat, lon, out, w = '1400', h = '900', pitch = '0', bearing = '0'] = process.argv.slice(2);
function get(url) {
  return new Promise((resolve) => {
    http.get(url, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, data: Buffer.concat(chunks) }));
    }).on('error', () => resolve({ status: 0, data: Buffer.alloc(0) }));
  });
}
const map = new mbgl.Map({
  ratio: 1,
  request: (req, cb) => {
    get(req.url).then(({ status, data }) => {
      if (status === 200 && data.length) cb(null, { data });
      else cb(null, {});
    });
  },
});
get(styleUrl).then(({ data }) => {
  map.load(JSON.parse(data.toString()));
  map.render({ zoom: Number(zoom), center: [Number(lon), Number(lat)], width: Number(w), height: Number(h),
                pitch: Number(pitch), bearing: Number(bearing) },
    (err, buffer) => {
      if (err) { console.error(err.message); process.exit(1); }
      const png = new PNG({ width: Number(w), height: Number(h) });
      png.data = Buffer.from(buffer);
      fs.writeFileSync(out, PNG.sync.write(png));
      map.release();
      console.log('ok', out);
    });
});
