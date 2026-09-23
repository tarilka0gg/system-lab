#!/usr/bin/env python3
"""Застосовує CSV-патч (patch-*.csv) до ВЛАСНОГО офлайн-дампа BIOS-чипа.

  apply_patch.py --bios-version F.15 ДАМП.bin patch-unlock-to-oc.csv ВИХІД.bin

Гарантії, заради яких скрипт існує:
  * дамп не змінюється, результат пишеться в НОВИЙ файл (існуючий не перезаписується);
  * перед записом перевіряється, що за КОЖНИМ офсетом лежить очікуване старе значення
    (колонка `old`). Хоч один збіг відсутній — скрипт відмовляється й нічого не пише;
  * розмір дампа має бути рівно 16 MiB;
  * версію BIOS треба підтвердити вручну (`--bios-version F.15`): CSV зняті з дампа
    плати HP 8C99 з BIOS F.15, на інших версіях розкладення змінних інше.
Скрипт нічого не прошиває. Що робити з результатом, вирішуєш ти.
"""
import argparse, csv, hashlib, os, sys

ap = argparse.ArgumentParser()
ap.add_argument("--bios-version", required=True)
ap.add_argument("dump"); ap.add_argument("patch"); ap.add_argument("out")
a = ap.parse_args()
if a.bios_version != "F.15":
    sys.exit("ВІДМОВА: патч знято для BIOS F.15 (плата HP 8C99); інша версія — інше розкладення змінних")
if os.path.exists(a.out):
    sys.exit(f"ВІДМОВА: {a.out} вже існує, перезаписувати не буду")
data = bytearray(open(a.dump, "rb").read())
if len(data) != 16 * 1024 * 1024:
    sys.exit(f"ВІДМОВА: розмір {len(data)} байт, очікується 16777216")
rows = list(csv.DictReader(open(a.patch, newline="")))
bad = []
for r in rows:
    off, old, new = int(r["offset"], 16), int(r["old"], 16), int(r["new"], 16)
    if data[off] != old:
        bad.append((r["offset"], r["old"], f"0x{data[off]:02x}"))
if bad:
    print(f"ВІДМОВА: {len(bad)} з {len(rows)} офсетів не мають очікуваного старого значення (нічого не записано):")
    for off, exp, got in bad[:10]:
        print(f"  {off}: очікувалось {exp}, є {got}")
    sys.exit(2)
for r in rows:
    data[int(r["offset"], 16)] = int(r["new"], 16)
open(a.out, "wb").write(data)
print(f"OK: змінено {len(rows)} байтів -> {a.out}")
print("sha256:", hashlib.sha256(data).hexdigest())
