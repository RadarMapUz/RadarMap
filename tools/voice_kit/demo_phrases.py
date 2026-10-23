#!/usr/bin/env python3
"""Образцы для слуха: фразы из готового пакета так, как их склеит приложение.

    python3 demo_phrases.py ../../RadarMap/Resources/Voice/voice-uz-female.bundle --out образцы/

Порядок отрывков — тот же, что даёт VoiceComposer.Uzbek для этих событий
(сверено с VoiceComposerTests), паузы — AppConfig.voicePauseCommaSeconds /
voicePauseStopSeconds, отрывки — раскодированный AAC из пакета, вплотную,
как у SegmentPlayer. На выходе по .m4a на фразу и одна склейка всех фраз
подряд (`all.m4a`) с секундой тишины между ними.

Нужно, чтобы владелец (и носитель языка) услышал набор до сборки
приложения. Только стандартная библиотека + afconvert из macOS.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

import kit_audio

COMMA_SECONDS = 0.16    # AppConfig.voicePauseCommaSeconds
STOP_SECONDS = 0.32     # AppConfig.voicePauseStopSeconds
GAP_SECONDS = 1.0       # между фразами в общей склейке
C, S = "_pause.comma", "_pause.stop"

# имя файла → (событие словами, отрывки)
PHRASES = [
    ("1_camera", "Radar oldinda oʻngda, besh yuz metr",
     ["kind.radar", "side.ahead_right", C, "dist.500"]),
    ("2_maneuver", "Uch yuz metrdan soʻng, oʻngga buriling",
     ["dist.300.after", C, "man.turn_right"]),
    ("3_overspeed", "Tezlik oshirildi",
     ["p.overspeed"]),
    ("4_speed_at_camera", "Radar oldinda, toʻrt yuz metr. Tezligingiz yetmish besh, cheklov oltmish",
     ["kind.radar", "side.ahead", C, "dist.400", S, "w.your_speed", "num.70", "num.5", C,
      "w.limit", "num.60"]),
    ("5_limit_ahead", "Ikki yuz metrdan soʻng tezlik cheklovi oltmish",
     ["dist.200.after", "w.speed_limit", "num.60"]),
    ("6_jam", "Oldinda tirbandlik, taxminan sakkiz yuz metr, qoʻshimcha toʻrt daqiqa",
     ["w.jam_ahead", C, "w.about", "dist.800", C, "w.plus", "num.4", "unit.minute"]),
    ("7_radar_report", "Qabul qilindi, rahmat",
     ["p.report_accepted"]),
]


def decode(path, work):
    wav = os.path.join(work, os.path.basename(path) + ".wav")
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI24@48000", path, wav], check=True, capture_output=True)
    return kit_audio.read_wav(wav).samples


def compose(ids, segments, rate=48000):
    out = []
    for segment in ids:
        if segment == C:
            out += [0.0] * int(COMMA_SECONDS * rate)
        elif segment == S:
            out += [0.0] * int(STOP_SECONDS * rate)
        else:
            out += segments[segment]
    return out


def encode(samples, target, work, rate=48000):
    wav = os.path.join(work, os.path.basename(target) + ".wav")
    kit_audio.write_wav(wav, samples, rate)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac@48000", "-b", "128000", wav, target],
                   check=True, capture_output=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Образцы фраз из пакета голоса")
    parser.add_argument("bundle", help="папка пакета (manifest.json + m4a)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--prefix", default="", help="приставка к именам файлов (например, голос)")
    args = parser.parse_args(argv)
    with open(os.path.join(args.bundle, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    os.makedirs(args.out, exist_ok=True)
    everything = []
    with tempfile.TemporaryDirectory() as work:
        needed = {i for _, _, ids in PHRASES for i in ids if not i.startswith("_pause.")}
        missing = needed - set(manifest["segments"])
        if missing:
            print("в пакете нет: %s" % ", ".join(sorted(missing)), file=sys.stderr)
            return 1
        segments = {i: decode(os.path.join(args.bundle, manifest["segments"][i]["file"]), work) for i in needed}
        for name, text, ids in PHRASES:
            samples = compose(ids, segments)
            target = os.path.join(args.out, args.prefix + name + ".m4a")
            encode(samples, target, work)
            everything += samples + [0.0] * int(GAP_SECONDS * 48000)
            print("%-22s %5.2f с  %s" % (name, len(samples) / 48000.0, text))
        encode(everything, os.path.join(args.out, args.prefix + "all.m4a"), work)
    return 0


if __name__ == "__main__":
    sys.exit(main())
