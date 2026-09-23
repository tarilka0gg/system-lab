#!/bin/bash
# Збірка ядра з /usr/src/linux-7.1.3-cachyos0 (clang 22 + ThinLTO чи Full LTO — залежно від .config)
# Версію бере з localversion.30-trim — зараз "-trim9".
# Запускати від СЕБЕ, не від root. Кроки з doas спитають пароль.
set -euo pipefail

SRC=/usr/src/linux-7.1.3-cachyos0
CONFIG_BACKUP="$(dirname "$(readlink -f "$0")")/../config/kernel-config-7.1.3-cachyos-trim9-tuned"
ROOT_PARTUUID=$(findmnt -no PARTUUID /)   # визначаємо автоматично, не зашиваємо
export PATH=/usr/lib/llvm/22/bin:$PATH        # eselect llvm зламаний, clang тільки тут
JOBS=$(nproc)

cd "$SRC"

# 0. страховка: якщо Portage перепакував сорці (вже було раз, 30.07),
#    .config злітає до дефолтного CachyOS. Звіряємо і за потреби відновлюємо.
if ! cmp -s "$CONFIG_BACKUP" .config 2>/dev/null; then
  echo ">>> .config у дереві не збігається з резервною копією — відновлюю з $CONFIG_BACKUP"
  cp "$CONFIG_BACKUP" .config
  make LLVM=1 olddefconfig
fi

KV=$(make -s LLVM=1 kernelrelease)
LTO_MODE=$(grep -oP '(?<=^CONFIG_LTO_CLANG_)(FULL|THIN)(?==y)' .config || echo none)
echo ">>> $KV, clang $(clang --version | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1), LTO=$LTO_MODE, -j$JOBS"

# 1. ядро + модулі (від користувача, дерево твоє)
# Full LTO: фінальний link — один важкий монолітний крок, а не паралельний по модулях.
# Пишемо пам'ять/своп раз на 10с у фон, щоб бачити реальний пік, а не гадати після факту.
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

time make LLVM=1 -j"$JOBS"

if [ "$LTO_MODE" = "FULL" ]; then
  kill "$MEMWATCH_PID" 2>/dev/null
  trap - EXIT
  PEAK_MEM=$(grep -oP 'mem_used=\K[0-9]+' "$MEMLOG" | sort -n | tail -1)
  PEAK_SWAP=$(grep -oP 'swap_used=\K[0-9]+' "$MEMLOG" | sort -n | tail -1)
  MIN_AVAIL=$(grep -oP 'mem_avail=\K[0-9]+' "$MEMLOG" | sort -n | head -1)
  echo ">>> пік пам'яті під час збірки: used=${PEAK_MEM}M swap=${PEAK_SWAP}M min_avail=${MIN_AVAIL}M"
  echo ">>> повний лог: $MEMLOG"
fi

# 2. встановлення
doas make LLVM=1 -j"$JOBS" modules_install
doas make LLVM=1 install

# 3. nvidia та інші out-of-tree модулі під нове ядро
doas env KERNEL_DIR="$SRC" emerge --quiet @module-rebuild

# 4. Limine — єдиний завантажувач (GRUB видалено 30.07: emerge --unmerge + чистка ESP).
# Limine нічого сам не сканує: ядро й мікрокод копіюємо на ESP руками,
# limine.conf правимо теж руками (upstream-пакет без автогенератора).
# /EFI/limine/  — основний шлях (NVRAM Boot0001 "Limine")
# /EFI/boot/    — резервний шлях прошивки на випадок скидання NVRAM;
#                 тримаємо там ІДЕНТИЧНУ копію, інакше вона протухне як колись GRUB.
ESP=/boot/efi/EFI
PREV_KV=$(doas awk -F'[()]' '/^\/Gentoo/{print $2; exit}' "$ESP/limine/limine.conf")

gen_limine_conf() {
  cat <<LIMINE_EOF
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
LIMINE_EOF
}

doas cp "/boot/vmlinuz-$KV" "$ESP/limine/vmlinuz-$KV"
doas cp /boot/intel-uc.img "$ESP/limine/intel-uc.img"
gen_limine_conf | doas tee "$ESP/limine/limine.conf" > /dev/null

# та сама конфігурація (з тими самими шляхами boot():/EFI/limine/...) — у резервний /EFI/boot/
gen_limine_conf | doas tee "$ESP/boot/limine.conf" > /dev/null
doas cp "$ESP/limine/BOOTX64.EFI" "$ESP/boot/BOOTX64.EFI"

# прибираємо ядро, яке щойно перестало бути fallback
doas find "$ESP/limine" -maxdepth 1 -name 'vmlinuz-*' \
  ! -name "vmlinuz-$KV" ! -name "vmlinuz-$PREV_KV" -delete

echo
echo ">>> Готово: $KV"
echo ">>> Модулів: $(find /usr/lib/modules/$KV/kernel -name '*.ko' | wc -l), $(du -sh /usr/lib/modules/$KV | cut -f1)"
echo ">>> vmlinuz: $(du -h /boot/vmlinuz-$KV | cut -f1)"
echo
echo ">>> Меню Limine приховане (timeout=0) — тримай Shift/Esc при старті, щоб його викликати."
