#!/usr/bin/env python3
"""Проверка папки записей диктора (этап 16.2).

    python3 validate.py recordings/            # сценарий script_uz.csv рядом
    python3 validate.py recordings/ --script script_uz.csv

Ловит то, из-за чего склейка зазвучит плохо или не зазвучит вовсе:
нет файла или лишний файл, не тот формат (нужен WAV 48 кГц / 24 бит / моно),
клиппинг и пик без запаса, громкость мимо −16 LUFS, тишина по краям больше
50 мс, подозрительная длина. Код выхода 1 — есть ошибки; предупреждения
читать глазами.

Только стандартная библиотека.
"""

import argparse
import csv
import os
import re
import sys

import kit_audio

RATE = 48000
WIDTH = 3                 # 24 бит
TARGET_LUFS = -16.0
LUFS_ERROR = 3.0          # дальше — ошибка (отрывки зазвучат разной громкостью)
LUFS_WARNING = 1.5        # дальше — предупреждение (сборка выровняет)
PEAK_MAX_DB = -1.0        # пик выше — мало запаса под AAC
EDGE_MAX = 0.050          # тишина по краям, с
EDGE_MIN = 0.003          # меньше — похоже, обрезано начало звука
MIN_SECONDS = 0.15
MAX_SECONDS = 6.0
SILENCE_DB = -50.0
ID_PATTERN = re.compile(r"^[a-z0-9._]+$")


class Issue:
    def __init__(self, segment, level, message):
        self.segment, self.level, self.message = segment, level, message

    def __repr__(self):
        return "%s %s: %s" % (self.level, self.segment, self.message)


def read_script(path):
    """Сценарий: список строк {id, text, example, position, note}."""
    with open(path, encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    for row in rows:
        if not ID_PATTERN.match(row.get("id", "")):
            raise ValueError("плохой id в сценарии: %r" % row.get("id"))
    return rows


def expected_seconds(text):
    """Грубая оценка длины по буквам: ~13 букв в секунду спокойной речи."""
    letters = sum(1 for c in text if c.isalpha())
    return max(0.3, letters / 13.0)


def check_file(segment, path, text=""):
    """Проблемы одного файла."""
    issues = []
    try:
        info = kit_audio.read_wav(path)
    except Exception as error:  # noqa: BLE001 — любой битый файл — ошибка проверки
        return [Issue(segment, "ошибка", "не читается как WAV: %s" % error)]
    if info.rate != RATE:
        issues.append(Issue(segment, "ошибка", "частота %d Гц, нужно %d" % (info.rate, RATE)))
    if info.width != WIDTH:
        issues.append(Issue(segment, "ошибка", "%d бит, нужно 24" % (info.width * 8)))
    if info.channels != 1:
        issues.append(Issue(segment, "ошибка", "%d канала, нужно моно" % info.channels))
    samples = info.samples
    duration = info.duration
    if duration < MIN_SECONDS:
        issues.append(Issue(segment, "ошибка", "слишком коротко: %.2f с" % duration))
        return issues
    if duration > MAX_SECONDS:
        issues.append(Issue(segment, "ошибка", "слишком длинно: %.2f с" % duration))
    if text:
        expected = expected_seconds(text)
        if duration > expected * 3 or duration < expected * 0.35:
            issues.append(Issue(segment, "предупреждение",
                                "длина %.2f с при ожидаемых ~%.1f с — тот ли текст?" % (duration, expected)))
    clips = kit_audio.clipped_runs(samples)
    if clips:
        issues.append(Issue(segment, "ошибка", "клиппинг: %d мест(а)" % clips))
    peak_db = kit_audio.db(kit_audio.peak(samples))
    if peak_db > PEAK_MAX_DB and not clips:
        issues.append(Issue(segment, "предупреждение", "пик %.1f dBFS — мало запаса (нужно ≤ −1)" % peak_db))
    lufs = kit_audio.loudness_lufs(samples, info.rate)
    if lufs == float("-inf"):
        issues.append(Issue(segment, "ошибка", "тишина"))
        return issues
    off = lufs - TARGET_LUFS
    if abs(off) > LUFS_ERROR:
        issues.append(Issue(segment, "ошибка", "громкость %.1f LUFS, нужно −16 ± 3" % lufs))
    elif abs(off) > LUFS_WARNING:
        issues.append(Issue(segment, "предупреждение", "громкость %.1f LUFS (цель −16)" % lufs))
    lead, tail = kit_audio.edge_silence(samples, info.rate, SILENCE_DB)
    if lead > EDGE_MAX or tail > EDGE_MAX:
        issues.append(Issue(segment, "ошибка",
                            "тишина по краям %d / %d мс, нужно ≤ 50" % (lead * 1000, tail * 1000)))
    if lead < EDGE_MIN:
        issues.append(Issue(segment, "предупреждение", "звук с первого сэмпла — не обрезано ли начало?"))
    dc = sum(samples) / len(samples)
    if abs(dc) > 0.02:
        issues.append(Issue(segment, "предупреждение", "смещение нуля %.3f" % dc))
    return issues


def validate(directory, script_rows):
    """Все проблемы папки: пропуски, лишние файлы, проблемы каждого файла."""
    issues = []
    wanted = {row["id"]: row for row in script_rows}
    present = {}
    for name in sorted(os.listdir(directory)):
        if name.startswith("."):
            continue
        stem, ext = os.path.splitext(name)
        if ext.lower() != ".wav":
            issues.append(Issue(name, "предупреждение", "не WAV — пропускаю"))
            continue
        if ext != ".wav":
            issues.append(Issue(name, "ошибка", "расширение — строчными: .wav"))
        present[stem] = os.path.join(directory, name)
    for segment in wanted:
        if segment not in present:
            issues.append(Issue(segment, "ошибка", "нет файла %s.wav" % segment))
    for segment in present:
        if segment not in wanted:
            issues.append(Issue(segment, "ошибка", "лишний файл: такого отрывка нет в сценарии"))
    for segment, path in sorted(present.items()):
        if segment in wanted:
            issues.extend(check_file(segment, path, wanted[segment].get("text", "")))
    return issues


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="Проверка записей диктора")
    parser.add_argument("directory", help="папка с WAV, имя файла = id отрывка")
    parser.add_argument("--script", default=os.path.join(here, "script_uz.csv"))
    args = parser.parse_args(argv)
    rows = read_script(args.script)
    issues = validate(args.directory, rows)
    errors = [i for i in issues if i.level == "ошибка"]
    for issue in issues:
        print("%-14s %-28s %s" % (issue.level, issue.segment, issue.message))
    print("отрывков в сценарии: %d, ошибок: %d, предупреждений: %d"
          % (len(rows), len(errors), len(issues) - len(errors)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
