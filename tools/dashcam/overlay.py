#!/usr/bin/env python3
"""OCR полосы кадра раз в секунду: время и скорость, вожжённые регистратором.

Полоса — верхние ~70 px кадра 1080p. ffmpeg режет её из каждой секунды
ролика во временную папку, Swift CLI (Apple Vision) читает текст. Результат
кэшируется в каталоге (таблицы ocr / ocr_done) — повторно ролик не читается.
По прочитанным часам уточняется старт ролика: «время в полосе − секунда
ролика», медиана по всем кадрам.

    python3 overlay.py KEY      — OCR поездки (KEY — имя первого ролика)
    python3 overlay.py --all    — все поездки
"""
import csv
import io
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
from datetime import datetime

import catalog

HERE = os.path.dirname(os.path.abspath(__file__))
FFMPEG = os.environ.get('FFMPEG', '/opt/homebrew/bin/ffmpeg')
SWIFTC = ('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc')
MACOS_SDK = ('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk')
SWIFT_SRC = os.path.join(HERE, 'bar_ocr.swift')
BIN = os.path.join(os.path.dirname(catalog.DB_PATH), 'bin', 'bar_ocr')
# Высота полосы на кадре 1080p; для других разрешений — пропорционально.
BAR_HEIGHT_1080 = 70
# Время из полосы, расходящееся со стартом ролика сильнее этого, — misread.
CLOCK_TRUST_SECONDS = 30


def ensure_binary():
    """Собирает Swift CLI, если его нет или исходник новее."""
    if os.path.exists(BIN) and os.path.getmtime(BIN) >= os.path.getmtime(SWIFT_SRC):
        return BIN
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    subprocess.run([SWIFTC, '-O', '-sdk', MACOS_SDK, SWIFT_SRC, '-o', BIN], check=True)
    return BIN


def parse_bar_csv(text):
    """CSV от bar_ocr → [(секунда ролика, время-в-полосе или None, км/ч или None)].
    Имя вырезки — номер кадра ffmpeg с 1; кадр n снят на секунде n−1."""
    out = []
    for row in csv.DictReader(io.StringIO(text)):
        stem = os.path.splitext(row['file'])[0]
        if not stem.isdigit():
            continue
        t = int(stem) - 1
        clock = None
        if row.get('time'):
            try:
                clock = datetime.strptime(row['time'], '%Y-%m-%d %H:%M:%S').replace(
                    tzinfo=catalog.DASHCAM_TZ).timestamp()
            except ValueError:
                clock = None
        kmh = float(row['speed']) if row.get('speed') else None
        out.append((t, clock, kmh))
    return out


def refine_start(rows, start):
    """Уточнённый старт ролика по часам в полосе. Полоса показывает целые
    секунды (усечение), поэтому медиана «часы − секунда ролика» даёт нижнюю
    границу; середина секунды — +0,5. Без надёжных чтений — прежний старт."""
    diffs = [clock - t for t, clock, _ in rows
             if clock is not None and abs(clock - t - start) <= CLOCK_TRUST_SECONDS]
    if len(diffs) < 5:
        return start
    return statistics.median(diffs) + 0.5


def ocr_clip(conn, clip, log=print, path=None):
    """path — где ролик лежит сейчас (копия с карты во временной папке);
    по умолчанию clip['path']."""
    if conn.execute('SELECT 1 FROM ocr_done WHERE clip_id=?', (clip['id'],)).fetchone():
        return False
    binary = ensure_binary()
    height = clip['height'] or 1080
    bar = max(16, round(BAR_HEIGHT_1080 * height / 1080))
    tmp = tempfile.mkdtemp(prefix='dashcam_bar_')
    try:
        subprocess.run([FFMPEG, '-v', 'error', '-nostdin',
                        '-i', path or clip['path'], '-vf', f'fps=1,crop=iw:{bar}:0:0',
                        os.path.join(tmp, '%05d.png')], check=True)
        text = subprocess.run([binary, tmp], capture_output=True, text=True, check=True).stdout
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rows = parse_bar_csv(text)
    start = refine_start(rows, clip['start'])
    read = sum(1 for r in rows if r[2] is not None)
    with conn:
        conn.execute('DELETE FROM ocr WHERE clip_id=?', (clip['id'],))
        conn.executemany('INSERT INTO ocr(clip_id, t, clock, kmh) VALUES(?,?,?,?)',
                         [(clip['id'], t, c, v) for t, c, v in rows])
        conn.execute('UPDATE clips SET start=? WHERE id=?', (start, clip['id']))
        conn.execute('INSERT OR REPLACE INTO ocr_done(clip_id, frames, read) VALUES(?,?,?)',
                     (clip['id'], len(rows), read))
    log(f"OCR {clip['name']}: {read}/{len(rows)} кадров, старт {start - clip['name_start']:+.1f} с к имени")
    return True


def ocr_trip(conn, key, progress=None, log=print):
    clips = catalog.trip_clips(conn, key)
    for i, clip in enumerate(clips):
        ocr_clip(conn, clip, log)
        if progress:
            progress(i + 1, len(clips))
    catalog.regroup(conn)  # старты уточнились — границы поездки тоже


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    conn = catalog.connect()
    keys = [t['key'] for t in catalog.trips(conn)] if argv == ['--all'] else argv
    for key in keys:
        ocr_trip(conn, key)


if __name__ == '__main__':
    sys.exit(main())
