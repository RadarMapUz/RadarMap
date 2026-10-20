#!/bin/zsh
# Учения призрака дороги на работу в симуляторе (план 19.10, 8.8.9, ворота В5).
#
# Три прогона дом→работа по прямой из демо-истории: «как обычно» (14 м/с),
# «пробка посередине» (35–55 % пути на 4 м/с) и «другой дорогой» (крюк
# ~800 м в сторону). Журнал прогноза призрака (info, без координат) — в
# <out>/<прогон>.log, снимки экрана раз в минуту.
#
#   tools/ghost_drill/ghost_drill.sh <UDID симулятора> <путь к RadarMap.app> [папка вывода]
#
# Приложение — DEBUG-сборка: ключи `-demoCommutes -ghostDrill` подкладывают
# демо-«дорогу» и профиль под скорость симулятора, `radarmap://end-trip`
# (только DEBUG) закрывает поездку между прогонами.
#
# Ловушка: `simctl location start` между двумя далёкими точками ведёт не по
# прямой (курс уходит на ~6°, к 800 м машина в 86 м от линии), и призрак
# честно говорит «сегодня другой дорогой». Поэтому путь — путевыми точками
# через ~100 м (waypoints.py). Ещё: на точках simctl теряет скорость, и
# «14 м/с» на деле ~12,5 — отклонение растёт на ~7 с в минуту, это не ошибка.
set -e
U=${1:?UDID симулятора}
APP=${2:?путь к RadarMap.app}
OUT=${3:-$(mktemp -d)}
HERE=${0:A:h}
H=(41.2930 69.2150); W=(41.3285 69.3010); D=(41.31705 69.25338)
mkdir -p $OUT
xcrun simctl install $U $APP

shots() { local n=0; local end=$(( $(date +%s) + $2 )); while [ $(date +%s) -lt $end ]; do sleep 60; n=$((n+1)); xcrun simctl io $U screenshot $OUT/$1_$n.png >/dev/null 2>&1; done }
begin() {
  xcrun simctl openurl $U radarmap://end-trip || true; sleep 2
  xcrun simctl location $U clear
  xcrun simctl location $U set $H[1],$H[2]
  xcrun simctl spawn $U log stream --level info --style compact --predicate 'subsystem == "uz.radarmap.ios" AND eventMessage CONTAINS "призрак"' > $OUT/$1.log 2>&1 &
  LOGPID=$!
  xcrun simctl launch --terminate-running-process $U uz.radarmap.ios -demoCommutes -ghostDrill >/dev/null
  # Посев учений ждёт чтения истории с диска: поездка, начатая раньше, взяла
  # бы профиль с диска («мало поездок этого часа»).
  sleep 30
  xcrun simctl openurl $U radarmap://start-trip
  sleep 4
}
finish() {
  sleep 20
  xcrun simctl io $U screenshot $OUT/$1_end.png >/dev/null 2>&1
  xcrun simctl openurl $U radarmap://end-trip || true
  sleep 5
  kill $LOGPID 2>/dev/null || true
  xcrun simctl location $U clear
  echo "$1 — готово $(date +%T)"
}
drive() { # скорость доля_от доля_до — по прямой дом→работа
  python3 $HERE/waypoints.py $H[1] $H[2] $W[1] $W[2] $2 $3 | xcrun simctl location $U start --speed=$1 --interval=1 -
}

begin usual; drive 14 0 1; shots usual 600; finish usual
begin jam; drive 14 0 0.35; sleep 206; drive 4 0.35 0.55; shots jam 412; drive 14 0.55 1; shots jam_b 265; finish jam
begin detour
{ python3 $HERE/waypoints.py $H[1] $H[2] $D[1] $D[2]; python3 $HERE/waypoints.py $D[1] $D[2] $W[1] $W[2] 0.01 1; } \
  | xcrun simctl location $U start --speed=14 --interval=1 -
shots detour 700; finish detour
echo "Журналы и снимки: $OUT"
