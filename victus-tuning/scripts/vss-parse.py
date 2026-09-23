#!/usr/bin/env python3
"""Парсер Insyde H2O VSS variable store (authenticated header, 0x3C байт).

Layout змінної:
  +0x00 StartId (2) = 0x55AA
  +0x02 State (1)
  +0x03 Reserved (1)
  +0x04 Attributes (4)
  +0x08 MonotonicCount (8)
  +0x10 TimeStamp EFI_TIME (16)
  +0x20 PubKeyIndex (4)
  +0x24 NameSize (4)
  +0x28 DataSize (4)
  +0x2C VendorGuid (16)
  +0x3C Name (UCS2), далі Data
"""
import struct, uuid, re, sys

HDR = 0x3C
# стани VSS
ST = {0x3F: 'ADDED', 0x3E: 'IN_DELETED', 0x7F: 'HDR_VALID_ONLY',
      0x3C: 'DELETED', 0xFF: 'ERASED', 0x3D: 'DELETED?'}


def parse_store(d, base, verbose=False, want=None):
    """Розбирає один $VSS стор. Повертає список змінних."""
    if d[base:base + 4] != b'$VSS':
        return None
    size, fmt, state = struct.unpack_from('<IBB', d, base + 4)
    out = {'base': base, 'size': size, 'format': fmt, 'state': state, 'vars': []}
    end = min(base + size, len(d))
    off = base + 0x10
    while off + HDR <= end:
        startid = struct.unpack_from('<H', d, off)[0]
        if startid != 0x55AA:
            break
        vstate = d[off + 2]
        attrs, = struct.unpack_from('<I', d, off + 4)
        namesz, datasz = struct.unpack_from('<II', d, off + 0x24)
        if namesz > 0x400 or datasz > 0x100000:
            break
        gb = d[off + 0x2C:off + 0x3C]
        try:
            g = uuid.UUID(bytes_le=gb)
        except Exception:
            g = None
        noff = off + HDR
        try:
            nm = d[noff:noff + namesz].decode('utf-16-le').rstrip('\x00')
        except Exception:
            nm = '<undecodable>'
        doff = noff + namesz
        v = {'hdr': off, 'state': vstate, 'attrs': attrs, 'name': nm,
             'guid': str(g) if g else None, 'datasz': datasz, 'data_off': doff}
        out['vars'].append(v)
        if verbose and (want is None or nm in want):
            print(f"    {nm:<24} state={vstate:#04x}({ST.get(vstate,'?'):<14})"
                  f" attrs={attrs:#x} size={datasz:<6} hdr@{off:#x} DATA@{doff:#x}")
        # Insyde пакує змінні впритул, БЕЗ вирівнювання. Але трапляються
        # варіанти з padding — якщо впритул не 0x55AA, пробуємо вирівняні.
        nxt = off + HDR + namesz + datasz
        for cand in (nxt, (nxt + 1) & ~1, (nxt + 3) & ~3, (nxt + 7) & ~7):
            if cand + 2 <= end and struct.unpack_from('<H', d, cand)[0] == 0x55AA:
                nxt = cand
                break
        off = nxt
    return out


def find_stores(d):
    """Знаходить усі правдоподібні $VSS стори."""
    res = []
    for m in re.finditer(b'\\$VSS', d):
        b = m.start()
        if b + 0x12 > len(d):
            continue
        size = struct.unpack_from('<I', d, b + 4)[0]
        if not (0x100 <= size <= 0x400000):
            continue
        if struct.unpack_from('<H', d, b + 0x10)[0] != 0x55AA:
            continue
        res.append(b)
    return res


if __name__ == '__main__':
    path = sys.argv[1]
    want = set(sys.argv[2:]) or None
    d = open(path, 'rb').read()
    print(f"### {path}  ({len(d)} байт, {len(d):#x})")
    for b in find_stores(d):
        s = parse_store(d, b, verbose=True, want=want)
        hit = [v for v in s['vars'] if want is None or v['name'] in want]
        print(f"\n--- $VSS @ {b:#x} size={s['size']:#x} fmt={s['format']:#x} "
              f"state={s['state']:#x} | змінних={len(s['vars'])} "
              f"| збігів={len(hit)}")
        for v in hit:
            print(f"    >> {v['name']} guid={v['guid']} datasz={v['datasz']} "
                  f"DATA@{v['data_off']:#x} state={v['state']:#04x}")
