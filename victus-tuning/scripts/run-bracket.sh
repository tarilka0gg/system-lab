#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# run-bracket.sh — уточнення межі між -160 (PASS) і -180 (FAIL_COMPUTE).
# Порядок адаптивний: -175 глибший за -170, тож якщо -170 падає, -175 падає
# тим паче — пропускаємо і йдемо на -165.
set -u
V=$BASE/scripts/validate.sh
CSV=$BASE/data/uv-asym.csv
LOG=$BASE/logs/bracket.log

verdict(){ grep "^$1," "$CSV" | tail -1 | awk -F, '{print $NF}'; }
run(){
    echo "$(date +%T) --- запуск $1 (CORE=$2) ---" | tee -a "$LOG"
    sleep 20
    "$V" "$2" -140 10 8 0 "$1"
    echo "$(date +%T) $1 -> $(verdict "$1")" | tee -a "$LOG"
}

: > "$LOG"
run br170 -170
if [ "$(verdict br170)" = "PASS" ]; then
    echo "$(date +%T) -170 чистий -> пробую глибше, -175" | tee -a "$LOG"
    run br175 -175
else
    echo "$(date +%T) -170 впав -> -175 глибший, пропускаю. Йду на -165" | tee -a "$LOG"
fi
run br165 -165

echo "$(date +%T) === БРЕКЕТ ЗАВЕРШЕНО ===" | tee -a "$LOG"
