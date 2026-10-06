#!/bin/bash
# Установка дорожного конвейера на VPS: сборщик, недельный скрипт, cron.
#
#   bash server/install_roads_pipeline.sh          # поставить и проверить
#   bash server/install_roads_pipeline.sh --run    # поставить и сразу прогнать
#
# Публикацию НЕ трогает: подпись живёт на машине владельца, и выкладывает
# тайлы publish_roads.sh. Этот скрипт только ставит то, что готовит кандидата.
#
# До него update_roads.sh на боевой не стоял вовсе, крон-записи не было, а
# build_roads.py там был на 12 865 байт против 138 894 в репозитории — то есть
# «еженедельная пересборка» не была ни еженедельной, ни той сборкой.
set -euo pipefail

HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WORK="${RADARMAP_WORK:-/opt/radarmap/work}"
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN=0
STATUS=0
SWAP=0
REUSE=0
for arg in "$@"; do
    [ "$arg" = "--run" ] && RUN=1
    [ "$arg" = "--status" ] && STATUS=1
    [ "$arg" = "--swap" ] && SWAP=1
    [ "$arg" = "--reuse" ] && REUSE=1
done

SSH=(ssh); SCP=(scp)
if [ -n "${RADARMAP_SSH_KEY:-}" ]; then
    SSH=(ssh -i "$RADARMAP_SSH_KEY"); SCP=(scp -i "$RADARMAP_SSH_KEY")
fi

# Состояние — отдельным режимом и ТОЛЬКО чтением.
#
# Прогон длится десятки минут, и оборванная локальная сессия ничего о нём не
# говорит: скрипт на машине мог и умереть вместе с ssh, и продолжать жить. Без
# ответа на это второй запуск идёт вслепую поверх первого — в один рабочий
# каталог, с одним и тем же файлом экстракта.
if [ "$STATUS" = "1" ]; then
    "${SSH[@]}" "$HOST" "
      # Ищем ЗАПУЩЕННЫЙ скрипт, а не своё же имя.
      #
      # Первая версия спрашивала pgrep -f update_roads.sh и всегда отвечала
      # «работает»: строка с этим именем есть в самой команде проверки, и
      # pgrep честно находил сам себя. Ответ «работает» на мёртвом конвейере
      # опаснее отсутствия ответа — он запрещает перезапуск.
      if flock -n /var/lock/radarmap-roads.lock true 2>/dev/null; then
          echo 'конвейер не запущен'
      else
          echo 'конвейер РАБОТАЕТ'
      fi
      echo '--- кандидат:'
      if [ -f '$WORK/roads_tiles_candidate/index_payload_v2.json' ]; then
          ls -la '$WORK/roads_tiles_candidate' | head -3
          echo -n '    файлов: '; ls '$WORK/roads_tiles_candidate' | wc -l
      else
          echo '    кандидата нет'
      fi
      echo '--- что сейчас работает:'
      date -Is | sed 's/^/    сейчас: /'
      ps -eo pid,etime,rss,args --sort=-rss | grep -E '[c]url|[o]smium|[b]uild_roads' | head -4 | cut -c1-120 | sed 's/^/    /'
      echo '--- дерево MVT в кандидате:'
      if [ -d '$WORK/roads_tiles_candidate/mvt' ]; then
          echo -n '    тайлов: '
          find '$WORK/roads_tiles_candidate/mvt' -name '*.mvt' | wc -l
      else
          echo '    нет — сборка шла без --mvt'
      fi
      echo '--- рабочие файлы:'
      ls -la '$WORK'/*.pbf '$WORK'/*.geojsonl 2>/dev/null | awk '{print \"    \" \$5, \$9}' | tail -8
      echo '--- память:'
      free -m | awk '/^Mem:|^Swap:/ {print \"    \" \$0}'
      echo '--- последние строки лога:'
      tail -25 /var/log/radarmap-roads.log 2>/dev/null || echo '    лога нет'
    "
    exit 0
fi

# Файл подкачки — отдельным ключом и по решению владельца.
#
# Замерено: сборка страны держит 2,0 КБ на дорогу, то есть 1,2–1,4 ГБ на
# 604 522 дороги, а на машине два гигабайта всего и рядом живут API и панель.
# Ядро убило сборку дважды, и оба раза не из-за нового слоя: поверхность
# стоит меньше процента, а дома и адреса уже пишутся потоком.
#
# Подкачка здесь уместна ровно потому, что сборка ночная и разовая: ей
# безразлична задержка диска, а API и панель в это время почти простаивают.
# Снимается одной командой: swapoff /swapfile && rm /swapfile.
if [ "$SWAP" = "1" ]; then
    echo "→ файл подкачки 2 ГБ"
    "${SSH[@]}" "$HOST" "
      set -e
      # Подкачка на машине УЖЕ была — гигабайт, и 424 МБ из неё занято, — а
      # сборку всё равно убило. Значит вопрос не «есть ли», а «сколько».
      # Добавляем ВТОРЫМ файлом: трогать работающий /swapfile под идущей
      # сборкой нельзя, а swapon рядом с ним безопасен.
      have_mb=\$(free -m | awk '/^Swap:/ {print \$2}')
      echo \"    подкачки сейчас: \${have_mb} МБ\"
      if [ \"\${have_mb:-0}\" -ge 3000 ]; then
          echo '    хватает, ничего не добавляем'; swapon --show; exit 0
      fi
      if swapon --show | grep -q /swapfile2; then
          echo '    второй файл уже включён'; swapon --show; exit 0
      fi
      free_gb=\$(df --output=avail -BG /  | tail -1 | tr -dc '0-9')
      if [ \"\$free_gb\" -lt 6 ]; then
          echo \"    СТОП: на диске \$free_gb ГБ — мало под файл подкачки\"; exit 1
      fi
      fallocate -l 2G /swapfile2 || dd if=/dev/zero of=/swapfile2 bs=1M count=2048
      chmod 600 /swapfile2
      mkswap /swapfile2 >/dev/null
      swapon /swapfile2
      grep -q '^/swapfile2' /etc/fstab || echo '/swapfile2 none swap sw 0 0' >> /etc/fstab
      echo '    включено:'; swapon --show
      free -m | head -3
    "
fi

echo "→ 1/5 проверка машины"
"${SSH[@]}" "$HOST" "
  set -e
  mkdir -p '$WORK'
  echo -n '    памяти свободно: '; free -m | awk '/^Mem:/ {print \$7\" МБ\"}'
  echo -n '    места в /opt:    '; df -h /opt | awk 'NR==2 {print \$4}'
  echo -n '    python:          '; python3 -V
  command -v osmium >/dev/null || echo '    ВНИМАНИЕ: osmium не найден — конвейер не соберёт экстракт'
"

echo "→ 2/5 заливка сборщика и недельного скрипта"
"${SCP[@]}" -q "$DIR/build_roads.py" "$HOST:$WORK/build_roads.py.new"
"${SCP[@]}" -q "$DIR/update_roads.sh" "$HOST:/opt/radarmap/update_roads.sh.new"
# Кандидаты нейросети: собираются руками и редко, но живут рядом со сборщиком —
# им нужны те же helper'ы из build_roads.py.
# Кодировщик MVT и раскладка по тайлам: сборщик импортирует их по ключу
# --mvt. Без них прогон падает — и падает ПОСЛЕ всей тяжёлой работы.
"${SCP[@]}" -q "$DIR/mvt.py" "$HOST:$WORK/mvt.py.new"
"${SCP[@]}" -q "$DIR/build_mvt.py" "$HOST:$WORK/build_mvt.py.new"
# Ворота поверхности: build_roads импортирует модуль на старте, без него
# воскресная сборка падает сразу (с 27.09.2026).
"${SCP[@]}" -q "$DIR/surface_check.py" "$HOST:$WORK/surface_check.py.new"
"${SCP[@]}" -q "$DIR/lane_inference.py" "$HOST:$WORK/lane_inference.py.new"
"${SCP[@]}" -q "$DIR/road_metrics.py" "$HOST:$WORK/road_metrics.py.new"
"${SCP[@]}" -q "$DIR/junction_worklist.py" "$HOST:$WORK/junction_worklist.py.new"
"${SCP[@]}" -q "$DIR/ml_candidates.py" "$HOST:$WORK/ml_candidates.py.new"
"${SCP[@]}" -q "$DIR/fetch_candidates.sh" "$HOST:/opt/radarmap/fetch_candidates.sh.new"

echo "→ 3/5 проверка синтаксиса ТОЙ ЖЕ версией python, что на сервере"
# Правило написано кровью: на машине разработчика 3.14, на сервере 3.10, и
# синтаксис, разрешённый с 3.12, проходит локально и падает здесь.
"${SSH[@]}" "$HOST" "
  set -e
  python3 -c \"import ast,sys; ast.parse(open('$WORK/build_roads.py.new').read())\"
  bash -n /opt/radarmap/update_roads.sh.new
  [ -f '$WORK/build_roads.py' ] && cp '$WORK/build_roads.py' '$WORK/build_roads.py.prev' || true
  mv '$WORK/build_roads.py.new' '$WORK/build_roads.py'
  mv /opt/radarmap/update_roads.sh.new /opt/radarmap/update_roads.sh
  chmod +x /opt/radarmap/update_roads.sh
  for extra in mvt build_mvt ml_candidates surface_check lane_inference road_metrics junction_worklist; do
      python3 -c \"import ast; ast.parse(open('$WORK/\$extra.py.new').read())\"
  done
  bash -n /opt/radarmap/fetch_candidates.sh.new
  for extra in mvt build_mvt ml_candidates surface_check lane_inference road_metrics junction_worklist; do
      mv \"$WORK/\$extra.py.new\" \"$WORK/\$extra.py\"
  done
  mv /opt/radarmap/fetch_candidates.sh.new /opt/radarmap/fetch_candidates.sh
  chmod +x /opt/radarmap/fetch_candidates.sh
  echo '    сборщик:' \$(stat -c %s '$WORK/build_roads.py') 'байт'
"

echo "→ 4/5 крон: воскресенье 04:17"
"${SSH[@]}" "$HOST" "
  set -e
  line='17 4 * * 0 /opt/radarmap/update_roads.sh >> /var/log/radarmap-roads.log 2>&1'
  if crontab -l 2>/dev/null | grep -q update_roads.sh; then
      echo '    запись уже стоит'
  else
      (crontab -l 2>/dev/null; echo \"\$line\") | crontab -
      echo '    запись добавлена'
  fi
"

if [ "$RUN" = "1" ]; then
    echo "→ 5/5 прогон конвейера — ОТЦЕПЛЕННО, как у крона"
    # Не в этой ssh-сессии, и это не удобство.
    #
    # Прогон длится десятки минут: качается pbf страны, режутся шесть слоёв,
    # потом сборка идёт ДВАЖДЫ ради проверки детерминизма. Оборвётся канал —
    # оборвётся и работа на середине, а увидеть это будет неоткуда. Крон
    # запускает ровно так же, и лог тот же самый.
    # Наложение двух прогонов сторожит ЗАМОК внутри самого скрипта, а не
    # проверка здесь: строка с его именем есть в командной строке любой такой
    # проверки, и она находит саму себя.
    "${SSH[@]}" "$HOST" "
      nohup setsid env RADARMAP_REUSE_PBF=$REUSE /opt/radarmap/update_roads.sh \
            >> /var/log/radarmap-roads.log 2>&1 &
      sleep 3
      tail -2 /var/log/radarmap-roads.log
    "
    echo "    следить: bash server/install_roads_pipeline.sh --status"
else
    echo "→ 5/5 прогон пропущен"
    echo "    запустить: bash server/install_roads_pipeline.sh --run"
    echo "    или на машине: /opt/radarmap/update_roads.sh"
fi

echo "Готово. Публикует по-прежнему владелец: bash server/publish_roads.sh --auto"
