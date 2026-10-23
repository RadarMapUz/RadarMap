#!/usr/bin/env python3
"""Сборка пакета голоса для приложения (этап 16.2).

    python3 build_pack.py recordings/ \\
        --out ../../RadarMap/Resources/Voice/voice-uz-female.bundle --voice "Имя диктора"

Шаги: проверка папки (validate.py — с ошибками сборка не идёт) → каждый
отрывок обрезается до 12 мс тишины по краям, выравнивается по громкости
до −16 LUFS (пик не выше −1 dBFS) и получает мягкие края 4 мс → AAC через
`afconvert` (macOS) → manifest.json: id → файл, длительность, sha256.
Пакет больше 3 МБ — ошибка: столько приложение везёт в каждой установке.

Только стандартная библиотека + afconvert из macOS.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

import kit_audio
import validate

MANIFEST_FORMAT = 1
BUDGET_BYTES = 3 * 1024 * 1024
KEEP_EDGE_SECONDS = 0.012
FADE_SECONDS = 0.004
# 48 кбит/с AAC-LC при 48 кГц — речь без слышимых потерь, и ~140 отрывков
# укладываются в ~1,6 МБ (у m4a ещё ~4 КБ заголовков на файл).
DEFAULT_BITRATE = 48000


class BuildError(Exception):
    pass


def afconvert(source, target, bitrate):
    """WAV → AAC в контейнере m4a. AVAudioFile учитывает задержку кодера
    (2112 сэмплов) по записи в контейнере, и стык выходит без паузы."""
    if not shutil.which("afconvert"):
        raise BuildError("нет afconvert — сборка пакета только на macOS")
    # Частота — явно: на низком битрейте кодер сам снижает её до 32 кГц, а
    # приложение сверяет частоту каждого отрывка с манифестом.
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac@%d" % validate.RATE, "-b", str(bitrate),
                    "-q", "127", str(source), str(target)], check=True, capture_output=True)


def process(samples, rate):
    """Обрезка краёв, громкость, мягкие края."""
    trimmed = kit_audio.trim(samples, rate, KEEP_EDGE_SECONDS, validate.SILENCE_DB)
    leveled = kit_audio.normalize(trimmed, rate, validate.TARGET_LUFS, validate.PEAK_MAX_DB)
    return kit_audio.fade(leveled, rate, FADE_SECONDS)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def build(directory, script_rows, out, language, voice, placeholder=False,
          bitrate=DEFAULT_BITRATE, encoder=afconvert, budget=BUDGET_BYTES, check=True):
    """Собрать пакет в `out`. Возвращает манифест."""
    if check:
        errors = [i for i in validate.validate(directory, script_rows) if i.level == "ошибка"]
        if errors:
            raise BuildError("проверка не прошла:\n" + "\n".join(map(repr, errors)))
    os.makedirs(out, exist_ok=True)
    # Старое — вон: отрывок, убранный из сценария, не должен доехать до
    # приложения в старом файле.
    for name in os.listdir(out):
        if name.endswith(".m4a") or name == "manifest.json":
            os.remove(os.path.join(out, name))
    segments = {}
    total = 0
    with tempfile.TemporaryDirectory() as work:
        for row in script_rows:
            segment = row["id"]
            info = kit_audio.read_wav(os.path.join(directory, segment + ".wav"))
            samples = process(info.samples, info.rate)
            temp = os.path.join(work, segment + ".wav")
            kit_audio.write_wav(temp, samples, info.rate)
            target = os.path.join(out, segment + ".m4a")
            encoder(temp, target, bitrate)
            size = os.path.getsize(target)
            total += size
            segments[segment] = {
                "file": segment + ".m4a",
                "duration": round(len(samples) / float(info.rate), 4),
                "sha256": sha256(target),
            }
    if total > budget:
        raise BuildError("пакет %.2f МБ — больше бюджета %.1f МБ" % (total / 1048576.0, budget / 1048576.0))
    manifest = {
        "format": MANIFEST_FORMAT,
        "language": language,
        "placeholder": bool(placeholder),
        "sampleRate": validate.RATE,
        "channels": 1,
        "codec": "aac",
        "bitrate": bitrate,
        "voice": voice,
        "segments": segments,
    }
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    return manifest


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="Сборка пакета голоса (AAC + manifest.json)")
    parser.add_argument("directory", help="папка с WAV диктора")
    parser.add_argument("--script", default=os.path.join(here, "script_uz.csv"))
    parser.add_argument("--out", required=True, help="папка пакета, например …/voice-uz-female.bundle")
    parser.add_argument("--language", default="uz")
    parser.add_argument("--voice", required=True, help="кто говорит — для экрана и журнала")
    parser.add_argument("--bitrate", type=int, default=DEFAULT_BITRATE)
    parser.add_argument("--placeholder", action="store_true", help="пакет-заглушка (не диктор)")
    args = parser.parse_args(argv)
    try:
        manifest = build(args.directory, validate.read_script(args.script), args.out, args.language,
                         args.voice, args.placeholder, args.bitrate)
    except BuildError as error:
        print("сборка не удалась: %s" % error, file=sys.stderr)
        return 1
    size = sum(os.path.getsize(os.path.join(args.out, s["file"])) for s in manifest["segments"].values())
    print("готово: %d отрывков, %.2f МБ → %s" % (len(manifest["segments"]), size / 1048576.0, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
