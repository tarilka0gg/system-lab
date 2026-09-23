# setup_var.efi — unlocking OverClocking Feature (HP Victus 16-r)

> ⛔ **Only for HP Victus 16-r1xxx, board 8C99, BIOS F.15.** The variable offsets (`CpuSetup:0x1D9`, `0x43`, `0x10E`, `0x381`, `0x7D`, `0x228`, `0x1CD`) and the "fingerprint" in Step 4 were taken from exactly this version. On a different board or BIOS version the `CpuSetup` layout differs: writing at these offsets will hit the wrong option and can leave the laptop **unbootable**, and without a programmer that's not recoverable.
> Before starting, check in Linux: `cat /sys/class/dmi/id/board_name` should be `8C99`, `cat /sys/class/dmi/id/bios_version` should be `F.15`. If either doesn't match, stop. Step 4 (fingerprint check) is mandatory — don't skip it.

Ready-made payload in this folder:
- `shellx64.efi` — UEFI Shell 2.2 (pbatard/UEFI-Shell 26H1), PE32+ x64
- `setup_var.efi` — datasone fork 0.3.1, PE32+ x64 (new named-variable logic)
- `sha256.txt` — checksums

> ⚠️ setup_var.efi addresses the variable **by NAME + numeric VAR_ID**, NOT by GUID.
> Confirming "the right CpuSetup" isn't done by GUID but by checking known bytes (see Step 4).

---

## Step 1 — Partitioning the FAT32 USB stick (from this OS, OpenRC)

Insert the stick, then **confirm it's the right one** (not nvme0n1!):

```
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL
```

The USB stick will show `TRAN=usb`. Say it's `/dev/sdX` (SUBSTITUTE YOUR OWN — everything will be wiped):

```
DEV=/dev/sdX                       # <-- CHECK THREE TIMES
umount ${DEV}* 2>/dev/null
sgdisk --zap-all "$DEV"            # clean GPT
sgdisk -n1:0:0 -t1:EF00 -c1:"EFI" "$DEV"   # one partition, type EFI System
partprobe "$DEV"; sleep 1
mkfs.vfat -F32 -n VICTUS ${DEV}1
```

(HP's UEFI reads both FAT32 GPT and MBR — GPT+EF00 is the most reliable.)

## Step 2 — Laying out the files

UEFI looks for a bootloader at `\EFI\BOOT\BOOTX64.EFI`. Put the Shell there —
then the stick boots straight into the Shell from the Boot Menu.

```
MNT=/mnt/victususb; mkdir -p "$MNT"
mount ${DEV}1 "$MNT"
mkdir -p "$MNT/EFI/BOOT"
cp shellx64.efi   "$MNT/EFI/BOOT/BOOTX64.EFI"   # autostarts the shell
cp setup_var.efi  "$MNT/setup_var.efi"          # tool at the root
sync; umount "$MNT"
```

## Step 3 — Booting into the Shell

1. Secure Boot is already **disabled** (confirmed: SecureBoot var = 0). If the BIOS reset it —
   disable it again: F10 at startup → Security → Secure Boot → Disable.
2. Insert the stick, press **F9** (Boot Menu) at the HP logo.
3. Pick USB (EFI). The UEFI Shell boots.
4. Find the stick's filesystem:
   ```
   map -r
   ```
   The stick is usually `FS0:` or `FS1:`. Switch to it:
   ```
   FS0:
   ls
   ```
   You should see `setup_var.efi`.

## Step 4 — VERIFYING the correct variable (MANDATORY before writing)

Read a few bytes and compare them against the reference below (values taken from
this same system's efivarfs dump). Reading changes nothing.

```
setup_var.efi CpuSetup:0x1D9
setup_var.efi CpuSetup:0x7D
setup_var.efi CpuSetup:0x228
setup_var.efi CpuSetup:0x1CD
setup_var.efi CpuSetup:0x43
```

Expected "fingerprint" (if it matches, this IS the right CpuSetup):

| offset | should be |
|--------|-----------|
| 0x1D9  | 0x00      |
| 0x7D   | 0x01      |
| 0x228  | 0x01      |
| 0x1CD  | 0x01      |
| 0x43   | 0x00      |

- If it matches — go to Step 5.
- If the tool says there are **multiple** variables named CpuSetup — it will ask
  for a VAR_ID. Run the fingerprint check for each id: `CpuSetup(0):0x7D`, `CpuSetup(1):0x7D`,
  etc., and pick the one whose bytes match the table.
- If NONE match — STOP, don't write. Reassess.

## Step 5 — Writing (OverClocking Feature only, this pass)

```
setup_var.efi CpuSetup:0x1D9=0x1
```

(if an id was needed, e.g. 0: `setup_var.efi CpuSetup(0):0x1D9=0x1`)

Verify right away:
```
setup_var.efi CpuSetup:0x1D9
```
Should show `0x1`.

## Step 6 — Reboot into Linux and verify (I do this)

Remove the stick, boot Gentoo/CachyOS. Then in the OS, check:
- rereading CpuSetup 0x1D9 from efivarfs — does `1` hold (most important)
- rdmsr 0x150 (OC mailbox) — did it start responding
- whether applying a voltage offset became possible

---

## Notes
- DON'T use `--reboot` until you're sure — a manual reboot and check is better.
- One write at a time. The locks (PROCHOT/HwP/Tcc) and power limits go in a separate pass
  AFTER confirming that 0x1D9 held.
- Backup of Setup variables: `~/victus-unlock/backup/` + `restore.sh` (efivarfs path,
  in case the OS ever allows a write; for a setup_var rollback, write
  the old value back with the same tool).
