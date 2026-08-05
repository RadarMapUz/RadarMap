#!/usr/bin/env python3
"""Сводка MetricKit по устройствам: крэши, зависания, время запуска.

Читает таблицу metrics (пишет её api.py: kind = metric | diagnostic,
payload — jsonRepresentation() пакета MetricKit) и печатает сводку за
последние N дней. Смотреть перед каждым релизом: рост hang rate или крэшей —
регресс, который жалобы догонят только через неделю.

Запуск на VPS:  python3 report_metrics.py [--days 7] [--db /opt/radarmap/api/reports.db]
"""

import argparse
import json
import sqlite3
import time
from collections import defaultdict

DB_PATH = "/opt/radarmap/api/reports.db"


def bucket_average(histogram: dict) -> float:
    """Среднее по гистограмме MetricKit: {"histogramValue": {"0": {"bucketStart":…,
    "bucketEnd":…, "bucketCount":…}, …}} — берём середины корзин."""
    buckets = (histogram or {}).get("histogramValue", {})
    total = 0.0
    count = 0
    for bucket in buckets.values():
        start = parse_measure(bucket.get("bucketStart"))
        end = parse_measure(bucket.get("bucketEnd"))
        n = int(bucket.get("bucketCount", 0))
        if start is None or end is None or n == 0:
            continue
        total += (start + end) / 2 * n
        count += n
    return total / count if count else 0.0


def parse_measure(value):
    """MetricKit пишет величины строками с единицей («240 ms», «1,2 s»)."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).replace(",", ".").strip()
    for suffix, factor in ((" ms", 1.0), (" s", 1000.0), ("ms", 1.0), ("s", 1000.0)):
        if text.endswith(suffix):
            try:
                return float(text[: -len(suffix)].strip()) * factor
            except ValueError:
                return None
    try:
        return float(text)
    except ValueError:
        return None


def signal_of(crash: dict) -> str:
    meta = crash.get("diagnosticMetaData", {})
    parts = []
    for key in ("exceptionType", "signal", "terminationReason"):
        if meta.get(key) is not None:
            parts.append(f"{key}={meta[key]}")
    return ", ".join(parts) or "без метаданных"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--db", default=DB_PATH)
    args = parser.parse_args()

    since = time.time() - args.days * 86400
    conn = sqlite3.connect(args.db)
    rows = conn.execute(
        "SELECT device, kind, received, payload FROM metrics WHERE received > ?"
        " ORDER BY received", (since,)).fetchall()
    conn.close()

    devices = set()
    crashes = []            # (device, день, сигнатура)
    hangs = []              # (device, длительность мс)
    launch_ms = []          # среднее время до первого кадра по пакетам
    hang_time_ms = []       # суммарное «висение» за сутки по пакетам

    for device, kind, received, payload in rows:
        devices.add(device)
        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            continue
        day = time.strftime("%d.%m", time.localtime(received))

        if kind == "diagnostic":
            for crash in data.get("crashDiagnostics", []) or []:
                crashes.append((device, day, signal_of(crash)))
            for hang in data.get("hangDiagnostics", []) or []:
                duration = parse_measure(
                    hang.get("diagnosticMetaData", {}).get("hangDuration"))
                hangs.append((device, duration or 0.0))
        else:
            launch = (data.get("applicationLaunchMetrics") or {}).get(
                "histogrammedTimeToFirstDrawKey")
            if launch:
                value = bucket_average(launch)
                if value:
                    launch_ms.append(value)
            responsiveness = (data.get("applicationResponsivenessMetrics") or {}).get(
                "histogrammedAppHangTime")
            if responsiveness:
                hang_time_ms.append(bucket_average(responsiveness))

    print(f"MetricKit за {args.days} дн · устройств: {len(devices)} · пакетов: {len(rows)}")
    print()

    print(f"Крэши: {len(crashes)}")
    grouped = defaultdict(int)
    for _, day, signature in crashes:
        grouped[f"{day} · {signature}"] += 1
    for line, count in sorted(grouped.items()):
        print(f"  {count}× {line}")
    print()

    print(f"Зависания (hangDiagnostics): {len(hangs)}")
    if hangs:
        durations = [d for _, d in hangs if d]
        if durations:
            print(f"  среднее {sum(durations) / len(durations):.0f} мс, "
                  f"максимум {max(durations):.0f} мс")
    print()

    if launch_ms:
        print(f"Запуск до первого кадра: среднее {sum(launch_ms) / len(launch_ms):.0f} мс "
              f"по {len(launch_ms)} пакетам")
    if hang_time_ms:
        nonzero = [v for v in hang_time_ms if v]
        print(f"Висение main за сутки (histogram): среднее "
              f"{(sum(nonzero) / len(nonzero)) if nonzero else 0:.0f} мс")
    if not rows:
        print("Пакетов нет: либо приложение не запускалось сутки, либо metrics не доходят.")


if __name__ == "__main__":
    main()
