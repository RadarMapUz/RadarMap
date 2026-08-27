#!/bin/bash
# Кандидаты от нейросети для рабочего города: скачать и разложить.
#
#   bash server/fetch_candidates.sh                 # Ташкент
#   RADARMAP_BBOX=41.2,69.1,41.4,69.4 bash server/fetch_candidates.sh
#
# Запускается РУКАМИ и редко: набор обновляется раз в несколько месяцев, а
# весит десятки мегабайт на город. В недельный конвейер он не входит намеренно
# — там всё, что едет на телефоны, а кандидат на телефон не едет никогда.
#
# Что это. Microsoft выложил контуры зданий, распознанные по спутнику,
# специально для картографов; лицензия совместима с OSM. Панель показывает их
# КАНДИДАТАМИ: модератор щёлкает — контур становится обычной правкой и
# проходит ту же проверку, что нарисованное мышью.
set -euo pipefail

WORK="${RADARMAP_WORK:-/opt/radarmap/work}"
TILES="${RADARMAP_TILES:-$WORK/roads_tiles}"
BBOX="${RADARMAP_BBOX:-41.20,69.10,41.42,69.45}"
INDEX="https://minedbuildings.z5.web.core.windows.net/global-buildings/dataset-links.csv"
DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$WORK"
echo "=== $(date -Is) кандидаты нейросети, рамка $BBOX ==="

echo "--- 1/3: какие квадраты нужны"
curl -sSfL --max-time 300 -o dataset-links.csv "$INDEX"
mapfile -t URLS < <(python3 - "$BBOX" <<'PY'
import csv, math, sys
south, west, north, east = [float(x) for x in sys.argv[1].split(",")]

def quadkey(lat, lon, zoom=9):
    sin = math.sin(math.radians(lat))
    x = int(((lon + 180) / 360) * (1 << zoom))
    y = int((0.5 - math.log((1 + sin) / (1 - sin)) / (4 * math.pi)) * (1 << zoom))
    out = ""
    for i in range(zoom, 0, -1):
        digit, mask = 0, 1 << (i - 1)
        if x & mask:
            digit += 1
        if y & mask:
            digit += 2
        out += str(digit)
    return out

# Углы рамки и её середины: квадрат зума 9 — это около 80 км, и рамка города
# задевает от одного до четырёх.
wanted = {quadkey(lat, lon)
          for lat in (south, (south + north) / 2, north)
          for lon in (west, (west + east) / 2, east)}
for row in csv.DictReader(open("dataset-links.csv")):
    if row["QuadKey"] in wanted:
        print(row["Url"])
PY
)
echo "    квадратов: ${#URLS[@]}"
[ "${#URLS[@]}" -gt 0 ] || { echo "СТОП: набор не покрывает эту рамку"; exit 1; }

echo "--- 2/3: закачка"
rm -rf _cand && mkdir -p _cand
n=0
for url in "${URLS[@]}"; do
    n=$((n + 1))
    curl -sSfL --max-time 1800 -o "_cand/part-$n.csv.gz" "$url"
    echo "    $n: $(stat -c %s "_cand/part-$n.csv.gz") байт"
done

echo "--- 3/3: раскладка"
# Сверяем с ЭКСТРАКТОМ ЗДАНИЙ OSM: предлагать то, что уже обведено, — значит
# заставлять модератора разбирать кучу, на три четверти состоящую из готового.
# Замерено на центре Ташкента: из 4 914 контуров нейросети сверка убирает 78%.
HOUSES=""
[ -s houses.geojsonl ] && HOUSES="--houses houses.geojsonl"
for part in _cand/part-*.csv.gz; do
    python3 "$WORK/ml_candidates.py" --in "$part" --tiles "$TILES" \
        $HOUSES --bbox "$BBOX"
done
rm -rf _cand
echo "Готово. В панели: клавиша C."
