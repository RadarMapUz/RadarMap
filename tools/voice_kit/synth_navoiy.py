#!/usr/bin/env python3
"""Озвучка сценария нейросетью Navoiy TTS вместо диктора (задача 28.M).

    ~/RadarMapBuild/voice/venv/bin/python -I synth_navoiy.py \\
        --voice-dir ~/RadarMapBuild/voice --reference female --out wav_female/

Navoiy TTS (aisha-org/navoiy-tts, Apache 2.0) — дообученная на узбекском
LLM-часть CosyVoice2-0.5B (FunAudioLLM, Apache 2.0). Встроенных дикторов у
неё нет: тембр берётся из опорной записи. Опора — только записи, которые
поставляются с самим кодом CosyVoice под той же лицензией (`asset/`):
`zero_shot_prompt.wav` (женский; им же озвучены демо Navoiy) и
`cross_lingual_prompt.wav` (мужской). Чужие голоса из случайных записей
скрипт не принимает: `--reference` — имя, а не путь.

Манера — пресет Navoiy «xotirjam» (calm): ровный спокойный голос без
эмоций, как у навигатора.

Интонация по колонке `position`. Отрывок, который в фразе стоит в начале
или в середине («Koʻchma radar», «oldinda», «yetmish»), начитанный
отдельно, получает понижение конца фразы — и в склейке каждое слово
звучит как последнее. Поэтому такой отрывок синтезируется ВНУТРИ фразы —
`текст, продолжение.` — и вырезается по паузе на запятой: до запятой
интонация остаётся незавершённой, ровной. Отрывки «конец»/«отдельно»
читаются целиком с точкой. Не нашлась пауза там, где ей положено быть, —
отрывок читается отдельно без точки (ровнее, чем с точкой), и это
пишется в журнал.

На каждый отрывок — несколько попыток с разными зёрнами; берётся та, чья
длина ближе к ожидаемой по числу слогов: модель иногда «зацикливается»
или глотает слово, и длина — самый честный признак этого без слуха.

Выход — WAV по требованиям README (48 кГц / 24 бит / моно, −16 LUFS, пик
≤ −1 dBFS, тишина по краям ≤ 50 мс) и `synth_log.csv`: способ, зерно,
длина, слоги, слоги в секунду — для разбора подозрительных отрывков.

Веса модели, код CosyVoice и окружение живут вне репозитория
(`--voice-dir`, по умолчанию ~/RadarMapBuild/voice): models/navoiy-tts,
models/CosyVoice2-0.5B, src/CosyVoice. Чистые помощники (подготовка
текста, слоги, поиск паузы, приведение к требованиям) не требуют torch и
покрыты test_synth_navoiy.py.
"""

import argparse
import csv
import math
import os
import random
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:  # запуск с -I: каталога скрипта в sys.path нет
    sys.path.insert(0, HERE)

import kit_audio  # noqa: E402
import validate   # noqa: E402

MODEL_RATE = 24000
# Опорные голоса — только из asset/ кода CosyVoice (Apache 2.0).
REFERENCES = {
    "female": "zero_shot_prompt.wav",
    "male": "cross_lingual_prompt.wav",
}
# Пресет «xotirjam» из emotions_40h.json Navoiy — дословно.
CALM_INSTRUCTION = "Speak in a calm, steady, neutral voice with even pacing and relaxed intonation."
DEFAULT_TAIL = "uch yuz metr"
# Потолок пика WAV: README требует ≤ −1 dBFS, но AAC 48 кбит/с поднимает пик
# речи синтеза до 1 дБ — берём с запасом.
SAFE_PEAK_DB = -2.5
NON_FINAL = ("начало", "середина")
# Как читать то, что модель сама не прочтёт (заметки сценария).
SPOKEN = [
    (re.compile(r"\bYTH\b"), "ye-te-xa"),
    (re.compile(r"\bYPX\b"), "ye-pe-xa"),
    (re.compile(r"\s\+\s"), " va "),
    (re.compile(r"\s*—\s*"), ", "),
]
APOSTROPHES = "ʻʼ‘’`´"
VOWELS = set("aeiouAEIOU")


# --- Текст -------------------------------------------------------------------

def spoken_text(text):
    """Текст сценария → то, что подаётся модели: апострофы прямые (так
    размечен корпус Navoiy), аббревиатуры и «+» — словами."""
    for pattern, replacement in SPOKEN:
        text = pattern.sub(replacement, text)
    for mark in APOSTROPHES:
        text = text.replace(mark, "'")
    return re.sub(r"\s+", " ", text).strip()


def syllables(text):
    """Слоги узбекской латиницы = гласные (oʻ — одна гласная)."""
    return sum(1 for c in spoken_text(text) if c in VOWELS)


def is_non_final(position):
    """Отрывок стоит в начале или в середине фразы — нужна незавершённая
    интонация. «начало, конец» и пр. — тоже: ровная середина звучит в конце
    приемлемо, а понижение в середине — нет."""
    return any(p.strip() in NON_FINAL for p in position.split(","))


def carrier(text, example):
    """Фраза, внутри которой синтезируется отрывок: сам отрывок, запятая и
    продолжение — настоящее из примера, если пример с отрывка и начинается,
    иначе нейтральное «uch yuz metr»."""
    seg = spoken_text(text).rstrip(".,!?")
    ex = spoken_text(example)
    tail = DEFAULT_TAIL
    if ex.lower().startswith(seg.lower()):
        rest = ex[len(seg):].lstrip(" ,.").rstrip(".!?")
        if rest and len(rest.split()) >= 2:
            tail = rest
    return "%s, %s." % (seg, tail)


def standalone(text, final):
    seg = spoken_text(text).rstrip(".,")
    if final:
        return seg if seg.endswith(("!", "?")) else seg + "."
    return seg


# --- Звук: пауза, оценка, приведение к требованиям ----------------------------

def frame_levels(samples, rate, frame_seconds=0.01):
    """dBFS по окнам 10 мс."""
    n = max(1, int(frame_seconds * rate))
    out = []
    for start in range(0, len(samples), n):
        chunk = samples[start:start + n]
        rms = math.sqrt(sum(v * v for v in chunk) / len(chunk)) if chunk else 0.0
        out.append(kit_audio.db(rms))
    return out, n


def silent_runs(samples, rate, below_db=35.0, min_seconds=0.06):
    """Паузы внутри звука: (начало, конец) в секундах, тише пика окон на
    `below_db` и не короче `min_seconds`. Края звука в счёт не идут."""
    levels, n = frame_levels(samples, rate)
    finite = [l for l in levels if l != float("-inf")]
    if not finite:
        return []
    threshold = max(finite) - below_db
    loud = [i for i, l in enumerate(levels) if l > threshold]
    if not loud:
        return []
    runs, start = [], None
    for i in range(loud[0], loud[-1] + 1):
        quiet = levels[i] <= threshold
        if quiet and start is None:
            start = i
        elif not quiet and start is not None:
            if (i - start) * n / rate >= min_seconds:
                runs.append((start * n / rate, i * n / rate))
            start = None
    return runs


def cut_point(samples, rate, segment_syllables, carrier_syllables, min_pause=0.12):
    """Где кончается отрывок в фразе-носителе. Ожидаемое место — доля слогов
    отрывка во всей фразе; из пауз не короче `min_pause` (смычка «q», «t»
    внутри слова — 50–170 мс, пауза запятой — 160–360 мс) берётся ближайшая
    к нему, в пределах от половины до двух ожидаемых длин и не в самом
    хвосте. Первая попавшаяся пауза резала «qirq» перед последним «q».
    None — паузы нет там, где ей положено быть."""
    total = len(samples) / float(rate)
    if carrier_syllables <= 0:
        return None
    runs = silent_runs(samples, rate, min_seconds=min_pause)
    lead, _ = kit_audio.edge_silence(samples, rate)
    expected = (total - lead) * segment_syllables / float(carrier_syllables)
    best = None
    for start, end in runs:
        spoken = start - lead
        if spoken < expected * 0.5 or spoken > expected * 2.0:
            continue
        if total - end < 0.25:          # за паузой должно остаться продолжение
            continue
        distance = abs(math.log(spoken / expected))
        if best is None or distance < best[0]:
            best = (distance, start + min(0.03, (end - start) / 2))
    return best[1] if best else None


def expected_seconds(text, rate_syllables=4.2):
    return max(0.3, syllables(text) / rate_syllables)


def duration_score(seconds, text):
    """Насколько длина правдоподобна: |log(длина / ожидаемая)|, 0 — идеально."""
    return abs(math.log(max(seconds, 1e-3) / expected_seconds(text)))


def take_score(samples, text, rate=48000):
    """Чем меньше, тем правдоподобнее дубль: длина против слогов плюс штраф
    за паузу дольше 0,25 с там, где в тексте нет ни запятой, ни тире, —
    так звучит запинка модели посреди фразы («Marshrut … qayta qurildi»)."""
    score = duration_score(len(samples) / float(rate), text)
    if not re.search(r"[,—;:]", text):
        score += len(silent_runs(samples, rate, min_seconds=0.25))
    return score


def resample_linear(samples, source, target):
    """Передискретизация на случай, если у модели не 48 кГц. Основная —
    в torchaudio (полифаза); эта — запасная и для тестов."""
    if source == target or not samples:
        return list(samples)
    ratio = source / float(target)
    count = int(len(samples) / ratio)
    out = []
    for i in range(count):
        x = i * ratio
        j = int(x)
        f = x - j
        a = samples[j]
        b = samples[j + 1] if j + 1 < len(samples) else a
        out.append(a + (b - a) * f)
    return out


def soft_limit(samples, ceiling_db=-1.2):
    """Мягкий потолок пика: редкий пик выше потолка сжимается, остальное не
    трогается. Нужен, чтобы −16 LUFS достигались без упора в −1 dBFS."""
    ceiling = 10 ** (ceiling_db / 20.0)
    knee = ceiling * 0.7
    out = []
    for s in samples:
        a = abs(s)
        if a > knee:
            over = (a - knee) / (ceiling - knee)
            a = knee + (ceiling - knee) * math.tanh(over)
            s = math.copysign(a, s)
        out.append(s)
    return out


def to_studio_spec(samples, rate):
    """Как сдала бы студия: края 15 мс, −16 LUFS, пик ≤ −1 dBFS, мягкие края.

    Модель иногда начинает звук с первого сэмпла: такой край сначала
    смягчается, а потом получает 15 мс тишины — иначе первый слог начнётся
    со щелчка, а validate.py спросит, не обрезано ли начало. Края режутся
    ПОСЛЕ выравнивания громкости: тихий вдох модели до усиления лежит ниже
    порога тишины и оставался бы краем, а после усиления становился «звуком
    с первого сэмпла»."""
    pad = [0.0] * int(0.02 * rate)
    samples = pad + kit_audio.fade(samples, rate, 0.004) + pad
    lufs = kit_audio.loudness_lufs(samples, rate)
    if lufs == float("-inf"):
        return samples
    samples = kit_audio.apply_gain(samples, validate.TARGET_LUFS - lufs)
    samples = kit_audio.trim(samples, rate, 0.015, validate.SILENCE_DB)
    # Тишина по краям занижала замер — после обрезки довести точно.
    samples = kit_audio.apply_gain(samples, validate.TARGET_LUFS - kit_audio.loudness_lufs(samples, rate))
    # Пик — с запасом под AAC: на 48 кбит/с кодер добавляет до ~1 дБ к пику
    # («peak.day» при −1 dBFS в WAV раскодировался в 0 dBFS с клиппингом).
    if kit_audio.db(kit_audio.peak(samples)) > SAFE_PEAK_DB:
        samples = soft_limit(samples, SAFE_PEAK_DB)
        lufs = kit_audio.loudness_lufs(samples, rate)
        samples = kit_audio.apply_gain(samples, min(validate.TARGET_LUFS - lufs,
                                                    SAFE_PEAK_DB - kit_audio.db(kit_audio.peak(samples))))
    return kit_audio.fade(samples, rate, 0.004)


# --- Модель ------------------------------------------------------------------

class Navoiy:
    """CosyVoice2-0.5B + LLM Navoiy, режим instruct2 с опорной записью."""

    def __init__(self, voice_dir, device="auto"):
        cosy = os.path.join(voice_dir, "src", "CosyVoice")
        for path in (cosy, os.path.join(cosy, "third_party", "Matcha-TTS")):
            if path not in sys.path:
                sys.path.insert(0, path)
        import types

        def stub(name, **attrs):
            module = types.ModuleType(name)
            module.__dict__.update(attrs)
            sys.modules.setdefault(name, module)
            return module

        def offline(*_args, **_kwargs):
            raise RuntimeError("модель — только с диска")
        # Эти пакеты CosyVoice импортирует, но для синтеза они не нужны:
        # modelscope — скачать модель по имени (у нас всё на диске), pyarrow и
        # pyworld — обучение (чтение parquet, F0 датасета), lightning — один
        # декоратор логгера Matcha. Заглушка вместо установки: меньше чужого
        # кода в окружении и нет сборки C++ (pyworld) под новый Python.
        stub("modelscope", snapshot_download=offline)
        stub("pyarrow")
        stub("pyarrow.parquet")
        stub("pyworld")
        stub("lightning")
        stub("lightning.pytorch")
        stub("lightning.pytorch.utilities", rank_zero_only=lambda fn: fn)
        # matcha/utils/__init__.py тянет hydra и rich ради обучения; нужны
        # только audio.py и pylogger.py — пакет без его __init__.
        matcha_utils = os.path.join(cosy, "third_party", "Matcha-TTS", "matcha", "utils")
        import matcha  # noqa: F401 — сам пакет пуст
        stub("matcha.utils", __path__=[matcha_utils])
        import numpy as np
        import soundfile
        import torch
        import torchaudio
        import cosyvoice.cli.frontend as frontend_module
        import cosyvoice.cli.model as model_module
        from cosyvoice.cli.cosyvoice import CosyVoice2

        def load_wav(wav, target_sr, min_sr=16000):
            # torchaudio.load в новых версиях требует torchcodec — читаем сами.
            data, sr = soundfile.read(wav, dtype="float32", always_2d=True)
            speech = torch.from_numpy(data.mean(axis=1)).unsqueeze(0)
            if sr != target_sr:
                assert sr >= min_sr, "частота опоры %d ниже %d" % (sr, min_sr)
                speech = torchaudio.functional.resample(speech, sr, target_sr)
            return speech
        frontend_module.load_wav = load_wav

        import cosyvoice.llm.llm as llm_module

        def forward_one_step(encoder, xs, masks, cache=None):
            # CosyVoice передаёт маску длиной в НОВЫЕ токены (1×1 на каждом
            # шаге после первого); transformers 4.51 это прощал, 5.x — нет:
            # модель перестаёт видеть уже сказанное, не выдаёт конец и пишет
            # звук до потолка длины. Одна фраза без паддинга — маска не нужна,
            # причинность Qwen2 соблюдает сам.
            outs = encoder.model(inputs_embeds=xs, output_hidden_states=True, return_dict=True,
                                 use_cache=True, past_key_values=cache)
            return outs.hidden_states[-1], outs.past_key_values
        llm_module.Qwen2Encoder.forward_one_step = forward_one_step

        checkpoint = os.path.join(voice_dir, "models", "navoiy-tts", "emotion_600h_joint.pt")
        base = os.path.join(voice_dir, "models", "CosyVoice2-0.5B")
        self.report = {}

        def load(model, llm_model, flow_model, hift_model):
            state = torch.load(checkpoint, map_location="cpu", weights_only=True)
            for key in ("state_dict", "model", "llm"):
                if isinstance(state.get(key), dict):
                    state = state[key]
            # transformers 5 грузит Qwen2 в dtype из его config (bfloat16), а
            # остальная модель — float32: приводим к одному.
            model.llm.float()
            result = model.llm.load_state_dict(state, strict=False)
            self.report = {"missing": list(result.missing_keys), "unexpected": list(result.unexpected_keys)}
            model.llm.to(model.device).eval()
            model.flow.load_state_dict(torch.load(flow_model, map_location=model.device, weights_only=True), strict=True)
            model.flow.to(model.device).eval()
            hift = {k.replace("generator.", ""): v
                    for k, v in torch.load(hift_model, map_location=model.device, weights_only=True).items()}
            model.hift.load_state_dict(hift, strict=True)
            model.hift.to(model.device).eval()
        model_module.CosyVoice2Model.load = load

        self.torch, self.np, self.torchaudio = torch, np, torchaudio
        self.tts = CosyVoice2(base, load_jit=False, load_trt=False, fp16=False)
        self.device = "cpu"
        if device in ("auto", "mps") and torch.backends.mps.is_available():
            try:
                self._move("mps")
                self.device = "mps"
            except Exception as error:  # noqa: BLE001 — MPS не взлетел — CPU
                print("MPS не подошёл (%s) — CPU" % error, file=sys.stderr)
                self._move("cpu")

    def _move(self, name):
        dev = self.torch.device(name)
        m = self.tts.model
        m.device = dev
        m.llm.to(dev)
        m.flow.to(dev)
        m.hift.to(dev)
        self.tts.frontend.device = dev

    def synth(self, text, reference, seed):
        torch = self.torch
        random.seed(seed)
        self.np.random.seed(seed)
        torch.manual_seed(seed)
        chunks = []
        with torch.inference_mode():
            for out in self.tts.inference_instruct2(text, CALM_INSTRUCTION + "<|endofprompt|>", reference,
                                                    stream=False, text_frontend=False):
                chunks.append(out["tts_speech"].detach().float().cpu())
        if not chunks:
            raise RuntimeError("модель не вернула звук")
        audio = torch.cat(chunks, dim=1)
        audio48 = self.torchaudio.functional.resample(audio, MODEL_RATE, validate.RATE)
        return audio48.squeeze(0).tolist()


# --- Сценарий целиком --------------------------------------------------------

def plan(row):
    """(способ, текст для модели) первой попытки."""
    if is_non_final(row["position"]):
        return "carrier", carrier(row["text"], row["example"])
    return "standalone", standalone(row["text"], final=True)


def render(model, row, reference, seeds):
    """Лучшая из попыток: (сэмплы 48 кГц, запись журнала)."""
    method, text = plan(row)
    best = None
    tried = []
    for seed in seeds:
        audio = model.synth(text, reference, seed)
        used, cut = method, None
        if method == "carrier":
            cut = cut_point(audio, validate.RATE, syllables(row["text"]), syllables(text))
            if cut is None:
                tried.append("%d:нет паузы" % seed)
                continue
            audio = audio[:int(cut * validate.RATE)]
        audio = kit_audio.trim(audio, validate.RATE, 0.015, validate.SILENCE_DB)
        seconds = len(audio) / float(validate.RATE)
        score = take_score(audio, row["text"])
        tried.append("%d:%.2fс" % (seed, seconds))
        if best is None or score < best[0]:
            best = (score, audio, used, seed, text, cut)
    if best is None:
        # Пауза так и не нашлась — отдельно, без точки: ровнее, чем с точкой.
        text = standalone(row["text"], final=False)
        for seed in seeds:
            audio = kit_audio.trim(model.synth(text, reference, seed), validate.RATE, 0.015, validate.SILENCE_DB)
            seconds = len(audio) / float(validate.RATE)
            score = take_score(audio, row["text"])
            tried.append("%d:отдельно %.2fс" % (seed, seconds))
            if best is None or score < best[0]:
                best = (score, audio, "standalone-flat", seed, text, None)
    score, audio, used, seed, text, cut = best
    seconds = len(audio) / float(validate.RATE)
    entry = {
        "id": row["id"], "method": used, "seed": seed, "model_text": text,
        "seconds": "%.3f" % seconds, "syllables": syllables(row["text"]),
        "syl_per_s": "%.2f" % (syllables(row["text"]) / seconds if seconds else 0),
        "score": "%.3f" % score, "tries": " ".join(tried),
    }
    return audio, entry


def main(argv=None):
    parser = argparse.ArgumentParser(description="Озвучка сценария Navoiy TTS")
    parser.add_argument("--voice-dir", default=os.path.expanduser("~/RadarMapBuild/voice"))
    parser.add_argument("--reference", choices=sorted(REFERENCES), required=True,
                        help="опорный голос из asset/ CosyVoice (не путь — чужие записи не принимаются)")
    parser.add_argument("--script", default=os.path.join(HERE, "script_uz.csv"))
    parser.add_argument("--out", required=True, help="папка WAV (id.wav)")
    parser.add_argument("--only", default="", help="через запятую: только эти id (проба)")
    parser.add_argument("--seeds", default="1986,2026,42", help="зёрна попыток")
    parser.add_argument("--device", default="auto", choices=["auto", "mps", "cpu"])
    parser.add_argument("--skip-existing", action="store_true", help="не трогать готовые id.wav")
    args = parser.parse_args(argv)

    rows = validate.read_script(args.script)
    if args.only:
        wanted = set(args.only.split(","))
        rows = [r for r in rows if r["id"] in wanted]
    reference = os.path.join(args.voice_dir, "src", "CosyVoice", "asset", REFERENCES[args.reference])
    seeds = [int(s) for s in args.seeds.split(",") if s]
    os.makedirs(args.out, exist_ok=True)
    started = time.time()
    model = Navoiy(args.voice_dir, args.device)
    print("модель: %s, ключи LLM: %s, загрузка %.0f с" % (model.device, model.report, time.time() - started),
          flush=True)
    log_path = os.path.join(args.out, "synth_log.csv")
    fields = ["id", "method", "seed", "model_text", "seconds", "syllables", "syl_per_s", "score", "tries"]
    previous = {}
    if args.skip_existing and os.path.exists(log_path):
        with open(log_path, encoding="utf-8") as f:
            previous = {r["id"]: r for r in csv.DictReader(f)}
    entries = []
    for index, row in enumerate(rows, 1):
        target = os.path.join(args.out, row["id"] + ".wav")
        if args.skip_existing and os.path.exists(target) and row["id"] in previous:
            entries.append(previous[row["id"]])
            continue
        t0 = time.time()
        audio, entry = render(model, row, reference, seeds)
        kit_audio.write_wav(target, to_studio_spec(audio, validate.RATE), validate.RATE)
        entries.append(entry)
        print("[%d/%d] %-24s %-15s %5s с  %.0f с работы" % (index, len(rows), row["id"], entry["method"],
                                                         entry["seconds"], time.time() - t0), flush=True)
        with open(log_path, "w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader()
            writer.writerows(entries)
    print("готово: %d отрывков за %.0f с → %s" % (len(entries), time.time() - started, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
