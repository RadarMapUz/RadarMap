#!/usr/bin/env python3
"""Пакет-заглушка до студии (этап 16.5): те же отрывки, но голосом `say`.

    python3 make_placeholder.py            # → RadarMap/Resources/Voice/voice-uz-placeholder.bundle

Узбекского голоса в macOS нет, поэтому узбекский текст читает турецкий
(Yelda) — с той же подменой орфографии под турецкую фонетику, что у
синтезатора в приложении (UzbekSpeech). Звучит чужим голосом, и это
нарочно: заглушка нужна, чтобы склейка, задержка и подмена отрывков
проверялись уже сейчас, а не чтобы её слушали водители. В манифесте —
`placeholder: true`; приложение берёт такой пакет только в отладочной
сборке и только по переключателю, а в выпуск папка не попадает вовсе
(EXCLUDED_SOURCE_FILE_NAMES в проекте).

Цепочка та же, что у диктора: WAV 48 кГц / 24 бит → validate.py →
build_pack.py. Если заглушка проходит проверку, пройдёт и студия.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import build_pack
import kit_audio
import validate

# Как UzbekSpeech.replacements: диграфы раньше одиночных букв.
REPLACEMENTS = [
    ("oʻ", "ö"), ("o‘", "ö"), ("o'", "ö"), ("oʼ", "ö"),
    ("Oʻ", "Ö"), ("O‘", "Ö"), ("O'", "Ö"),
    ("gʻ", "g"), ("g‘", "g"), ("g'", "g"), ("gʼ", "g"),
    ("sh", "ş"), ("ch", "ç"), ("Sh", "Ş"), ("Ch", "Ç"),
    ("x", "h"), ("X", "H"), ("q", "k"), ("Q", "K"), ("j", "c"), ("J", "C"),
    ("ʼ", ""), ("’", ""),
    # Не буквы: «+» в «Intellektual kamera + radar» читается «va».
    (" + ", " va "),
]


def transliterate(text):
    for source, target in REPLACEMENTS:
        text = text.replace(source, target)
    return text


def say(text, voice, path):
    subprocess.run(["say", "-v", voice, "--file-format=WAVE", "--data-format=LEI24@48000",
                    "-o", str(path), text], check=True, capture_output=True)


def to_studio_spec(path):
    """Как сдала бы студия: края ≤ 50 мс, −16 LUFS, пик ≤ −1 dBFS."""
    info = kit_audio.read_wav(path)
    samples = kit_audio.trim(info.samples, info.rate, 0.015, validate.SILENCE_DB)
    samples = kit_audio.normalize(samples, info.rate, validate.TARGET_LUFS, -1.5)
    kit_audio.write_wav(path, samples, info.rate)


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", ".."))
    parser = argparse.ArgumentParser(description="Пакет-заглушка голосом say")
    parser.add_argument("--script", default=os.path.join(here, "script_uz.csv"))
    parser.add_argument("--out", default=os.path.join(root, "RadarMap", "Resources", "Voice",
                                                      "voice-uz-placeholder.bundle"))
    parser.add_argument("--voice", default="Yelda")
    parser.add_argument("--language", default="uz")
    parser.add_argument("--bitrate", type=int, default=32000,
                        help="заглушке хватает 32 кбит/с: её не слушают, ею проверяют")
    args = parser.parse_args(argv)
    if not shutil.which("say"):
        print("нет say — заглушка собирается только на macOS", file=sys.stderr)
        return 1
    rows = validate.read_script(args.script)
    with tempfile.TemporaryDirectory() as work:
        for row in rows:
            path = os.path.join(work, row["id"] + ".wav")
            say(transliterate(row["text"]) if args.language == "uz" else row["text"], args.voice, path)
            to_studio_spec(path)
        try:
            manifest = build_pack.build(work, rows, args.out, args.language,
                                        "say: %s — заглушка, не диктор" % args.voice,
                                        placeholder=True, bitrate=args.bitrate)
        except build_pack.BuildError as error:
            print("заглушка не собралась: %s" % error, file=sys.stderr)
            return 1
    size = sum(os.path.getsize(os.path.join(args.out, s["file"])) for s in manifest["segments"].values())
    print("заглушка: %d отрывков, %.2f МБ → %s" % (len(manifest["segments"]), size / 1048576.0, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
