#!/usr/bin/env python3
"""Очередь изменений OSM: что делать с правками, когда база пересобралась.

Раздел, ради которого стоит городить конструктор. База пересобирается из
свежего экстракта каждое воскресенье, и правка, посаженная на дорогу, которой
больше нет, — это не мелочь в логе: на схеме она окажется в поле, и водитель
увидит разворот там, где его нет.

ГРАНИЦА ПРОВЕДЕНА ПО ОДНОМУ ПРИЗНАКУ: автоматика вправе ДВИГАТЬ объект, но не
вправе решать, что он больше не нужен. Сдвиг на два метра она чинит сама.
Дорога исчезла — спрашивает.

ПЕРЕСАЖИВАЕМ ОТ raw, А НЕ ОТ ПРОШЛОЙ ПОСАДКИ. Это не тонкость: посадка от
посадки накапливает ошибку, и объект уползает понемногу каждую неделю, оставаясь
каждый раз «в пределах трёх метров». От исходного намерения человека он не уползает
никогда.
"""
import map_edits

# Что решила автоматика.
KEEP = "keep"              # отпечаток сошёлся — вокруг ничего не изменилось
RESETTLED = "resettled"    # подвинули сами, молча
CHECK = "check"            # подвинули, но пусть человек посмотрит
LOST = "lost"              # опоры не стало — в очередь, с публикации снять
CAUGHT_UP = "caught_up"    # OSM догнал нашу нарисованную дорогу

# Пороги. Числа из §9.2 плана.
#
# Три метра — это ширина обочины: сдвиг такого размера не меняет ни того, на
# какой ты полосе, ни того, с какой стороны перекрёстка стоит светофор.
SILENT_METERS = 3.0
# Пятнадцать — половина проспекта. Дальше объект уже может оказаться на другой
# проезжей части, и это решает человек.
CHECK_METERS = 15.0
# Ближе двадцати метров к нашей нарисованной дороге появилась настоящая —
# значит OSM нас догнал.
CAUGHT_UP_METERS = 20.0


def reconcile(edit, roads):
    """Что делать с одной правкой после пересборки → (решение, точка, сдвиг).

    Точка — куда пересадить; None означает «не двигаем».
    """
    raw = edit.get("raw") or []
    if len(raw) < 2:
        return LOST, None, 0.0
    origin = (float(raw[0]), float(raw[1]))

    # Отпечаток сошёлся — вокруг ничего не изменилось, правка едет молча.
    # Проверяем ПЕРВЫМ: это самый частый случай, и он не стоит ни одной посадки.
    if edit.get("fingerprint") and \
            edit["fingerprint"] == map_edits.fingerprint(origin, roads):
        return KEEP, None, 0.0

    result = map_edits.snap(origin, roads)
    if not result.on_road:
        # Сюда попадает и случай «стало неоднозначно»: там, где раньше была
        # одна дорога, теперь две в трёх метрах. Двигать вслепую нельзя — это
        # ровно тот проспект с дублёром, ради которого магнит и не гадает.
        return LOST, None, 0.0

    old = edit.get("geom") or raw
    shift = map_edits.meters_between((float(old[0]), float(old[1])), result.point)
    if shift <= SILENT_METERS:
        return RESETTLED, list(result.point), shift
    if shift <= CHECK_METERS:
        return CHECK, list(result.point), shift
    return LOST, None, shift


def caught_up(edit, roads, meters=CAUGHT_UP_METERS):
    """Догнал ли OSM нашу нарисованную дорогу.

    Своя геометрия живёт, пока OSM её не догнал, и панель обязана сказать,
    когда это случилось: дорога, отданная в OSM, поддерживается всем миром, а
    наша — только нами.
    """
    if edit.get("kind") != "geometry":
        return False
    geom = edit.get("geom") or []
    points = geom if isinstance(geom[0], (list, tuple)) else [geom]
    for point in points:
        origin = (float(point[0]), float(point[1]))
        for road in roads:
            line = road.get("points") or []
            if len(line) < 2:
                continue
            if map_edits.nearest_on(origin, line)[2] <= meters:
                return True
    return False


def sweep(conn, roads=None, tiles_dir=None):
    """Прогнать ВСЕ действующие правки по новой сети → список решений.

    Ничего не применяет сам: возвращает, что нашёл. Применение — отдельным
    шагом, потому что снятие с публикации это решение, а не следствие.

    Дороги берутся ВОКРУГ КАЖДОЙ ПРАВКИ, а не разом по всей земле. Правка
    держится за место, и всё, что дальше двухсот метров, к ней отношения не
    имеет — а стоит его чтение всей памяти панели: на боевом «сверь все
    правки» открывало 210 файлов и упирало сервис в MemoryMax, после чего он
    переставал отвечать вовсе.

    Готовый список дорог (roads) остаётся ради тестов и ради вызова, у которого
    сеть уже в руках, — например из сборки тайлов.
    """
    out = []
    for edit in map_edits.export_accepted(conn):
        near = roads
        if near is None:
            raw = edit.get("raw") or edit.get("geom") or []
            if len(raw) < 2:
                out.append({"edit": edit, "verdict": LOST, "point": None,
                            "shift": 0.0})
                continue
            near = map_edits.roads_near(tiles_dir, (raw[0], raw[1]))
        if caught_up(edit, near):
            out.append({"edit": edit, "verdict": CAUGHT_UP, "point": None,
                        "shift": 0.0})
            continue
        verdict, point, shift = reconcile(edit, near)
        out.append({"edit": edit, "verdict": verdict, "point": point,
                    "shift": round(shift, 1)})
    return out


def apply_sweep(conn, decisions):
    """Применить то, на что автоматика имеет право → (подвинуто, в очередь).

    Двигает молча только RESETTLED и CHECK. LOST не снимает с публикации сам:
    он лишь помечает правку — снимает её человек одним кликом. Автоматика
    вправе двигать объект, но не вправе решать, что он больше не нужен.
    """
    moved, queued = 0, 0
    for decision in decisions:
        edit = decision["edit"]
        if decision["verdict"] in (RESETTLED, CHECK) and decision["point"]:
            note = edit.get("note") or ""
            if decision["verdict"] == CHECK:
                mark = f"{map_edits.CHECK_MARK}: сдвиг {decision['shift']} м"
                note = f"{note} · {mark}".strip(" ·") if mark not in note else note
            if map_edits.update(conn, edit["id"], edit["version"],
                                geom=decision["point"], note=note):
                moved += 1
        elif decision["verdict"] in (LOST, CAUGHT_UP):
            queued += 1
    return moved, queued


def marked(edits):
    """Правки, помеченные автоматикой и ждущие человека.

    Считается по ЗАМЕТКЕ, а не по вердикту свежей сверки: метку поставила
    пересадка, а следующая неделя может не найти сдвига вовсе — и правка
    молча исчезла бы из очереди, так и оставшись непроверенной.
    """
    return [e for e in edits if map_edits.CHECK_MARK in (e.get("note") or "")]


def summary(decisions):
    """Сводка по вердиктам — для страницы «Что изменилось» и для лога сборки."""
    counts = {}
    for decision in decisions:
        counts[decision["verdict"]] = counts.get(decision["verdict"], 0) + 1
    return counts
