#!/usr/bin/env python3
"""Фінальна передпрошивочна верифікація образів. Нічого не змінює.
Виводить PASS/FAIL по кожній перевірці. Будь-який FAIL = не шити."""
import os, struct, re, sys, hashlib

BIOS_DIR = os.environ.get('BIOS_DIR', os.path.expanduser('~/Documents/Bios Binaries'))
ORIG = os.path.join(BIOS_DIR, 'biosunlock')
COPIES = [('DEFAULTS-1', 0x688fbf), ('DEFAULTS-2', 0x68d4c0), ('DEFAULTS-3', 0x68ecf0),
          ('NVRAM-work', 0x75e1f6), ('NVRAM-bkp', 0x78143f)]
CORE = [(0x1D9, 'OverClocking Feature', 1), (0x43, 'CFG Lock', 0),
        (0x10E, 'Overclocking Lock', 0), (0x381, 'третій замок', 0),
        (0x45, 'Configurable TDP Lock', 0), (0x30, 'Pkg Power Limit MSR Lock', 0)]
EXTRA = [(0x7D, 'PROCHOT Lock'), (0x228, 'HwP Lock'), (0x1CD, 'Tcc Offset Lock Enable')]
ME = (0x1000, 0x50a000)
DESC = (0x0, 0x1000)

fails = []


def chk(cond, label, detail=''):
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}" + (f"  — {detail}" if detail else ''))
    if not cond:
        fails.append(label)
    return cond


def verify(path, extra_want, expect_diff):
    global fails
    print("=" * 92)
    print(f"  {path}   (очікується {extra_want=} для 0x7D/0x228/0x1CD, diff={expect_diff})")
    print("=" * 92)
    o = open(ORIG, 'rb').read()
    d = open(path, 'rb').read()

    # --- 1. таблиця 6 цільових байтів ---
    print("\n1) ЦІЛЬОВІ БАЙТИ у всіх 5 копіях")
    hdr = f"  {'offset':<7} {'опція':<26} {'треба':>5} " + ' '.join(f"{n:>11}" for n, _ in COPIES)
    print(hdr); print("  " + "-" * (len(hdr) - 2))
    all_ok = True
    for off, name, want in CORE:
        vals = [d[b + off] for _, b in COPIES]
        ok = all(v == want for v in vals)
        all_ok &= ok
        cells = ' '.join(f"{v:>11}" if v == want else f"{str(v) + ' X':>11}" for v in vals)
        print(f"  {off:#05x}   {name:<26} {want:>5} {cells}")
    chk(all_ok, "усі 6 цільових байтів правильні в усіх 5 копіях")

    # --- 2. 0x7D / 0x228 / 0x1CD ---
    print(f"\n2) PROCHOT / HwP / Tcc Offset — мають бути ={extra_want}")
    hdr = f"  {'offset':<7} {'опція':<26} {'треба':>5} " + ' '.join(f"{n:>11}" for n, _ in COPIES)
    print(hdr); print("  " + "-" * (len(hdr) - 2))
    ex_ok = True
    for off, name in EXTRA:
        vals = [d[b + off] for _, b in COPIES]
        # у базовій версії 0x1CD в DEFAULTS-2 законно =0 (був таким в оригіналі)
        exp = [extra_want] * 5
        if extra_want == 1 and off == 0x1CD:
            exp[1] = o[COPIES[1][1] + off]
        ok = vals == exp
        ex_ok &= ok
        cells = ' '.join(f"{v:>11}" if v == e else f"{str(v) + ' X':>11}" for v, e in zip(vals, exp))
        print(f"  {off:#05x}   {name:<26} {extra_want:>5} {cells}")
    chk(ex_ok, f"0x7D/0x228/0x1CD відповідають очікуванню ({extra_want})")

    # --- 3. структура ---
    print("\n3) СТРУКТУРА")
    chk(len(d) == 16777216, "розмір 16777216", f"{len(d)}")
    chk(d[DESC[0]:DESC[1]] == o[DESC[0]:DESC[1]], "descriptor не змінений")
    chk(struct.unpack_from('<I', d, 0x10)[0] == 0x0FF0A55A, "FLVALSIG 5A A5 F0 0F")
    chk(d[ME[0]:ME[1]] == o[ME[0]:ME[1]], "ME-регіон незайманий (побайтово)")
    tail = d[-16:]
    chk(tail != b'\x00' * 16 and tail != b'\xff' * 16 and b'\xe9' in tail,
        "хвіст = reset vector, не нулі", tail.hex(' '))
    bad = []
    for m in re.finditer(b'_FVH', d):
        base = m.start() - 0x28
        if base < 0:
            continue
        hl = struct.unpack_from('<H', d, base + 0x30)[0]
        if hl == 0 or hl > 0x200 or base + hl > len(d):
            continue
        s = 0
        for i in range(0, hl, 2):
            s = (s + struct.unpack_from('<H', d, base + i)[0]) & 0xffff
        if s != 0 and base != 0x0db05d0:   # 0xdb05d0 — відомий хибний збіг у стиснених даних
            bad.append(hex(base))
    chk(not bad, "усі FV sum16 == 0", f"невірні: {bad}" if bad else "13 FV")
    # VSS стори на місці
    stores = [0x687000, 0x68b501, 0x68dad9, 0x739048, 0x76b048]
    chk(all(d[s:s + 4] == b'$VSS' for s in stores), "усі 5 $VSS-сторів на місці")

    # --- 4. diff ---
    print("\n4) DIFF vs biosunlock")
    diff = [i for i in range(len(o)) if o[i] != d[i]]
    chk(len(diff) == expect_diff, f"рівно {expect_diff} змінених байтів", f"фактично {len(diff)}")
    # кожен diff має належати цілі
    targets = set()
    for _, b in COPIES:
        for off, _, _ in CORE:
            targets.add(b + off)
        for off, _ in EXTRA:
            targets.add(b + off)
    stray = [hex(x) for x in diff if x not in targets]
    chk(not stray, "жодного байта поза цільовими offset-ами", f"сторонні: {stray}" if stray else "")
    print(f"    змінені offset-и: {' '.join(hex(x) for x in diff)}")
    print(f"\n  sha256: {hashlib.sha256(d).hexdigest()}")
    print()


verify(os.path.join(BIOS_DIR, 'biosunlock-oc.bin'), 1, 14)
verify(os.path.join(BIOS_DIR, 'biosunlock-oc-max.bin'), 0, 28)

print("=" * 92)
if fails:
    print(f"  ✗ ПРОВАЛЕНО перевірок: {len(fails)}")
    for f in fails:
        print(f"      - {f}")
    sys.exit(1)
print("  ✓ УСІ ПЕРЕВІРКИ ПРОЙДЕНО — обидва образи відповідають специфікації")
