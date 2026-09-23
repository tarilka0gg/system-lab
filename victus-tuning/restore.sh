#!/bin/sh
. "$(dirname "$(readlink -f "$0")")/scripts/board-guard.sh"
# restore.sh — повертає CpuSetup / SaSetup / Setup з бекапу в efivarfs.
# Використання:  ./restore.sh [шлях-до-теки-бекапу]
# Якщо аргумент не заданий — береться тека з .last_backup.
# ПОТРІБЕН root (efivarfs).  OpenRC-friendly, без systemd.
set -eu

BASE="$(dirname "$(readlink -f "$0")")"
BK="${1:-$BASE/$(cat "$BASE/.last_backup")}"
EFI=/sys/firmware/efi/efivars

echo "Відновлення з: $BK"

for v in \
  CpuSetup-b08f97ff-e6e8-4193-a997-5e9e9b0adb32 \
  SaSetup-72c5e28c-7783-43a1-8767-fad73fccafa4 \
  Setup-ec87d643-eba4-4bb5-a1e5-3f3e36b20da9
do
  src="$BK/$v"
  dst="$EFI/$v"
  [ -f "$src" ] || { echo "ПРОПУСК: немає $src"; continue; }
  # зняти immutable, якщо стоїть
  chattr -i "$dst" 2>/dev/null || true
  # efivarfs очікує весь файл (4 байти атрибутів + дані) одним записом
  cat "$src" > "$dst"
  echo "відновлено $v ($(stat -c%s "$src") байт)"
done

echo "Готово. Перевір sha256 за $BK/manifest.txt та перезавантажся."
