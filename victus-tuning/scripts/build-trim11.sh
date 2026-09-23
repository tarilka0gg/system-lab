#!/bin/bash
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# build-trim11.sh — збірка + повне розгортання ядра trim11 (джерела 7.1.6).
# Запускати з-під root, коли звільниться CPU.
#
# На відміну від build-trim10.sh, тут одразу зашитий весь ручний
# розгортальний хвіст (make install НЕ чіпає ESP/limine.conf сам —
# з'ясовано під час розгортання trim10):
#   - копіювання vmlinuz + мікрокоду в /boot/efi/EFI/limine/
#   - переписування limine.conf (обидві копії): trim11 primary,
#     trim10 -> [fallback], trim9 видаляється повністю (ESP+/boot+modules)
#   - видалення LimineLastBootedEntry (інакше глушить default_entry)
set -e

SRC=/usr/src/linux-7.1.6-cachyos0
LOG=$BASE/../kernel/logs/trim11-build.log
JOBS=$(nproc)

NEW=7.1.6-cachyos-trim11-tuned
FALLBACK=7.1.3-cachyos-trim10-tuned
RETIRE=7.1.3-cachyos-trim9-tuned

ESP=/boot/efi/EFI/limine
PARTUUID=$(findmnt -no PARTUUID /)
CMDLINE="root=PARTUUID=$PARTUUID ro zswap.enabled=0 efi_pstore.pstore_disable=0"

cd "$SRC"

echo "=== $(date) старт збірки trim11 (-j$JOBS) ===" | tee "$LOG"
make -j"$JOBS" 2>&1 | tee -a "$LOG"

echo "=== $(date) modules_install ===" | tee -a "$LOG"
make modules_install 2>&1 | tee -a "$LOG"

echo "=== $(date) install ===" | tee -a "$LOG"
make install 2>&1 | tee -a "$LOG"

echo "=== $(date) розгортання в ESP ===" | tee -a "$LOG"
cp -v "/boot/vmlinuz-$NEW" "$ESP/"
cp -v /boot/intel-uc.img "$ESP/intel-uc.img"

for CONF in /boot/efi/EFI/limine/limine.conf /boot/efi/EFI/boot/limine.conf; do
cat > "$CONF" <<EOF
timeout: 0
default_entry: 1

/Gentoo ($NEW)
    protocol: linux
    kernel_path: boot():/EFI/limine/vmlinuz-$NEW
    module_path: boot():/EFI/limine/intel-uc.img
    cmdline: $CMDLINE

/Gentoo ($FALLBACK) [fallback]
    protocol: linux
    kernel_path: boot():/EFI/limine/vmlinuz-$FALLBACK
    module_path: boot():/EFI/limine/intel-uc.img
    cmdline: $CMDLINE
EOF
done

echo "=== $(date) видаляю retire-ядро ($RETIRE) ===" | tee -a "$LOG"
rm -fv "$ESP/vmlinuz-$RETIRE"
rm -fv "/boot/vmlinuz-$RETIRE" "/boot/System.map-$RETIRE" "/boot/config-$RETIRE"
rm -rfv "/usr/lib/modules/$RETIRE"
rm -fv /boot/*.old

echo "=== $(date) прибираю LimineLastBootedEntry ===" | tee -a "$LOG"
VAR=$(find /sys/firmware/efi/efivars -iname '*LimineLastBooted*' 2>/dev/null | head -1)
if [ -n "$VAR" ]; then
    chattr -i "$VAR" 2>/dev/null
    rm -fv "$VAR"
fi

echo "=== $(date) TRIM11 ГОТОВЕ ===" | tee -a "$LOG"
