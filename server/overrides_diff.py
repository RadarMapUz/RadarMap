#!/usr/bin/env python3
"""Что именно владелец подписывает в publish_overrides.sh.

Payload правок собирает панель на VPS (`admin.py --export`), а подпись
ставится на маке. Если показывать перед подписью только «правок: N», взломанный
сервер или ошибка в панели проходят под подписью владельца (аудит 38B, H-2):
сто скрытий и переносы на параллельную улицу выглядят как обычная выкладка.
Поэтому перед подписью — разница с ПРОШЛОЙ ПОДПИСАННОЙ публикацией по каждой
камере (адрес из локальной базы, было → стало) и те же пределы, что у
приложения (`bot_near.overrides_sane` — копия `CameraOverrideEngine.isSane`,
сверяется тестом с AppConfig).

Прошлая публикация берётся только подписанной нашим ключом: сохранённая
локально после прошлой выкладки и/или скачанная с сервера. Неподписанной не
верим — разница считается от пустого файла, то есть показывается всё.

Подписывается не то, что прислал сервер, а пересборка разобранного
(`--canonical`): показанное человеку и подписанное — одни и те же байты.

Запуск:
  python3 overrides_diff.py --new payload.json --cameras cameras.json \\
      [--prev envelope.json ...] [--expect-version N] [--canonical out.json]
Код 0 — можно подписывать (после «да» человека), 1 — нельзя.
"""
import argparse
import json
import sys

import bot_near

OP_TITLES = {"hide": "скрыта", "move": "перенесена", "retype": "тип сменён"}


#: Целые на телефоне — Int (64 бита): больше — JSONDecoder не разберёт файл.
INT64 = 2 ** 63


def _unique(pairs):
    # Python берёт ПОСЛЕДНИЙ из повторённых ключей, JSONDecoder телефона —
    # ПЕРВЫЙ: `{"items": [скрытия], "items": []}` показал бы человеку пустую
    # разницу, а телефон применил бы скрытия. Повтор — не по контракту.
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("повтор ключа")
    return dict(pairs)


def _finite(text):
    value = float(text)
    if value != value or value in (float("inf"), float("-inf")):
        raise ValueError("число вне double")
    return value


def _no_constant(name):
    raise ValueError(f"{name} — не JSON для телефона")


def strict_loads(raw):
    """JSON так, как его прочтёт телефон, или ValueError: без повторов ключей
    на любом уровне, без NaN/Infinity и чисел, которые double не вмещает."""
    return json.loads(raw, object_pairs_hook=_unique, parse_float=_finite,
                      parse_constant=_no_constant)


def parse_payload(raw):
    """(version, items, updatedAt) или None — файл не по контракту приложения."""
    try:
        data = strict_loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    items = bot_near.parse_overrides(json.dumps(data))
    if items is None:
        return None
    if not -INT64 <= data["version"] < INT64 or any(not -INT64 <= item["id"] < INT64 for item in items):
        return None
    updated = data.get("updatedAt")
    if updated is not None and not isinstance(updated, str):
        return None
    # Только поля, которые читает телефон: чего нет в CameraOverride, того
    # нет ни в разнице, ни в подписи.
    items = [{key: item[key] for key in ("id", "op", "lat", "lon", "type") if item.get(key) is not None}
             for item in items]
    return data["version"], items, updated


def canonical(version, items, updated=None):
    """Байты, которые подписываются: пересборка ровно того, что разобрано и
    показано человеку, а не байты с сервера (в них могло быть что-то, что
    телефон прочтёт иначе). Только поля CameraOverrides."""
    rows = []
    for item in items:
        row = {"id": item["id"], "op": item["op"]}
        for key in ("lat", "lon", "type"):
            if item.get(key) is not None:
                row[key] = item[key]
        rows.append(row)
    data = {"version": version}
    if updated is not None:
        data["updatedAt"] = updated
    data["items"] = rows
    return json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def verified_previous(envelopes, verify=None):
    """Самая свежая прошлая публикация, подпись которой сошлась нашим ключом:
    (version, items, предупреждения). Нет ни одной — (0, [], предупреждения):
    разница считается от пустого файла и показывает всё."""
    import base64
    import status
    verify = verify or status.verify_ed25519
    best, notes = None, []
    for name, body in envelopes:
        try:
            envelope = json.loads(body)
            payload = base64.b64decode(envelope["payload"])
            sig = envelope["sig"]
        except (ValueError, KeyError, TypeError):
            notes.append(f"{name}: конверт не читается — не учитываю")
            continue
        verdict = verify(payload, sig)
        if verdict is not True:
            why = "проверить подпись нечем (нужен openssl с Ed25519)" if verdict is None \
                else "подпись не сходится с ключом приложения"
            notes.append(f"{name}: {why} — не учитываю")
            continue
        parsed = parse_payload(payload)
        if parsed is None:
            notes.append(f"{name}: подписан, но не по контракту — не учитываю")
            continue
        if best is None or parsed[0] > best[0]:
            best = parsed[:2]
    if best is None:
        notes.append("прошлой подписанной публикации нет — показываю все правки как новые")
        return 0, [], notes
    return best[0], best[1], notes


def _by_id(items):
    # Как в приложении: последняя строка для id побеждает.
    return {item["id"]: item for item in items}


def diff(prev_items, new_items):
    """Разница двух снимков по камерам: список (id, было, стало), где было/стало —
    строка правки или None (камера как в базе). Отсортирован по id."""
    prev, new = _by_id(prev_items), _by_id(new_items)
    changes = []
    for cid in sorted(set(prev) | set(new)):
        before, after = prev.get(cid), new.get(cid)
        if _same(before, after):
            continue
        changes.append((cid, before, after))
    return changes


def _same(a, b):
    if a is None or b is None:
        return a is b
    keys = ("op", "lat", "lon", "type")
    return all(a.get(k) == b.get(k) for k in keys)


def counts(items):
    by_id = _by_id(items)
    return {op: sum(1 for item in by_id.values() if item["op"] == op) for op in OP_TITLES}


def _state(item, camera):
    if item is None:
        return "как в базе"
    if item["op"] == "hide":
        return "СКРЫТА"
    if item["op"] == "retype":
        old = camera.get("type") if camera else "?"
        return f"тип {old} → {item.get('type')}"
    lat, lon = item.get("lat"), item.get("lon")
    if camera and bot_near._number(lat) and bot_near._number(lon):
        meters = bot_near.fast_distance(camera["lat"], camera["lon"], lat, lon)
        return f"ПЕРЕНЕСЕНА на {meters:.0f} м ({lat:.6f}, {lon:.6f})"
    return f"ПЕРЕНЕСЕНА ({lat}, {lon})"


def _address(camera):
    if not camera:
        return "нет в локальной базе"
    parts = [camera.get("city") or camera.get("region") or "", camera.get("location") or ""]
    return ", ".join(p for p in parts if p) + f" [{camera.get('type', '?')}]"


def render(changes, prev_items, new_items, cameras):
    """Строки отчёта для человека: по камере «было → стало» и счётчики."""
    lines = []
    for cid, before, after in changes:
        camera = cameras.get(cid)
        lines.append(f"  #{cid} {_address(camera)}")
        lines.append(f"      было: {_state(before, camera)}")
        lines.append(f"     стало: {_state(after, camera)}")
    if not changes:
        lines.append("  изменений относительно прошлой публикации нет")
    was, now = counts(prev_items), counts(new_items)
    lines.append("")
    for op, title in OP_TITLES.items():
        lines.append(f"  {title}: было {was[op]} → стало {now[op]}")
    new_silent = sum(1 for _, _, after in changes if after is not None and after["op"] in ("hide", "move"))
    lines.append(f"  новых скрытий и переносов в этой выкладке: {new_silent}")
    return lines


def problems(version, items, prev_version, cameras):
    """Почему подписывать нельзя (пустой список — можно). Те же пределы, что у
    телефона: подписанный файл, который телефоны отвергнут, хуже неподписанного
    — решения модератора молча не применятся нигде. Камера, которой нет в
    локальной базе, — не преграда (телефон такую строку просто не найдёт), её
    показывает `render`."""
    found = []
    if version < prev_version:
        found.append(f"версия {version} меньше опубликованной {prev_version} — телефоны примут её за откат")
    for item in items:
        if item["op"] == "move" and not (
                bot_near._number(item.get("lat")) and bot_near._number(item.get("lon"))
                and bot_near.UZ_LAT_RANGE[0] <= item["lat"] <= bot_near.UZ_LAT_RANGE[1]
                and bot_near.UZ_LON_RANGE[0] <= item["lon"] <= bot_near.UZ_LON_RANGE[1]):
            found.append(f"координата переноса вне Узбекистана у камеры {item['id']}")
        if item["op"] == "retype" and not item.get("type"):
            found.append(f"пустой тип у камеры {item['id']}")
        if item["id"] in cameras and item["op"] == "move" and bot_near._number(item.get("lat")) and bot_near._number(item.get("lon")):
            camera = cameras[item["id"]]
            if bot_near.fast_distance(camera["lat"], camera["lon"], item["lat"], item["lon"]) \
                    > bot_near.OVERRIDE_MAX_MOVE_METERS:
                found.append(f"перенос камеры {item['id']} дальше "
                             f"{bot_near.OVERRIDE_MAX_MOVE_METERS:.0f} м — телефоны его отбросят")
    if not bot_near.overrides_sane(items, len(cameras)):
        found.append(
            f"скрытий и переносов больше {bot_near.OVERRIDE_MAX_HIDDEN_SHARE:.0%} базы "
            f"или переносов больше {bot_near.OVERRIDE_MAX_MOVED_SHARE:.0%} — "
            "приложение отвергнет файл целиком")
    return found


def load_cameras(path):
    with open(path, encoding="utf-8") as handle:
        return {row["id"]: row for row in json.load(handle)}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--new", required=True, help="payload, собранный панелью")
    parser.add_argument("--cameras", required=True, help="локальная база (RadarMap/Resources/cameras.json)")
    parser.add_argument("--prev", action="append", default=[], help="подписанный конверт прошлой публикации")
    parser.add_argument("--expect-version", type=int, help="версия, которую назвал человек")
    parser.add_argument("--canonical", help="куда записать байты для подписи")
    args = parser.parse_args(argv)

    with open(args.new, "rb") as handle:
        parsed = parse_payload(handle.read())
    if parsed is None:
        print("payload не по контракту приложения (повтор ключа, NaN, число вне Int64…) — не подписываю")
        return 1
    version, items, updated = parsed
    if args.expect_version is not None and version != args.expect_version:
        # Вопрос «Подписать vN?» должен быть про то, что подписывается: v2^62
        # с сервера подняла бы храповик телефонов, и следующую честную
        # выкладку они отвергли бы как откат.
        print(f"✗ в файле версия {version}, а публикуется v{args.expect_version} — не подписываю")
        return 1
    envelopes = []
    for path in args.prev:
        try:
            with open(path, "rb") as handle:
                envelopes.append((path, handle.read()))
        except OSError as error:
            print(f"{path}: не читается ({error.strerror}) — не учитываю")
    prev_version, prev_items, notes = verified_previous(envelopes)
    cameras = load_cameras(args.cameras)

    for note in notes:
        print(f"! {note}")
    print(f"Правки v{version} против опубликованной v{prev_version} (база: {len(cameras)} камер):")
    for line in render(diff(prev_items, items), prev_items, items, cameras):
        print(line)
    found = problems(version, items, prev_version, cameras)
    for problem in found:
        print(f"✗ {problem}")
    if found:
        return 1
    if args.canonical:
        with open(args.canonical, "wb") as handle:
            handle.write(canonical(version, items, updated))
    return 0


if __name__ == "__main__":
    sys.exit(main())
