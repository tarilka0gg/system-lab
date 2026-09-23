#!/bin/bash
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# Вартовий проти fork-ланцюга dbus-launch (спостережено 2026-07-25, після
# запуску гри з `gamemoderun` у Steam Launch Options — до 71403 процесів,
# 25GB RAM за хвилини). Перевіряє кожні 2с, вбиває при перевищенні порогу.
THRESHOLD=100
LOG="$(dirname "$(readlink -f "$0")")/../logs/dbus-launch-watchdog.log"

echo "$(date +%T) watchdog started, threshold=$THRESHOLD" >> "$LOG"
while true; do
    c=$(pgrep -c 'dbus-launch' 2>/dev/null || echo 0)
    if [ "$c" -gt "$THRESHOLD" ]; then
        echo "$(date +%T) THRESHOLD EXCEEDED: $c dbus-launch procs -> killing" >> "$LOG"
        pkill -9 -f 'dbus-launch' 2>>"$LOG"
        free -h >> "$LOG"
        echo "---" >> "$LOG"
    fi
    sleep 2
done
