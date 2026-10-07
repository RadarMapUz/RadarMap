#!/bin/bash
# Сборка базовой карты (OpenMapTiles) на маке владельца: ~5 минут против часов
# на сервере в 2 ГБ. Результат — каталог для публикации (publish_omt.sh):
#   omt/z/x/y.pbf, omt_index_payload.json, glyphs/, sprite/, style.json
#
#   bash server/omt/build_omt.sh [рабочий каталог, по умолчанию ~/RadarMapBuild/omt]
#
# Нужна Java 21: brew install openjdk@21. Planetiler и выгрузка OSM качаются сами.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HOME/RadarMapBuild/omt}"
BASE="${RADARMAP_BASE:-https://soulmed.uz/radarmap}"
JAVA="${JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}"
OUT="$WORK/publish"
mkdir -p "$WORK" && cd "$WORK"

[ -x "$JAVA" ] || { echo "нет Java 21: brew install openjdk@21"; exit 1; }
[ -f planetiler.jar ] || curl -sSfL -o planetiler.jar \
    https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar

echo "→ свежая выгрузка OSM"
curl -sSfL -o uzbekistan.osm.pbf.new https://download.geofabrik.de/asia/uzbekistan-latest.osm.pbf
curl -sSfL -o uzbekistan.osm.pbf.md5 https://download.geofabrik.de/asia/uzbekistan-latest.osm.pbf.md5
sed "s#uzbekistan-latest.osm.pbf#uzbekistan.osm.pbf.new#" uzbekistan.osm.pbf.md5 | md5 -c 2>/dev/null \
    || (sed "s#uzbekistan-latest.osm.pbf#uzbekistan.osm.pbf.new#" uzbekistan.osm.pbf.md5 | md5sum -c -)
mv uzbekistan.osm.pbf.new uzbekistan.osm.pbf

echo "→ Planetiler (схема OpenMapTiles, зумы 0–14)"
# Языки подписей — ровно те, что показывает приложение: русский, узбекский
# (name:uz — подписи узбекской версии; по умолчанию его в наборе нет) и
# английский как запасной. Набор по умолчанию — ~70 языков: каждое имя
# в тайле хранилось семьюдесятью копиями, и это ехало в каждый офлайн-регион.
"$JAVA" -Xmx8g -jar planetiler.jar --osm-path=uzbekistan.osm.pbf --download \
    --languages=ru,uz,en \
    --output=uz.mbtiles --force --maxzoom=14 > planetiler.log 2>&1

echo "→ тайлы и индекс"
rm -rf "$OUT" && mkdir -p "$OUT"
python3 "$HERE/export_mbtiles.py" uz.mbtiles "$OUT"

echo "→ шрифты (три начертания Noto Sans — ровно те, что в стиле) и иконки"
if [ ! -d fonts/"Noto Sans Regular" ]; then
    curl -sSfL -o fonts.zip https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip
    mkdir -p fonts && (cd fonts && unzip -q -o ../fonts.zip)
fi
mkdir -p "$OUT/glyphs"
for face in "Noto Sans Regular" "Noto Sans Bold" "Noto Sans Italic"; do
    cp -R "fonts/$face" "$OUT/glyphs/"
done
cp -R "$HERE/sprite" "$OUT/sprite"

echo "→ стиль"
python3 "$HERE/make_style.py" "$BASE" > "$OUT/style.json"
python3 -m unittest discover -s "$HERE" -p "test_make_style.py" >/dev/null

echo "готово: $OUT ($(du -sh "$OUT" | cut -f1)). Публикует владелец: bash server/omt/publish_omt.sh"
