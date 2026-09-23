#!/usr/bin/env python3
"""Витягує з розпакованого IFR усі опції варстора CpuSetup і резолвить їхні назви
через HII string package. Мета — знайти ВСІ *Lock, а не лише відомі з карти."""
import struct, uuid, pickle, sys, re

CPUGUID = uuid.UUID('b08f97ff-e6e8-4193-a997-5e9e9b0adb32').bytes_le

# опкоди-питання з EFI_IFR_QUESTION_HEADER
QOPS = {0x05: 'ONE_OF', 0x06: 'CHECKBOX', 0x07: 'NUMERIC',
        0x08: 'PASSWORD', 0x09: 'ORDERED_LIST', 0x0A: 'STRING'}


def parse_strings(b, pos):
    """Розбирає EFI_HII_STRING_PACKAGE_HDR за зміщенням pos -> {id: text}."""
    hdr = struct.unpack_from('<I', b, pos)[0]
    plen, ptype = hdr & 0xFFFFFF, (hdr >> 24) & 0xFF
    if ptype != 0x02:
        return {}
    hdrsize, strinfo = struct.unpack_from('<II', b, pos + 4)
    out, sid, o, end = {}, 1, pos + strinfo, pos + plen
    while o < end and o < len(b):
        bt = b[o]; o += 1
        if bt == 0x00:                      # SIBT_END
            break
        elif bt == 0x14:                    # SIBT_STRING_UCS2
            e = o
            while e + 1 < len(b) and b[e:e + 2] != b'\x00\x00':
                e += 2
            out[sid] = b[o:e].decode('utf-16-le', errors='replace')
            sid += 1; o = e + 2
        elif bt == 0x10:                    # SIBT_DUPLICATE
            o += 2; sid += 1
        elif bt == 0x20:                    # SIBT_SKIP2
            sid += struct.unpack_from('<H', b, o)[0]; o += 2
        elif bt == 0x21:                    # SIBT_SKIP1
            sid += b[o]; o += 1
        elif bt in (0x11, 0x12, 0x13):      # font/наскрізні
            o += 1
        else:
            break
    return out


def main():
    blobs = pickle.load(open(sys.argv[1], 'rb'))
    strings, questions = {}, []
    for b in blobs:
        # 1) усі string-пакети
        for m in re.finditer(rb'[\x00-\xff]{3}\x02', b):
            pos = m.start()
            hdr = struct.unpack_from('<I', b, pos)[0]
            plen = hdr & 0xFFFFFF
            if not (0x100 < plen < 0x400000) or pos + plen > len(b):
                continue
            try:
                hs, si = struct.unpack_from('<II', b, pos + 4)
            except Exception:
                continue
            if not (0x30 <= hs <= 0x100 and hs <= si < plen):
                continue
            got = parse_strings(b, pos)
            if len(got) > 50:
                for k, v in got.items():
                    strings.setdefault(k, v)
        # 2) варстор CpuSetup -> VarStoreId
        for m in re.finditer(re.escape(CPUGUID), b):
            s = m.start() - 2
            if s < 0 or b[s] != 0x24:
                continue
            ln = b[s + 1]
            vsid, size = struct.unpack_from('<HH', b, s + 18)
            # 3) сканувати IFR навколо цього варстора
            lo, hi = max(0, s - 0x200000), min(len(b), s + 0x200000)
            o = lo
            while o + 14 < hi:
                op, l = b[o], b[o + 1]
                if l < 2:
                    o += 1; continue
                if op in QOPS and o + 13 < len(b):
                    q_vsid, q_off = struct.unpack_from('<HH', b, o + 8)
                    if q_vsid == vsid:
                        prompt = struct.unpack_from('<H', b, o + 2)[0]
                        questions.append((q_off, prompt, QOPS[op]))
                o += l
    # дедуп
    seen, res = set(), []
    for off, pr, kind in questions:
        if (off, pr) in seen:
            continue
        seen.add((off, pr))
        res.append((off, strings.get(pr, f'<str#{pr}>'), kind))
    res.sort()
    print(f"# рядків у таблиці: {len(strings)}, унікальних питань CpuSetup: {len(res)}\n")
    print(f"{'offset':<8} {'тип':<10} назва")
    print("-" * 70)
    for off, name, kind in res:
        if 'lock' in name.lower() or 'overclock' in name.lower():
            print(f"{off:#06x}   {kind:<10} {name}")
    print("\n=== усі питання (для контролю зсувів) ===")
    for off, name, kind in res[:0]:
        pass


if __name__ == '__main__':
    main()
