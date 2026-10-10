#!/usr/bin/env python3
"""Подписываемый индекс лимитов скорости — payload для speed_limits_index.json.

ЗАЧЕМ. Лимиты говорят голосом («Превышение скорости») и считают суммы штрафов
в Итогах — по классу доверия это те же данные, что база камер и пульт. Но они
одни ехали на телефон без подписи: файл пишет крон на VPS
(extract_speed_limits.py), и приложение верило любым байтам по этому адресу.
Тот, кто получил доступ к серверу, мог выставить «20» на всех трассах — сирену
у каждой камеры и минус рейтинг каждому водителю, — и телефон бы это принял.

УСТРОЙСТВО — как у дорожных тайлов (build_roads.py → publish_roads.sh).
Подписывается не файл в 3,4 МБ, а маленький индекс с sha256 и размером каждого
файла. Подпись ставит ВЛАДЕЛЕЦ у себя (publish_limits.sh), ключ на VPS не
попадает никогда; файл, не сошедшийся с индексом по хэшу или размеру, телефон
отбрасывает. Одна подпись на весь набор.

ИМЕНА С ХЭШЕМ, а не те, что пишет крон. Крон раз в месяц ПЕРЕПИСЫВАЕТ
speed_limits*.json на месте — подпись под ними разошлась бы с файлом в ту же
минуту, и свежая установка осталась бы вовсе без лимитов до следующей подписи.
Поэтому подписанный набор — копии в limits/ с sha в имени: содержимое по такому
адресу не меняется никогда, а старые адреса живут дальше для установленных
сборок, которые о подписи не знают.

ЧЕГО ПОДПИСЬ НЕ ДАЁТ. Данные по-прежнему собирает VPS, и если он взломан ДО
подписи, владелец подпишет подделку — ровно как у дорог. Поэтому здесь же
ворота: файл, не похожий на сборку extract_speed_limits.py, не подписывается.
Подпись гарантирует другое: телефон получит ровно то, что владелец проверил,
и никто после — ни сервер, ни кэш, ни сеть — это не подменит.

Скрипт ничего не подписывает и никуда не ходит: проверяет файлы, кладёт копии
под именами с хэшем и пишет payload. Логика — в build_payload(), покрыта
test_build_limits_index.py.

    python3 build_limits_index.py --v1 speed_limits.json --v2 speed_limits_v2.json --out stage/
"""
import argparse
import hashlib
import json
import os
import sys
import time

from extract_speed_limits import MIN_SEGMENTS

# Формат САМОГО индекса — контракт с LimitsManifest (RadarMap/Models/LimitsManifest.swift).
# Клиент отвергает индекс чужого формата целиком, а не угадывает поля.
INDEX_FORMAT = 1

# Каталог подписанных копий в вебруте. Отдельный от файлов крона намеренно:
# сюда пишет только publish_limits.sh, и чистить его можно, не задевая того,
# что читают старые сборки.
PUBLISHED_DIR = "limits"

# Формат файла лимитов → базовое имя (как его пишет extract_speed_limits.py).
# 1 — [limit, [lat,lon,…]], 2 — [limit, cls, [lat,lon,…]] плюс "format": 2.
BASENAMES = {1: "speed_limits", 2: "speed_limits_v2"}

# Сколько hex-знаков sha в имени. 64 бита: совпасть случайно они не могут, а
# имя остаётся читаемым в логах nginx.
NAME_SHA_CHARS = 16


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def published_name(fmt, sha):
    """Путь подписанной копии относительно вебрута: limits/<база>.<sha16>.json."""
    return "%s/%s.%s.json" % (PUBLISHED_DIR, BASENAMES[fmt], sha[:NAME_SHA_CHARS])


def _is_number(value):
    # bool в Python — подкласс int, а true вместо координаты — это мусор.
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def check_limits_file(data, fmt, min_segments=MIN_SEGMENTS):
    """Разобрать файл лимитов и проверить, что он похож на сборку крона.

    Возвращает разобранный документ; на любой неисправности — ValueError с
    причиной. Проверка строгая и по ВСЕМ сегментам: телефон отбрасывает
    отдельный битый сегмент молча, но подписывать заведомо битый файл —
    значит выдать порчу за решение владельца.
    """
    try:
        doc = json.loads(data)
    except ValueError as error:
        raise ValueError("формат %d: не JSON (%s)" % (fmt, error))
    if not isinstance(doc, dict) or not isinstance(doc.get("segments"), list):
        raise ValueError("формат %d: нет списка segments" % fmt)
    version = doc.get("version")
    if not isinstance(version, int) or isinstance(version, bool) or version <= 0:
        raise ValueError("формат %d: нет версии сборки" % fmt)
    if fmt == 2 and doc.get("format") != 2:
        raise ValueError("формат 2: в файле не стоит \"format\": 2 — перепутаны файлы?")
    if fmt == 1 and "format" in doc:
        raise ValueError("формат 1: в файле стоит \"format\" — перепутаны файлы?")

    width = 2 if fmt == 1 else 3
    for position, entry in enumerate(doc["segments"]):
        if not isinstance(entry, list) or len(entry) != width:
            raise ValueError("формат %d: сегмент %d не из %d полей" % (fmt, position, width))
        limit, flat = entry[0], entry[-1]
        if not isinstance(limit, int) or isinstance(limit, bool):
            raise ValueError("формат %d: сегмент %d — лимит не целое" % (fmt, position))
        if fmt == 2 and (not isinstance(entry[1], int) or isinstance(entry[1], bool)):
            raise ValueError("формат 2: сегмент %d — класс дороги не целое" % position)
        if (not isinstance(flat, list) or len(flat) < 4 or len(flat) % 2
                or not all(_is_number(value) for value in flat)):
            raise ValueError("формат %d: сегмент %d — геометрия битая" % (fmt, position))

    count = len(doc["segments"])
    if count < min_segments:
        raise ValueError("формат %d: сегментов всего %d — выгрузка обрезана" % (fmt, count))
    return doc


def check_consistent(legacy, modern):
    """v1 обязан быть ровно v2 без класса дороги.

    Крон пишет их по очереди (extract_speed_limits.write_published): забрать
    файлы посреди прогона — значит получить новый v1 рядом со старым v2.
    Подписать такую пару — дать разным сборкам разные лимиты на одной дороге.
    """
    if legacy["version"] != modern["version"]:
        raise ValueError("v1 и v2 разных сборок (%s и %s) — крон писал файлы во время забора"
                         % (legacy["version"], modern["version"]))
    if len(legacy["segments"]) != len(modern["segments"]):
        raise ValueError("v1 и v2 разной длины (%d и %d)"
                         % (len(legacy["segments"]), len(modern["segments"])))
    for position, (old, new) in enumerate(zip(legacy["segments"], modern["segments"])):
        if old != [new[0], new[2]]:
            raise ValueError("v1 и v2 расходятся в сегменте %d" % position)


def build_payload(files, built=None, min_segments=MIN_SEGMENTS):
    """Индекс набора: {формат: байты файла} → payload (dict).

    Чистая функция: никакой сети и диска. Файлы перечислены от нового формата
    к старому — клиент берёт самый новый из понятных ему, и порядок здесь
    лишь облегчает чтение глазами.
    """
    if not files:
        raise ValueError("нет ни одного файла лимитов")
    unknown = sorted(set(files) - set(BASENAMES))
    if unknown:
        raise ValueError("неизвестные форматы: %s" % unknown)

    docs = {fmt: check_limits_file(data, fmt, min_segments) for fmt, data in files.items()}
    if 1 in docs and 2 in docs:
        check_consistent(docs[1], docs[2])
    versions = {doc["version"] for doc in docs.values()}
    if len(versions) != 1:
        raise ValueError("файлы разных сборок: %s" % sorted(versions))

    entries = []
    for fmt in sorted(files, reverse=True):
        data = files[fmt]
        sha = sha256_hex(data)
        entries.append({
            "format": fmt,
            "name": published_name(fmt, sha),
            "sha256": sha,
            "bytes": len(data),
            "segments": len(docs[fmt]["segments"]),
        })
    return {
        "format": INDEX_FORMAT,
        "version": versions.pop(),
        "built": int(time.time()) if built is None else built,
        "files": entries,
    }


def encode_payload(payload):
    """Байты, которые подписываются. Детерминированно: одинаковый набор —
    одинаковая подпись, и повторная публикация видна как «ничего не сменилось»."""
    return json.dumps(payload, separators=(",", ":"), sort_keys=True,
                      ensure_ascii=False).encode("utf-8")


def write_stage(out_dir, files, payload):
    """Копии под именами с хэшем + index_payload.json — то, что поедет на VPS."""
    by_format = {entry["format"]: entry for entry in payload["files"]}
    for fmt, data in files.items():
        target = os.path.join(out_dir, by_format[fmt]["name"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(data)
    with open(os.path.join(out_dir, "index_payload.json"), "wb") as handle:
        handle.write(encode_payload(payload))


def main(argv=None):
    parser = argparse.ArgumentParser(description="payload подписанного индекса лимитов")
    parser.add_argument("--v1", help="speed_limits.json (формат 1)")
    parser.add_argument("--v2", help="speed_limits_v2.json (формат 2)")
    parser.add_argument("--out", required=True, help="каталог для копий и index_payload.json")
    args = parser.parse_args(argv)

    files = {}
    for fmt, path in ((1, args.v1), (2, args.v2)):
        if path:
            with open(path, "rb") as handle:
                files[fmt] = handle.read()
    try:
        payload = build_payload(files)
    except ValueError as error:
        print("НЕ ПОДПИСЫВАТЬ: %s" % error)
        return 1
    write_stage(args.out, files, payload)
    built_at = time.strftime("%Y-%m-%d %H:%M", time.localtime(payload["version"]))
    print("сборка лимитов от %s" % built_at)
    for entry in payload["files"]:
        print("  формат %d: %s — %d сегментов, %d КиБ" % (
            entry["format"], entry["name"], entry["segments"], entry["bytes"] // 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
