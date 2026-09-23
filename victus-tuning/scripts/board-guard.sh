# board-guard.sh — підключається (`. board-guard.sh`) на початку кожного скрипта,
# який пише в MSR, sysfs, EFI-змінні чи конфіги живлення.
# Скрипти написані й перевірені ТІЛЬКИ на HP Victus 16-r1xxx (board 8C99, BIOS F.15).
# На іншій платі MSR/NVRAM-офсети означають інше, тому відмовляємось працювати.
_board=$(cat /sys/class/dmi/id/board_name 2>/dev/null)
_prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
_vend=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null)
if [ "$_board" != "8C99" ] || [ "$_vend" != "HP" ] || ! echo "$_prod" | grep -q 'Victus.*16-r1'; then
    echo "ВІДМОВА: цей скрипт лише для HP Victus 16-r1xxx (board 8C99)." >&2
    echo "         тут: board='$_board' vendor='$_vend' product='$_prod'" >&2
    exit 64
fi
unset _board _prod _vend
