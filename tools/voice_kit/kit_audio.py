"""Звук для набора диктора: чтение/запись WAV, громкость, тишина по краям.

Только стандартная библиотека (wave, array, math) — набор должен
запускаться на любом маке студии без pip.

Громкость — по ITU-R BS.1770 (как LUFS в любом студийном измерителе):
K-фильтр (полка + срез низа), блоки 400 мс с перекрытием 75 %, абсолютный
порог −70 LUFS и относительный −10 LU. Для отрывка короче блока —
один блок на весь отрывок. Это оценка, а не сертифицированный измеритель,
но расходится с ним на десятые доли LU — для сверки отрывков между собой
этого достаточно.
"""

import array
import math
import wave

FULL_SCALE_24 = float(1 << 23)


class WavInfo:
    """Заголовок и сэмплы (float, −1…1) моно-WAV."""

    def __init__(self, rate, width, channels, frames, samples):
        self.rate = rate
        self.width = width          # байт на сэмпл: 3 = 24 бит
        self.channels = channels
        self.frames = frames
        self.samples = samples      # только первый канал, float

    @property
    def duration(self):
        return self.frames / float(self.rate) if self.rate else 0.0


def read_wav(path):
    """Прочитать WAV. Сэмплы — первого канала, в диапазоне −1…1."""
    with wave.open(str(path), "rb") as w:
        rate, width, channels, frames = w.getframerate(), w.getsampwidth(), w.getnchannels(), w.getnframes()
        data = w.readframes(frames)
    samples = decode_pcm(data, width, channels)
    return WavInfo(rate, width, channels, frames, samples)


def decode_pcm(data, width, channels):
    """Целые PCM 8/16/24/32 бит → float первого канала."""
    if width == 3:
        # 24 бит: раскладываем по 4 байта со сдвигом — быстро, на срезах C.
        count = len(data) // 3
        padded = bytearray(count * 4)
        padded[1::4] = data[0::3]
        padded[2::4] = data[1::3]
        padded[3::4] = data[2::3]
        values = array.array("i")
        values.frombytes(bytes(padded))
        scale = float(1 << 31)
    elif width == 2:
        values = array.array("h")
        values.frombytes(data[: len(data) // 2 * 2])
        scale = 32768.0
    elif width == 4:
        values = array.array("i")
        values.frombytes(data[: len(data) // 4 * 4])
        scale = float(1 << 31)
    elif width == 1:
        return [(b - 128) / 128.0 for b in data[::channels]]
    else:
        raise ValueError("неизвестная разрядность: %d байт" % width)
    if channels > 1:
        values = values[::channels]
    return [v / scale for v in values]


def write_wav(path, samples, rate=48000):
    """Записать моно WAV 24 бит."""
    top = FULL_SCALE_24 - 1
    values = array.array("i", (int(round(max(-1.0, min(1.0, s)) * top)) << 8 for s in samples))
    raw = values.tobytes()
    out = bytearray(len(values) * 3)
    out[0::3] = raw[1::4]
    out[1::3] = raw[2::4]
    out[2::3] = raw[3::4]
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(3)
        w.setframerate(rate)
        w.writeframes(bytes(out))


# --- Громкость (BS.1770) -----------------------------------------------------

def _k_filter_coefficients(rate):
    """Коэффициенты K-фильтра для частоты дискретизации (как в pyloudnorm)."""
    # Полка +4 дБ на высоких.
    gain, q, fc = 3.999843853973347, 0.7071752369554196, 1681.974450955533
    k = math.tan(math.pi * fc / rate)
    vh = 10 ** (gain / 20.0)
    vb = vh ** 0.4996667741545416
    a0 = 1.0 + k / q + k * k
    shelf = ((vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
             2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0)
    # Срез низа ~38 Гц.
    q, fc = 0.5003270373238773, 38.13547087602444
    k = math.tan(math.pi * fc / rate)
    a0 = 1.0 + k / q + k * k
    highpass = (1.0, -2.0, 1.0, 2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0)
    return shelf, highpass


def _biquad(samples, coefficients):
    b0, b1, b2, a1, a2 = coefficients
    x1 = x2 = y1 = y2 = 0.0
    out = [0.0] * len(samples)
    for i, x in enumerate(samples):
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, x
        y2, y1 = y1, y
        out[i] = y
    return out


def loudness_lufs(samples, rate):
    """Интегральная громкость, LUFS. −inf — тишина."""
    if not samples:
        return float("-inf")
    shelf, highpass = _k_filter_coefficients(rate)
    weighted = _biquad(_biquad(samples, shelf), highpass)
    squares = [v * v for v in weighted]
    block = int(0.4 * rate)
    step = block // 4
    if len(squares) <= block:
        powers = [sum(squares) / len(squares)]
    else:
        prefix = [0.0]
        for v in squares:
            prefix.append(prefix[-1] + v)
        powers = [(prefix[i + block] - prefix[i]) / block for i in range(0, len(squares) - block + 1, step)]

    def lufs(power):
        return -0.691 + 10.0 * math.log10(power) if power > 0 else float("-inf")

    gated = [p for p in powers if lufs(p) > -70.0]
    if not gated:
        return float("-inf")
    relative = lufs(sum(gated) / len(gated)) - 10.0
    gated = [p for p in gated if lufs(p) > relative]
    return lufs(sum(gated) / len(gated))


# --- Уровни и края -------------------------------------------------------------

def db(value):
    return 20.0 * math.log10(value) if value > 0 else float("-inf")


def peak(samples):
    return max((abs(s) for s in samples), default=0.0)


def clipped_runs(samples, level=0.999, run=3):
    """Сколько раз подряд ≥ `run` сэмплов упёрлись в потолок — клиппинг."""
    count = streak = 0
    for s in samples:
        if abs(s) >= level:
            streak += 1
            if streak == run:
                count += 1
        else:
            streak = 0
    return count


def _window_levels(samples, rate, window_seconds=0.005):
    window = max(1, int(window_seconds * rate))
    levels = []
    for start in range(0, len(samples), window):
        chunk = samples[start:start + window]
        rms = math.sqrt(sum(v * v for v in chunk) / len(chunk)) if chunk else 0.0
        levels.append(db(rms))
    return levels, window


def edge_silence(samples, rate, threshold_db=-50.0):
    """Тишина в начале и в конце, секунды (окна 5 мс тише порога)."""
    levels, window = _window_levels(samples, rate)
    loud = [i for i, level in enumerate(levels) if level > threshold_db]
    if not loud:
        total = len(samples) / float(rate)
        return total, total
    lead = loud[0] * window / float(rate)
    tail_samples = len(samples) - (loud[-1] + 1) * window
    return lead, max(0, tail_samples) / float(rate)


def trim(samples, rate, keep_seconds=0.012, threshold_db=-50.0):
    """Обрезать тишину по краям, оставив `keep_seconds` с каждой стороны."""
    levels, window = _window_levels(samples, rate)
    loud = [i for i, level in enumerate(levels) if level > threshold_db]
    if not loud:
        return list(samples)
    keep = int(keep_seconds * rate)
    start = max(0, loud[0] * window - keep)
    end = min(len(samples), (loud[-1] + 1) * window + keep)
    return list(samples[start:end])


def apply_gain(samples, gain_db):
    factor = 10 ** (gain_db / 20.0)
    return [s * factor for s in samples]


def normalize(samples, rate, target_lufs=-16.0, ceiling_db=-1.0):
    """Довести до целевой громкости, не поднимая пик выше потолка."""
    measured = loudness_lufs(samples, rate)
    if measured == float("-inf"):
        return list(samples)
    gain = target_lufs - measured
    headroom = ceiling_db - db(peak(samples))
    return apply_gain(samples, min(gain, headroom))


def fade(samples, rate, seconds=0.004):
    count = len(samples)
    n = min(count // 2, int(seconds * rate))
    out = list(samples)
    for i in range(n):
        g = i / float(n)
        out[i] *= g
        out[count - 1 - i] *= g
    return out
