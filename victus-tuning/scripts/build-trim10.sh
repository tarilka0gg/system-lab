#!/bin/bash
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# build-trim10.sh — збірка + встановлення ядра trim10.
# Запускати з-під root, коли звільниться CPU.
set -e

SRC=/usr/src/linux-7.1.3-cachyos0
LOG=$BASE/../kernel/logs/trim10-build.log
JOBS=$(nproc)

cd "$SRC"

echo "=== $(date) старт збірки trim10 (-j$JOBS) ===" | tee "$LOG"
make -j"$JOBS" 2>&1 | tee -a "$LOG"

echo "=== $(date) modules_install ===" | tee -a "$LOG"
make modules_install 2>&1 | tee -a "$LOG"

echo "=== $(date) install (kernel-install перегенерує limine.conf) ===" | tee -a "$LOG"
make install 2>&1 | tee -a "$LOG"

echo "=== $(date) TRIM10 ГОТОВЕ ===" | tee -a "$LOG"
