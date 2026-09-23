#!/bin/bash
# root-версія ~/build-kernel-7.1.3.sh (без doas, бо вже root)
# Збірка ядра з /usr/src/linux-7.1.3-cachyos0 (Full LTO зараз — trim9)
set -euo pipefail

SRC=/usr/src/linux-7.1.3-cachyos0
CONFIG_BACKUP="$(dirname "$(readlink -f "$0")")/../config/kernel-config-7.1.3-cachyos-trim9-tuned"
ROOT_PARTUUID=$(findmnt -no PARTUUID /)   # визначаємо автоматично, не зашиваємо
export PATH=/usr/lib/llvm/22/bin:$PATH
JOBS=$(nproc)

cd "$SRC"

if ! cmp -s "$CONFIG_BACKUP" .config 2>/dev/null; then
  echo ">>> .config у дереві не збігається з резервною копією — відновлюю з $CONFIG_BACKUP"
  cp "$CONFIG_BACKUP" .config
  make LLVM=1 olddefconfig
fi

KV=$(make -s LLVM=1 kernelrelease)
LTO_MODE=$(grep -oP '(?<=^CONFIG_LTO_CLANG_)(FULL|THIN)(?==y)' .config || echo none)
echo ">>> $KV, clang $(clang --version | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1), LTO=$LTO_MODE, -j$JOBS"

# Full LTO: фінальний link — один важкий монолітний крок.
# Пишемо пам'ять/своп раз на 10с у фон, щоб бачити реальний пік.
MEMLOG=/tmp/build-mem-$KV.log
: > "$MEMLOG"
if [ "$LTO_MODE" = "FULL" ]; then
  ( while true; do
      date '+%H:%M:%S' | tr -d '\n' >> "$MEMLOG"
      echo -n ' ' >> "$MEMLOG"
      free -m | awk '/^Mem:/{printf "mem_used=%dM mem_avail=%dM ",$3,$7} /^Swap:/{printf "swap_used=%dM\n",$3}' >> "$MEMLOG"
      sleep 10
    done ) &
  MEMWATCH_PID=$!
  trap 'kill $MEMWATCH_PID 2>/dev/null' EXIT
fi

time runuser -u tarilka0gg -- env PATH="$PATH" make LLVM=1 -j"$JOBS"

if [ "$LTO_MODE" = "FULL" ]; then
  kill "$MEMWATCH_PID" 2>/dev/null
  trap - EXIT
  PEAK_MEM=$(grep -oP 'mem_used=\K[0-9]+' "$MEMLOG" | sort -n | tail -1)
  PEAK_SWAP=$(grep -oP 'swap_used=\K[0-9]+' "$MEMLOG" | sort -n | tail -1)
  MIN_AVAIL=$(grep -oP 'mem_avail=\K[0-9]+' "$MEMLOG" | sort -n | head -1)
  echo ">>> пік пам'яті під час збірки: used=${PEAK_MEM}M swap=${PEAK_SWAP}M min_avail=${MIN_AVAIL}M"
  echo ">>> повний лог: $MEMLOG"
fi

echo ">>> modules_install + install"
make LLVM=1 -j"$JOBS" modules_install
make LLVM=1 install

echo ">>> nvidia @module-rebuild"
KERNEL_DIR="$SRC" emerge --quiet @module-rebuild

echo ">>> Limine"
ESP=/boot/efi/EFI
PREV_KV=$(awk -F'[()]' '/^\/Gentoo/{print $2; exit}' "$ESP/limine/limine.conf")
gen_conf() {
  cat <<LIM
timeout: 0
default_entry: 1

/Gentoo ($KV)
    protocol: linux
    kernel_path: boot():/EFI/limine/vmlinuz-$KV
    module_path: boot():/EFI/limine/intel-uc.img
    cmdline: root=PARTUUID=$ROOT_PARTUUID ro zswap.enabled=0

/Gentoo ($PREV_KV) [fallback]
    protocol: linux
    kernel_path: boot():/EFI/limine/vmlinuz-$PREV_KV
    module_path: boot():/EFI/limine/intel-uc.img
    cmdline: root=PARTUUID=$ROOT_PARTUUID ro zswap.enabled=0
LIM
}
cp "/boot/vmlinuz-$KV" "$ESP/limine/vmlinuz-$KV"
cp /boot/intel-uc.img "$ESP/limine/intel-uc.img"
gen_conf > "$ESP/limine/limine.conf"
gen_conf > "$ESP/boot/limine.conf"
cp "$ESP/limine/BOOTX64.EFI" "$ESP/boot/BOOTX64.EFI"
find "$ESP/limine" -maxdepth 1 -name 'vmlinuz-*' ! -name "vmlinuz-$KV" ! -name "vmlinuz-$PREV_KV" -delete

echo
echo ">>> ГОТОВО: $KV"
echo ">>> Модулів: $(find /usr/lib/modules/$KV/kernel -name '*.ko' | wc -l), $(du -sh /usr/lib/modules/$KV | cut -f1)"
echo ">>> vmlinuz: $(du -h /boot/vmlinuz-$KV | cut -f1)"
echo ">>> default=$KV, fallback=$PREV_KV"
