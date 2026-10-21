#!/bin/sh
# Экспорт сценария диктора из кода приложения: script_uz.csv (и script_ru.csv
# по запросу). Запускать после любой правки VoiceEvent/VoiceComposer/VoiceScript —
# тест VoiceComposerTests.testScriptCSVMatchesCode сверяет файл с кодом.
#
#   tools/voice_kit/export_script.sh        # script_uz.csv
#   tools/voice_kit/export_script.sh ru     # script_ru.csv
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
lang="${1:-uz}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O -parse-as-library -o "$work/export" \
    "$root/RadarMap/Models/VoiceEvent.swift" \
    "$root/RadarMap/Models/VoiceComposer.swift" \
    "$root/RadarMap/Models/VoiceScript.swift" \
    "$here/ExportScript.swift"
"$work/export" "$lang" > "$here/script_$lang.csv"
echo "готово: $here/script_$lang.csv ($(($(wc -l < "$here/script_$lang.csv") - 1)) отрывков)"
