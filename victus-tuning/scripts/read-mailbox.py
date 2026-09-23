#!/usr/bin/env python3
"""Читає офсети напруги з OC mailbox (MSR 0x150) для всіх 5 доменів. Лише читання.
Запис у 0x150 тут — це команда «прочитати площину», значення напруги вона не змінює.
Потрібен root і `modprobe msr`. Після відкату андервольту всі домени мають бути 0.0 мВ.
  exit 0 — усі нулі; exit 3 — є ненульовий офсет."""
import os, struct, subprocess, sys

def board_ok():
    g = lambda n: open(f"/sys/class/dmi/id/{n}").read().strip()
    return g("board_name") == "8C99" and g("board_vendor") == "HP"

if not board_ok():
    sys.exit("ВІДМОВА: скрипт лише для HP Victus 16-r1xxx (board 8C99)")
subprocess.run(["modprobe", "msr"], check=False)
f = os.open("/dev/cpu/0/msr", os.O_RDWR)
PLANES = [("CORE", 0), ("GPU", 1), ("CACHE", 2), ("UNCORE", 3), ("ANALOGIO", 4)]
nonzero = False
for name, plane in PLANES:
    os.lseek(f, 0x150, 0); os.write(f, struct.pack("<Q", (1 << 63) | (plane << 40) | (0x10 << 32)))
    os.lseek(f, 0x150, 0); v = struct.unpack("<Q", os.read(f, 8))[0]
    off = (v >> 21) & 0x7FF
    off -= 2048 if off >= 1024 else 0
    mv = round(off * 1000 / 1024, 1)
    nonzero |= abs(mv) >= 0.5
    print(f"{name:<9} {mv:+7.1f} мВ")
print("ВСІ НУЛІ" if not nonzero else "Є ненульові офсети")
sys.exit(3 if nonzero else 0)
