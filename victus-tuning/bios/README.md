# BIOS: patch description (no images, no dumps)

**Target:** HP Victus 16-r1xxx, board **8C99**, BIOS **F.15** (01/13/2025), Insyde H2O. The patch enables `OverClocking Feature` and clears the locks that make the OC mailbox (MSR `0x150`) ignore writes. See `docs/journal.md` (sessions 5–12, 21) for the search history.

## What's here and what isn't

- **Here:** three CSVs of byte-level changes (`patch-*.csv`: offset, old value, new value, which copy of CpuSetup), the `apply_patch.py` script, and the description in this file.
- **No images, no NVRAM dumps.** A dump pulled with a programmer contains serial numbers, the board UUID, the ME region, and HP/Insyde code, and its SHA-256 would differ for another user anyway. So the hashes of my dumps aren't published here — there's nothing to compare them against. `Setup`-variable dumps also aren't published: their layout depends on the BIOS version, and restoring a dump from a different version breaks the settings.
- **Hash of the official file:** `08C99.bin` (noted in my journal as the official HP image with no live NVRAM), SHA-256 `29ee5c2a60a7930c371ebcdaa3c303061cac07d782aa6ab9755f054d38b16341`. I haven't checked it against HP's site, so verify the source yourself.

## Patches

| CSV | Bytes | What it does |
|---|---|---|
| `patch-stock-to-unlock.csv` | 6 | factory state → 3 locks cleared (`0x43` CFG Lock, `0x10E` OC Lock, `0x381`) |
| `patch-unlock-to-oc.csv` | 14 | `0x1D9` OverClocking Feature = 1, locks `0x43`, `0x10E`, `0x381` = 0 across all 5 copies of CpuSetup |
| `patch-unlock-to-oc-max.csv` | 28 | same, plus `0x7D` PROCHOT Lock, `0x228` HwP Lock, `0x1CD` Tcc Offset Lock = 0. **This is what's flashed on my machine.** |

## Usage

```bash
python3 apply_patch.py --bios-version F.15 my-dump.bin patch-unlock-to-oc.csv result.bin
```

The script refuses to run if: the size isn't 16 MiB, the BIOS version isn't confirmed, the output file already exists, or **even one offset doesn't hold the expected old value**. It doesn't flash anything and doesn't modify anything in place. The offsets were taken from **my** dump; on someone else's they'll most likely not match, and the script will stop. That's a safeguard, not a bug.

## Warnings

- My values (`0x7D`, `0x228`, `0x1CD`) became writable, but I haven't investigated thermal-protection behavior.
- ⛔ **The offsets in these CSVs are only valid for BIOS F.15 on the HP 8C99 board.** On a different board or BIOS version the same offsets will land on different data, and flashing such an image can leave the laptop **unbootable**. Without a programmer that's not recoverable. `apply_patch.py` only guards against a byte mismatch in the dump, not against the dump being from a different version — you confirm `--bios-version F.15` yourself, after checking `cat /sys/class/dmi/id/bios_version`.
- Flashing without a backup of the stock image can also leave the laptop unbootable.
- This is a description of my own experiments, not instructions and not legal advice about firmware modification rights.
