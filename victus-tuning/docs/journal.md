# Victus Unlock — journal

## 2026-07-24 — Session 1: recon, backup, runtime write attempt

### Phase 0 — backup
- Folder: `backup/20260724-162905/`
- Dumps of three variables from efivarfs (via `cat`, since `cp` gives `Illegal seek`):
  - CpuSetup 965 B, SaSetup 1404 B, Setup 2993 B (including 4 B of attributes)
  - `manifest.txt` — SHA256, checked with `sha256sum -c` = OK
- MSR snapshot: `msr-snapshot.txt`
- `restore.sh` — ready, `sh -n` OK. Writes the whole buffer back to efivarfs, with `chattr -i`.

### Phase 1 — state (every bit counted explicitly with python3)
Variables (CpuSetup):
- 0x1D9 OverClocking Feature = **0** (disabled) ← the master switch
- 0x43 CFG Lock = 0, 0x10E OC Lock = 0, 0x45 TDP Lock = 0, 0x30 PkgPwr MSR Lock = 0
- 0xC7 EC Turbo Control Mode = 0
- All voltage offsets (P/Ring/E-L2) = 0, prefix = 0

Live system:
- CFG Lock (0xE2 b15) = **0 — cleared** (confirmed)
- OC Lock (0x194 b20) = **0 — cleared**
- OC mailbox (0x150) reads as 0
- RAPL: PL1=PL2=352 → 44.0 W, enable=1, clamp=1; unit 0x606 pu=3 (0.125 W)

User's hypothesis confirmed: the locks were cleared earlier, but **0x1D9 was never enabled**,
so there was nothing to apply the offsets to. Didn't look for intel-undervolt traces (per instruction).

### Correction about 44 W (important)
- Measurement of ACTUAL draw under full load (24×yes, energy counter 0x611):
  **44.0 W steady draw** — matches the limit. So the clamp is real *right now*.
- BUT: AC is connected (`ACAD online=1`), and `platform_profile = balanced`
  (options: low-power / balanced / **performance**). governor = powersave.
- The most likely cause of 44 W is the **`balanced` profile, not a hard EC lock.**
  The 120 W from the user's memory was probably on `performance`.
- Did NOT switch the profile (per the "don't touch anything else" instruction). Test for later:
  `echo performance > /sys/firmware/acpi/platform_profile` and remeasure.

### Attempt to write 0x1D9: 0 → 1 (authorized) — FAILED
- immutable cleared (`chattr -i` OK).
- Methods tried: python r+b+seek (not seekable), open('wb') (O_TRUNC → EROFS),
  os.open(O_WRONLY)+os.write (EROFS), dd bs=965 (EROFS).
- The byte stayed 0. The write was rejected right at `write()`.

### EROFS diagnosis
- lockdown = [none], Secure Boot = 0, immutable cleared, mount = rw.
- The variable has the RT attribute (0x7), but the firmware rejects runtime `SetVariable`.
- CONCLUSION: Insyde H2O only allows writing Setup variables in a **boot-services**
  context (inside the BIOS / UEFI Shell), not from the OS runtime.
  **The efivarfs path for these variables is blocked at the firmware level.**

## 2026-07-24 — Session 2: profile-sweep (44 W hypothesis)

Script `profile-sweep.sh` (governor->performance temporarily, restored to balanced/powersave).
Script bug: `rdmsr -0 -d` gave decimals with leading zeros -> the draw column in the CSV
came out empty, but the raw energy counters survived in the logs, draw was reconstructed by hand.

| profile      | draw  | PL1  | freq     | temp |
|--------------|-------|------|----------|------|
| low-power    | 45.0 W| 44 W | 2540 MHz | 68°C |
| balanced     | 45.0 W| 44 W | 2550 MHz | 65°C |
| performance  | 44.9 W| 44 W | 2545 MHz | 65°C |

CONCLUSION: platform_profile does NOT affect power. The 44-45 W ceiling is real
and profile-independent. Per the user's criterion -> setup_var.efi is needed.
Caveat: `yes` is a scalar workload; draw pins exactly at PL1 and freq stays
only ~2540 MHz (throttle-like) -> almost certainly a real clamp, but an
AVX2 stressor would confirm it more firmly. The memory of 120 W didn't reproduce
on any profile -> likely a different BIOS/measurement state back then.

### Next step
- Move to **`setup_var.efi` from the UEFI Shell** (Secure Boot already off).
  Needed both for the undervolt (0x1D9) and for power limits (Phase 4) — both paths
  run into the same firmware restriction on writing Setup variables from runtime.
- No data changed — the system is in the same state as at the start of the session. Backup valid.

### What's NOT proven / still to check
- Didn't test a write to a throwaway variable → formally hasn't ruled out "efivarfs globally RO"
  vs "this specific variable is firmware-RO". Both lead to setup_var.efi, so it's not critical.
- The effect of platform_profile=performance on PL — not measured.

## 2026-07-24 — Session 3: payload for setup_var.efi ready

Folder `usb-payload/`:
- shellx64.efi  — UEFI Shell 2.2 (pbatard/UEFI-Shell 26H1), PE32+ x64, 1137728 B
- setup_var.efi — datasone 0.3.1, PE32+ x64, 101376 B
- sha256.txt, README-flash.md (step-by-step instructions)

IMPORTANT: the first download of Shell.efi from edk2 master raw returned HTML (the path was removed
from master) — replaced with pbatard/UEFI-Shell. setup_var.efi 0.3.1 addresses the variable
by NAME+VAR_ID, NOT by GUID. Syntax: `setup_var.efi CpuSetup:0x1D9=0x1`.
Verifying the right CpuSetup is done by matching a byte fingerprint against the efivarfs dump
(0x1D9=0, 0x7D=1, 0x228=1, 0x1CD=1, 0x43=0).

The USB stick isn't plugged in yet (system only sees nvme0n1). We'll do the FAT32
partitioning once it's plugged in — the device will be identified by TRAN=usb, so nvme isn't touched.
This pass: write ONLY 0x1D9=0x1, reboot, verify it holds.

## 2026-07-24 — Session 4: 44 W SOLVED — it's throttled, not the EC

TEST 1 (throttled running): wrmsr 0x610=150W -> rolled back to 44W after ~5s.
  => userspace reapplies it. Found: sys-power/throttled-0.12, PID 2526,
     OpenRC [started], /etc/throttled.conf [AC] PL1=44 PL2=44 Update=5s.
  intel-undervolt-1.7 is also installed, but enable=no; throttled UNDERVOLT.AC=0.

TEST 1b (throttled stopped, MSR 0x610=150W): held, BUT draw=44W, freq 2108.
  => there's a SECOND, static cap. Found: MMIO RAPL MCHBAR+0x59A0
     (MCHBAR base=0xfedc0000) = 0x0042816000dd8160 = PL1=PL2=44W, LOCK=0.
     MMIO takes priority over MSR -> so raising only the MSR did nothing.
     throttled writes both; after stop, MMIO stayed at 44W statically.

TEST final (MSR=150 + MMIO=150): draw 44->53.7W, freq 2108->2327, temp 75C.
  Didn't go higher because `yes` is a light load; under AVX2 it would pull toward ~150W.

CONCLUSION: 44 W is 100% a software cap (throttled writing MSR+MMIO RAPL).
  No EC/BIOS lock at all. LOCK=0. Everything is volatile (reboot/throttled restart -> 44W).
  PHASE 4 (power limits via BIOS) IS NOT NEEDED — the limits are written from the OS.
  The clean fix for power limits = editing /etc/throttled.conf [AC] PL1/PL2 (+ restart).
  The 120W memory: consistent — that was a state with a higher/different throttled limit.

Baseline restored: throttled restart -> MSR+MMIO back to 44W, service running.
My changes were volatile; a reboot would have reset them anyway.

### What's still needed for the USB stick (0x1D9)
  Power limits are solved by software. The stick/setup_var.efi is still needed ONLY if
  undervolting via the OC mailbox doesn't apply without OverClocking Feature=1.
  (Open question: does throttled/intel-undervolt undervolt a locked CPU via
   MSR 0x150 without 0x1D9 — maybe the stick isn't even needed. We'll test empirically:
   try -50mV via throttled UNDERVOLT.AC and see whether Vcore dropped.)

## 2026-07-24 — Session 5: undervolt test without the BIOS unlock — FAILED (the stick is needed)

Method: throttled UNDERVOLT.AC, Vcore from MSR 0x198 b47:32/8192, median of 12 samples/60s.
The shared VccIA rail is accounted for: CORE+CACHE+ANALOGIO offset together -50mV.

| state       | Vcore med | freq     | draw | temp |
|-------------|-----------|----------|------|------|
| baseline    | 817 mV    | 2100 MHz | 44 W | 69°C |
| -50mV (uv)  | 819 mV    | 2167 MHz | 44 W | 69°C |

Vcore did NOT drop. Checked why:
- intel-undervolt read: all domains -0.00 mV (offset not in the mailbox)
- manual mailbox 0x150 read plane0 = 0x0
- intel-undervolt apply -> "Values do not equal" (wrote it, read back 0, didn't apply)

TWO independent tools (throttled, intel-undervolt) CANNOT apply
the undervolt. The OC mailbox (0x150) silently discards offset writes.

CONCLUSION (final, confirms the original hypothesis):
  The undervolt does NOT work without OverClocking Feature=1. MSR 0x150 is inactive.
  => setup_var.efi / 0x1D9 IS NEEDED. Payload ready (usb-payload/).

Baseline restored: throttled.conf from backup, service running, 44W.

### Plan going forward after sessions 4-5
  power limits — done via SOFTWARE (throttled.conf), Phase 4 through the BIOS not needed.
  undervolt   — needs the BIOS unlock of 0x1D9 -> the USB stick.
  Order: stick+0x1D9 first, reboot, verify the mailbox comes alive,
         then undervolt + power limits together (VccIA), then PL steps.

## 2026-07-24 — Session 6: sdb USB stick prepared for setup_var.efi

Side note: the sda(128GB)/sdb(64GB) sticks were reshuffled at the user's request —
Ventoy+8 ISOs moved to sda (SHA256 verified, one corrupted copy of linuxmint.iso.1
recopied and confirmed), sdb fully wiped (wipefs+dd of the edges) and freed up.

Now sdb(64GB) is partitioned for setup_var.efi:
  GPT, partition1 type EF00 "EFI", FAT32, label VICTUS.
  \EFI\BOOT\BOOTX64.EFI = shellx64.efi (autostarts the UEFI Shell)
  \setup_var.efi, \README-flash.md — at the root.
  SHA256 checked against usb-payload/sha256.txt — matches.

PROCESS ERROR (fixed): the first `mount /dev/sdb1` failed with
"FAT-fs: IO charset iso8859-1 not found" (no nls_iso8859_1 in the kernel).
The cp commands after the failed mount silently wrote the files into the LOCAL folder
/mnt/victususb on nvme (not the stick!) — deleted, redone correctly
with `mount -t vfat -o iocharset=utf8`.

The stick is physically ready. Still to do: actually going into the UEFI Shell and writing
CpuSetup 0x1D9=0x1 (Steps 4-5 of README-flash.md) — the user does this
by hand on reboot (F9 -> USB -> Shell), verifying the "fingerprint" before writing.

## 2026-07-24 — Session 7: analysis of the dumps for the 0x1D9 patch (READ ONLY)

### Found THREE images (not two), all in ~/ rather than ~/victus-unlock/
| file | size | what it is |
|---|---|---|
| 08C99.bin    | 0xFA0000 (16384000) | official HP, WITHOUT live NVRAM |
| biosstock.bin| 0xF90000 (16318464) | offline chip dump, STOCK (pre-patch) |
| biosunlock   | 0xE20000 (14811136) | the same dump + 6 patched bytes = dump A |

biosunlock vs biosstock: common prefix up to 0x68d503, only **6 differing bytes**.

### Origin: offline dumps from a programmer
The ME region (0x1000-0x509FFF) has real content (entropy 6.60, $FPT@0x1aa000,
17× $MN2). A software dump from the OS would read ME as 0xFF. biosstock has live NVRAM
with a deletion history (519 variables) => this is a genuine chip dump, not an image from a website.

### NVRAM structure (Insyde authenticated VSS, header 0x3C)
Variable layout: StartId(2) State(1) Rsvd(1) Attrs(4) Monotonic(8) TimeStamp(16)
PubKeyIndex(4) NameSize(4)@+0x24 DataSize(4)@+0x28 GUID(16)@+0x2C Name@+0x3C.
IMPORTANT: variables are packed BACK-TO-BACK, with no alignment. Parser: victus-unlock/vss-parse.py

Five copies of CpuSetup (GUID b08f97ff-..., datasize=961):
| copy | $VSS store | DATA offset | 0x1D9 abs |
|---|---|---|---|
| DEFAULTS-1 | 0x687000 | 0x688fbf | 0x689198 |
| DEFAULTS-2 | 0x68b501 | 0x68d4c0 | 0x68d699 |
| DEFAULTS-3 | 0x68dad9 | 0x68ecf0 | **0x68eec9** |
| NVRAM-1 (working, 519 variables) | 0x739048 | 0x75e1f6 | 0x75e3cf |
| NVRAM-2 (backup, 125 variables)  | 0x76b048 | 0x78143f | 0x781618 |
NVRAM-2 = NVRAM-1 + 0x32000 (working+backup, as expected).
Both NVRAM copies live in an FV with GUID fff12b8d-... (EFI_SYSTEM_NV_DATA_FV).

### WHAT THE USER PATCHED LAST TIME (stock -> unlock), 6 bytes 1->0
| abs offset | copy | var.offset | option |
|---|---|---|---|
| 0x68d503 | DEFAULTS-2 | 0x43  | CFG Lock |
| 0x68d5ce | DEFAULTS-2 | 0x10E | Overclocking Lock |
| 0x68d841 | DEFAULTS-2 | 0x381 | (third lock, not in our tables) |
| 0x68ed33 | DEFAULTS-3 | 0x43  | CFG Lock |
| 0x68edfe | DEFAULTS-3 | 0x10E | Overclocking Lock |
| 0x68f071 | DEFAULTS-3 | 0x381 | (third lock) |
**0x1D9 was NOT touched** — this exactly confirms the user's memory ("cleared three locks,
but never found the master switch"). Only DEFAULTS-2 and -3 were patched, not NVRAM.

### STORE VERIFICATION — the fingerprint matched
Live system (efivarfs): 1D9=0 7D=1 228=1 1CD=1 43=0 10E=0 45=0 30=0 381=0
| copy | fingerprint 1D9/7D/228/1CD/43 |
|---|---|
| DEFAULTS-1 | 0/1/1/1/1 |
| DEFAULTS-2 | 0/1/1/0/0 |
| **DEFAULTS-3** | **0/1/1/1/0  <== EXACT MATCH on all 9 bytes** |
| NVRAM-1/-2 | 0/1/1/1/1 (old, pre-patch state) |

Full body comparison of DEFAULTS-3 vs live: 79/961 differences, ALL of them fields the BIOS
fills in from CPU runtime capabilities (0xCC-0x10D turbo ratio 52/52/48/48,
0x1=24 threads, etc.), zero in the defaults. There's NO layout shift — the offsets are the same.
=> The store is identified with 100% confidence: DEFAULTS-3 is what backs the live CpuSetup.

### CRC / checksums — NO RECALCULATION NEEDED
- Standard VSS has no CRC on the variable body.
- FV header checksum (offset +0x32) covers ONLY the 0x48-byte header, not the data.
  Confirmed: sum16=0x0000 (OK) in BOTH files, values 0x28c5/0xe6c7 IDENTICAL
  in stock and unlock => the previous 6-byte patch didn't need a recalculation.
- Empirical proof: the 0x43/0x10E/0x381 patch was flashed and WORKS on the live system
  (CFG Lock genuinely cleared, MSR 0xE2 bit15=0). If there were a checksum, it wouldn't have booted.

### ⚠️ MAIN PROBLEM: all three files are TRUNCATED
The descriptor says the BIOS region is 0x680000-0xFFFFFF (ending at 16MB = 0x1000000).
| file | missing | where it cuts off |
|---|---|---|
| 08C99.bin | 0x60000 | in the padding (tail of 53628× 0xFF) — a soft cutoff |
| biosstock.bin | 0x70000 | IN THE MIDDLE of x86 code (8a 86 04 02 00 00 88 45 fe eb 12) |
| biosunlock | 0x1E0000 | IN THE MIDDLE of data, 1.87 MB missing |
None of them is a complete 16MB image. biosunlock is missing almost 2 MB of real content.

### CONCLUSIONS
1. The base for the patch is **biosunlock** (contains the previous 3 patches + live NVRAM),
   but ONLY AFTER getting a fresh COMPLETE 16MB offline dump.
2. Target offsets for 0x1D9 (per the current biosunlock): DEFAULTS-3 = 0x68eec9
   (proven working path), plus DEFAULTS-2 = 0x68d699 for redundancy.
   NVRAM copies (0x75e3cf / 0x781618) — optional.
3. CRC does NOT need recalculating.
4. THESE FILES CANNOT BE FLASHED AS-IS — they're truncated. A fresh full dump
   from the CH341A is needed, cross-checked over 2-3 reads, and verify on it that the offsets
   match (the structure could shift if the BIOS version differs).

Nothing patched, nothing flashed. All operations were read-only.

## 2026-07-24 — Session 8: RE-DOWNLOADED images, analysis redone on the FULL 16MB

The user re-downloaded the files (the previous ones were corrupted/truncated). Redid the analysis.

### All images are now FULL: 16777216 (0x1000000)
| file | SHA256 (16) | what it is |
|---|---|---|
| 08C99.bin | 29ee5c2a60a7930c | official HP, no live NVRAM |
| biosstock.bin | 3106c79ce4a7bfe9 | **= biosunlock (IDENTICAL)** |
| biosunlock | 3106c79ce4a7bfe9 | **PATCHED (unlocked) = dump A** |
| biosstock.bin.bak | 87ac59705a97e755 | **the ORIGINAL STOCK (locks=1)** |

!! WARNING ABOUT NAMES: the names are misleading. The file `biosstock.bin` contains PATCHED content
(identical to `biosunlock`), while the real stock image is in `biosstock.bin.bak`.
Direction: .bak has 0x43/0x10E/0x381 = 1 (locked); biosunlock = 0 (cleared).

### Regions now fully within the file bounds
Descriptor 4K / ME 5156K / res9 1496K / BIOS 0x680000-0xFFFFFF 9728K — all OK.
The tail ends with the reset vector (90 90 e9 fb b8 ... 30 fe ff) => the image is complete.
The previously missing part (0xE20000-0x1000000) has NEITHER $VSS NOR NVDATA_FV
NOR CpuSetup — so the truncation wasn't hiding any additional stores. The previous
session's conclusions remain fully valid.

### Reconfirmed (offsets DID NOT change)
5 copies of CpuSetup, the same DATA offsets. The diff biosunlock vs .bak is exactly 6 bytes
at the same offsets (0x68d503/0x68d5ce/0x68d841/0x68ed33/0x68edfe/0x68f071).

Fingerprint verification against the live system (1D9=0 7D=1 228=1 1CD=1 43=0 10E=0 45=0 30=0 381=0):
| copy | biosunlock | diff | .bak | diff |
|---|---|---|---|---|
| DEFAULTS-1 | 0/1/1/1/1 | 108 | 0/1/1/1/1 | 108 |
| DEFAULTS-2 | 0/1/1/0/0 | 151 | 0/1/1/0/1 | 154 |
| **DEFAULTS-3** | **0/1/1/1/0 MATCH** | **79** | 0/1/1/1/1 | 82 |
| NVRAM-1/-2 | 0/1/1/1/1 | 78 | 0/1/1/1/1 | 78 |
=> DEFAULTS-3 in biosunlock is exactly the store backing the live CpuSetup. Confirmed.

### Absolute offsets of 0x1D9 (all currently = 0)
  DEFAULTS-1  0x00689198
  DEFAULTS-2  0x0068d699
  **DEFAULTS-3  0x0068eec9  <-- primary target**
  NVRAM-1     0x0075e3cf
  NVRAM-2     0x00781618

### Checksums
13 FVs with _FVH, all sum16=0x0000 OK. The one BAD entry @0x0db05d0 is a random collision
of the signature inside compressed data, not a real FV. No CRC on the variable body.
No recalculation needed after patching 0x1D9 (same as last time with the 6 bytes).

### FLASHABILITY STATUS
The images are now COMPLETE and structurally valid — the previous session's blocker is cleared.
Base for the patch: **biosunlock** (contains the previous 3 patches + live NVRAM).
One caveat remains unresolved: biosunlock is a dump taken EARLIER, not the chip's
current state. The live NVRAM in it has pre-patch values (0x43=1),
meaning flashing it will roll the NVRAM back to an older state. For minimal risk it's
best to take a fresh dump with the programmer and redo the offset verification on it.

Nothing patched, nothing flashed. Read-only.

## 2026-07-24 — Session 9: generated biosunlock-oc.bin (0x1D9 -> 1)

### Patch performed (image created, NOT flashed)
Source: biosunlock  sha256 3106c79ce4a7bfe93dbb281359392ec2ae5b50931a73ac5b1b307ada20743152
Target:  biosunlock-oc.bin sha256 20270119c729468fee144acbde2a7fe1b7f79762e201c78125b0606bae4b3ceb
Changed EXACTLY 2 bytes, 0x00 -> 0x01:
  0x0068d699  DEFAULTS-2 @0x68b501  var.offset 0x1D9
  0x0068eec9  DEFAULTS-3 @0x68dad9  var.offset 0x1D9
Left DEFAULTS-1 alone (per instruction). VSS structure intact after the patch (21/11/5/519/125).

State in the patched image:
| copy | 1D9 | 43 | 10E | 381 |
|---|---|---|---|---|
| DEFAULTS-1 | 0 | 1 | 1 | 1 |
| DEFAULTS-2 | **1** | 0 | 0 | 0 |
| DEFAULTS-3 | **1** | 0 | 0 | 0 |
| NVRAM-1/-2 | 0 | **1** | **1** | **1** |

### IMPORTANT: NVRAM contains a LOCKED CpuSetup
NVRAM working/backup have 0x43=1, 0x10E=1, 0x381=1 (locks ENABLED) and 0x1D9=0.
So if the BIOS takes CpuSetup from NVRAM without a reseed, not only would 0x1D9 fail to
apply, but the earlier lock unlock would be ROLLED BACK too.

The reseed mechanism was found in NVRAM — there are service flags:
  FirstBootAfterFlash (1 B), RestoreFactoryDefault (1 B), InitSetupVariable (1 B),
  PlatformConfigurationChange (4 B)
=> the BIOS detects that it was flashed and reinitializes Setup variables from DEFAULTS.
Empirical proof: last time, patching ONLY DEFAULTS-2/-3 gave a live 0x43=0.

RECOMMENDATION: patch NVRAM too, but sync ALL 4 bytes
(0x1D9=1, 0x43=0, 0x10E=0, 0x381=0) in both copies (0x75e1f6 / 0x78143f),
so either path (reseed or not) lands in the right state.
Patching ONLY 0x1D9 in NVRAM would be the worst case: without a reseed it would give
0x1D9=1 with the locks still enabled.

### NVRAM ROLLBACK ON FLASHING — actual scope (checked against the live system)
NVRAM working: 519 entries, 124 active. Comparison dump vs efivarfs:
| variable | state |
|---|---|
| BootOrder, Boot0000, Boot3000 | IDENTICAL |
| SecureBoot, SetupMode, certdb | IDENTICAL |
| Timeout, PlatformLang, OsIndications, MsdmAddress | IDENTICAL |
| **Boot0001** | DIFFERS: in the dump 'Windows Boot Manager' -> \EFI\Microsoft\Boot\bootmgfw.efi (dead, Windows removed 2026-07-12); live: 'EFI Hard Drive (SAMSUNG MZVL21T0HCLR)' |
| **HWSIG** | DIFFERS (values differ) — hw signature, the BIOS recomputes it itself |
| MemoryConfig (63456 B) | not RT-visible, can't compare — DRAM training, self-healing |
The rest (SAR/regulatory: EWRD/WGDS/WRDS/SPLC/WRDD/SADS/GPC/BRDS/WAND,
HSTI_RESULTS, UnlockID, OfflineUniqueIDEKPub, VsmLocalKey2, Tcg2*) — present
in the dump; no critical discrepancies found, since these are stable factory data.
There's NO MAC address in NVRAM: the GbE region in the descriptor is UNUSED, the Realtek
r8169 has its own EEPROM => flashing the SPI doesn't touch the MAC.

RISK CONCLUSION: the rollback is much smaller than expected — effectively only
the dead Windows entry Boot0001 (removed with efibootmgr) + HWSIG (self-healing)
+ possibly one slow boot from memory retraining.

Not flashed. Only the file biosunlock-oc.bin was created.

## 2026-07-24 — Session 10: FINAL image, full lock synchronization

### Lock audit BEFORE the patch (biosunlock)
| offset | option | needed | LIVE | DEF-1 | DEF-2 | DEF-3 | NVR-w | NVR-b |
|---|---|---|---|---|---|---|---|---|
| 0x1D9 | OverClocking Feature | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| 0x43  | CFG Lock | 0 | 0 | 1 | 0 | 0 | 1 | 1 |
| 0x10E | Overclocking Lock | 0 | 0 | 1 | 0 | 0 | 1 | 1 |
| 0x381 | third lock | 0 | 0 | 1 | 0 | 0 | 1 | 1 |
| 0x45  | Configurable TDP Lock | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 0x30  | Pkg Power Limit MSR Lock | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 0x7D  | PROCHOT Lock | 0 | **1** | 1 | 1 | 1 | 1 | 1 |
| 0x228 | HwP Lock | 0 | **1** | 1 | 1 | 1 | 1 | 1 |
| 0x1CD | Tcc Offset Lock | 0 | **1** | 1 | 0 | 1 | 1 | 1 |
| 0x1B4/5/6 | TDC Lock x3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

DESYNC of DEFAULTS-3 vs NVRAM: NVRAM still had 0x43, 0x10E, 0x381 ENABLED
(they were cleared in DEFAULTS last time). Plus 0x7D/0x228 are locked EVERYWHERE, including
the live system — meaning they were never cleared anywhere before. 0x1CD is cleared only in DEFAULTS-2.

### IFR: found ADDITIONAL locks, offsets NOT obtained
Unpacked 22 LZMA sections (26 MB) plus 13 more recursively. Found the CpuSetup varstore
(EFI_IFR_VARSTORE_EFI id=0x3 size=961 @blob0:0x100cdf0 and 0x1040672 — size matches).
BUT walking the IFR and resolving the string package failed (the form package isn't contiguous,
the string package header can't be located). Via string search, ADDITIONAL CpuSetup options
were FOUND that AREN'T in the user's map:
  - CPU Run Control Lock  ("Enable/Disable CPU Run Control Lock")
  - Power Limit 3 Lock
  - Power Limit 4 Lock
  - Thermal Throttling Lock
  - Pmic NVM Write Lock Support
Their offsets were NOT determined => NOT patched. No guessing allowed.
Other locks found belong to modules other than CpuSetup (BIOS Lock, RTC Memory Lock, LTR Lock,
USB Overcurrent Lock, Lock PCH Sideband Access -> PchSetup; DriveLock -> Security).

### FINAL IMAGE
biosunlock-oc.bin  sha256 755d1dab5bed4b4c8a3952a5483f5209b267488985f50d6fc4297853393e976f
source biosunlock  sha256 3106c79ce4a7bfe93dbb281359392ec2ae5b50931a73ac5b1b307ada20743152
Changed 21 bytes across 4 copies (DEFAULTS-1 deliberately left alone):
  DEFAULTS-2 (3): 0x68d699=1(1D9), 0x68d53d=0(7D), 0x68d6e8=0(228)
  DEFAULTS-3 (4): 0x68eec9=1(1D9), 0x68ed6d=0(7D), 0x68ef18=0(228), 0x68eebd=0(1CD)
  NVRAM-work (7): 0x75e3cf=1(1D9), 0x75e239=0(43), 0x75e304=0(10E), 0x75e577=0(381),
                  0x75e273=0(7D), 0x75e41e=0(228), 0x75e3c3=0(1CD)
  NVRAM-bkp  (7): 0x781618=1(1D9), 0x781482=0(43), 0x78154d=0(10E), 0x7817c0=0(381),
                  0x7814bc=0(7D), 0x781667=0(228), 0x78160c=0(1CD)
DEFAULTS-2/-3/NVRAM-work/NVRAM-bkp are now IDENTICAL across all 12 checked bytes
=> the result is the same whether or not a reseed happens. VSS structure intact (21/11/5/519/125).

### WARNINGS
0x7D (PROCHOT Lock), 0x228 (HwP Lock), 0x1CD (Tcc Offset Lock) had NEVER before
been cleared on this machine — they're =1 in stock, in the previous working patch, and in the live
system. This goes beyond the previously validated 3-lock patch. Clearing these locks makes
the corresponding MSRs WRITABLE, but doesn't disable thermal protection itself.
DEFAULTS-1 remains fully locked (per instruction, left untouched) — if the BIOS ever
reseeds specifically from it, the locks will come back.

NOT FLASHED.

## 2026-07-24 — Session 11: TWO final versions, DEFAULTS-1 aligned

Both generated from a clean biosunlock (3106c79c...). DEFAULTS-1 is now also
aligned in BOTH — there's no more desync between copies.

### biosunlock-oc.bin — MAIN (validated territory), 14 bytes
sha256 b18596bcf847477cd2b2fa68a3f9f7d1cd4a3c60ab6298e54cfed5c2fa52c016
0x1D9=1, 0x43=0, 0x10E=0, 0x381=0 in all 5 copies. 0x7D/0x228/0x1CD NOT touched.
  DEFAULTS-1 (4): 0x689198=1, 0x689002=0, 0x6890cd=0, 0x689340=0
  DEFAULTS-2 (1): 0x68d699=1
  DEFAULTS-3 (1): 0x68eec9=1
  NVRAM-work (4): 0x75e3cf=1, 0x75e239=0, 0x75e304=0, 0x75e577=0
  NVRAM-bkp  (4): 0x781618=1, 0x781482=0, 0x78154d=0, 0x7817c0=0
Remaining asymmetry (intentional, per instruction not to touch 0x1CD): DEFAULTS-2 has
0x1CD=0, the rest =1. Doesn't affect the result — 0x1CD is out of scope for this version.

### biosunlock-oc-max.bin — EXTENDED (unexplored), 28 bytes
sha256 e0ae0646c382c623e1c293af6de5026932a54a20dc09abbfa9a8d52aa54cfb47
Same as above plus 0x7D=0, 0x228=0, 0x1CD=0 in all 5 copies.
Here all 5 copies are IDENTICAL across all 7 bytes — full sync, no desync at all.

### Verification of both
- size 16777216 for both
- VSS structure intact: 21/11/5/519/125 variables in both
- 13 FVs, all checksums OK (except the known false match @0x0db05d0)
- neither needs a CRC recalculation

### Note created: ~/FLASH-ORDER.txt
Contains hashes, which to flash first, verification commands after flashing, and a warning
that biosstock.bin is NOT stock (stock is in biosstock.bin.bak).

NOT FLASHED. Both files only created.

## 2026-07-24 — Session 12: FINAL PRE-FLASH VERIFICATION — both PASS

Script: victus-unlock/verify-final.py (changes nothing, exits 1 on any FAIL).
Result: exit 0, all checks passed.

### biosunlock-oc.bin (14 bytes) b18596bcf847477cd2b2fa68a3f9f7d1cd4a3c60ab6298e54cfed5c2fa52c016
1) Target bytes — in ALL 5 copies: 0x1D9=1, 0x43=0, 0x10E=0, 0x381=0,
   0x45=0, 0x30=0 (the last two untouched, as expected). PASS
2) 0x7D=1, 0x228=1, 0x1CD=1 in all copies, EXCEPT DEFAULTS-2 where 0x1CD=0.
   This is NOT a side effect of the patch — that's how it was in the original biosunlock; the
   verifier checks this position against the original, not against a constant. PASS
3) Structure: size 16777216, descriptor unchanged, FLVALSIG OK,
   the ME region byte-for-byte identical to the original, the tail is the reset vector
   (90 90 e9 fb b8 ... 30 fe ff), 13 FVs all sum16=0, all 5 $VSS in place. PASS
4) Diff = exactly 14 bytes, NONE outside the target offsets. PASS
   0x689002 0x6890cd 0x689198 0x689340 0x68d699 0x68eec9 0x75e239 0x75e304
   0x75e3cf 0x75e577 0x781482 0x78154d 0x781618 0x7817c0

### biosunlock-oc-max.bin (28 bytes) e0ae0646c382c623e1c293af6de5026932a54a20dc09abbfa9a8d52aa54cfb47
1) The same 6 bytes are correct in all 5 copies. PASS
2) 0x7D=0, 0x228=0, 0x1CD=0 in ALL 5 copies (full symmetry). PASS
3) Structure — all the same checks. PASS
4) Diff = exactly 28 bytes (14 base + 14 extra: 0x7D×5 + 0x228×5 + 0x1CD×4,
   since in DEFAULTS-2 0x1CD was already 0). No stray bytes. PASS

The ME region is byte-for-byte identical to the original in BOTH images — the patch didn't touch it.
The descriptor is unchanged in both. Ready to flash.

NOT FLASHED.

## 2026-07-24 — Session 13: diagnosing "CPU won't boost" — an ORPHANED MMIO CLAMP

### Symptom
freq ~2000 MHz, 63-64°C under full load, draw exactly 44.0 W.

### Cause found (measured, not guessed)
| source | value |
|---|---|
| MSR 0x610 | **130 W** (PL1=PL2, enable=1) |
| MMIO RAPL 0x59A0 | **44 W** <-- OVERRIDES the MSR |
| actual draw | **44.0 W** = matches the MMIO |

Heat ruled out: 63-64°C, DigitalReadout 38° below TjMax, THERM_STATUS
PROCHOT=0 thermal=0, PERF_LIMIT_REASONS 0x690 = 0x0 (no reason at the core level).

CHAIN: throttled was STOPPED (rc-status: stopped), but its last write of
44 W to MMIO 0x59A0 was left ORPHANED — nobody updates or clears it.
In parallel, platform_profile became `performance` (was `balanced`), so the firmware
raised the MSR to 130 W. MMIO has priority -> a 44 W clamp despite the MSR allowing more.
scaling_max_freq is NOT lowered (5.2/5.0/3.7 GHz by core type — normal),
no_turbo=0, max_perf_pct=100, driver=intel_pstate. Governor powersave (unchanged).

### Fix
Synced MMIO 0x59A0 with MSR 0x610 (44W -> 130W). Nothing else touched.
Result under load:
| | before | after |
|---|---|---|
| draw | 44.0 W | **91.9 W** |
| freq | ~2000 MHz | **3519-3883 MHz** |
| temp | 63-64°C | 91-94°C (14° below TjMax, PROCHOT=0) |

### IMPORTANT CLARIFICATION
44 W is NOT a regression from our experiments in terms of power — exactly 44 W
was measured in Phase 1 at the very start of the session, BEFORE any changes (throttled
was running then and held 44 W as designed). So "the state before experiments" was also 44 W.
The current 92 W is BETTER than the pre-session state, not a return to it.
What actually changed: throttled stopped + platform_profile=performance.
The user's memory of 120 W is now consistent with reality.

### VOLATILITY / next steps
- The MMIO write is volatile: a reboot resets it.
- throttled is currently stopped. If it starts (reboot/manually), it will
  reimpose 44 W, because /etc/throttled.conf [AC] has PL1_Tdp_W=44 PL2_Tdp_W=44.
- PERMANENT fix: set the desired PL1/PL2 in throttled.conf [AC] and keep the
  service running — it consistently writes both MSR and MMIO (that's exactly why
  everything was consistent earlier). Otherwise the orphaned clamp will recur.
- Temperature 91-94°C at 92 W is steady — within range (TjMax not reached), but high.
  For quiet/longevity, a sensible compromise is ~65-75 W.

BIOS flashing was NOT done — the state is purely software, as the user suspected.

## 2026-07-24 — Session 14: PL1=80 / PL2=115 permanently + found the EC "rearming" behavior

### Configured
/etc/throttled.conf [AC]: PL1_Tdp_W: 80, PL2_Tdp_W: 115, cTDP: 0 (unchanged).
Backup of the previous config: victus-unlock/backup/throttled.conf.before-80w
throttled is in runlevel `default` => starts automatically after reboot.

Final measurement (24×yes, after a 20s window for the PL1 ramp):
  MSR 0x610 = PL1 80W / PL2 115W, MMIO 0x59A0 the same — consistent
  DRAW = 80.0 W (right on target), freq 2781-3094 MHz, temp 81-82°C
  PROCHOT=0, 23° below TjMax

### MAIN DISCOVERY: the EC needs to be "rearmed" by writing to platform_profile
Interim measurements were confusing (45-54 W with 80/115 set in BOTH registers).
Checked and ruled out as the cause:
  - the PL1 clamp bit (test clamp=1 vs 0: 54.3 W vs 44.9 W — not it)
  - the cTDP level (test 0 vs 2: 44.9 W vs 52.5 W — not it)
  - HWP/EPP (0x774 min=11 max=64 EPP=0 — not limiting)
  - something overwriting the registers (checked over 15s — no, they hold)
THE REAL CAUSE: until a WRITE is made to /sys/firmware/acpi/platform_profile,
the EC holds its own lower limit regardless of the RAPL registers. Writing to
profile (even the same value, `performance`) makes the firmware reapply
the limits — the MSR immediately jumps to 130 W, and after that our RAPL values
start taking effect.
Proof (clean A/B under identical thermal conditions, throttled stopped):
  A firmware's 130W -> 81.5 W, 2895 MHz, 81°C
  B our 80/115     -> 80.0 W, 2833 MHz, 79°C
Both work; before writing to profile, the same 80/115 gave only 45-52 W.

### PRACTICAL CONSEQUENCE
After a reboot (or if power "droops" again), it's enough to run:
  echo performance > /sys/firmware/acpi/platform_profile
throttled then holds 80/115 on its own. If power-profiles-daemon switches the profile,
it may need repeating. A candidate for automation if it recurs.

BIOS state untouched. The biosunlock-oc*.bin images sit ready, not flashed.

## 2026-07-24 — Session 15: does it survive a reboot — NO, found and fixed

### Question: does PL1=80/PL2=115 survive a reboot
Checked by SIMULATING the exact boot order, not by reasoning about it.

What survives a reboot on its own:
  - /etc/throttled.conf (PL1=80, PL2=115) — a file on disk, YES
  - throttled in runlevel `default` — starts on its own, YES
  - PPD /var/lib/power-profiles-daemon/state.ini: Profile=performance — YES
    (PPD isn't in a runlevel, it's D-Bus-activated via net.hadess.PowerProfiles)

### PROBLEM: it didn't survive
Boot-order simulation (throttled -> local.d, since `local` has `after *`):
  1) throttled starts -> MSR PL1=80W PL2=115W
  2) /etc/local.d/performance.start runs `powerprofilesctl set performance`
     -> the MSR STAYS at 80W, meaning there was NO write to platform_profile
  3) measurement under load: **52.7 W**, 2274 MHz — the limit is NOT in effect

CAUSE: `powerprofilesctl set performance` when `performance` is already set
is a NO-OP — PPD doesn't write to sysfs if the value isn't changing. Without an actual
WRITE to /sys/firmware/acpi/platform_profile, the EC isn't rearmed and holds
its own lowered limit, ignoring the RAPL registers.
Control test: a direct `echo performance > /sys/firmware/acpi/platform_profile`
immediately gives MSR=130W (the EC rearmed), throttled brings it back to 80/115 within <=5s,
measurement -> 79.9 W, 3176 MHz. A difference of 52.7 -> 79.9 W from one sysfs write.

### FIX
/etc/local.d/performance.start (backup: victus-unlock/backup/performance.start.orig)
was:
    powerprofilesctl set performance
became:
    powerprofilesctl set performance 2>/dev/null   # keep PPD's own state consistent
    echo performance > /sys/firmware/acpi/platform_profile   # the actual write

Redid the boot simulation with the fixed script:
  1) throttled  -> PL1=80W
  2) local.d    -> PL1=130W (EC rearmed)
  3) reapply    -> PL1=80W PL2=115W
  measurement: **79.9 W, 3084 MHz, 85°C** — the target holds.

### CAVEAT
This is a simulation, not an actual reboot — it reproduces the ordering (`local` has `after *`,
so it runs after throttled) and shows the correct final state, but a 100% proof requires
an actual reboot. After rebooting, worth checking:
  rdmsr -0 0x610   (should be PL1=80 PL2=115)
  and a measurement under load — should be ~80 W, not ~52 W.

## 2026-07-25 — Session 16: resume hook + measuring rearm speed

### Speed (measured, not assumed)
  the whole /etc/local.d/performance.start script: ~0.11 s
  powerprofilesctl (warm PPD):   ~0.09 s
  powerprofilesctl (cold, D-Bus activating PPD from scratch): 0.13 s, PPD came up normally
  echo > platform_profile:         0.023 s
Conclusion: adds ~0.1s to boot, unnoticeable. Safe to hang on resume too.

### New resume hook
/lib/elogind/system-sleep/90-power-limits-rearm (root:root, +x)
Called by elogind on waking from sleep, with $1=post. Does the same
`echo performance > /sys/firmware/acpi/platform_profile` as boot does,
for the same reason: the EC doesn't rearm itself, and without this write PL1/PL2
from throttled don't take effect (earlier measurement: 52.7W without rearming vs 79.9W with it).

Path confirmed from `man 5 sleep.conf` (elogind documentation, the section about
HandleNvidiaSleep, which explicitly points to /lib/elogind/system-sleep/* as
the canonical hook directory). The folder didn't exist — created it.

NOT VERIFIED with an actual suspend/resume cycle (the user asked not to
run load tests right now, wants to play). Check for later:
  systemctl suspend  (or the elogind equivalent)
  # after waking:
  rdmsr -0 0x610   # should be PL1=80 PL2=115, not lowered

## 2026-07-25 — Session 17: EPP performance (clock boost) + post-reboot verification

### The "why isn't it boosting" question — not a real problem, a measurement artifact
Earlier I was showing the AVERAGE frequency across all 24 threads. RustClient.exe has
affinity 0,2,4,6,8,10 (per taskset -pc); exactly these cores were boosting normally:
  cpu0=3449 cpu2=3043 cpu6=3034 cpu10=3088 MHz
The other 18 threads were idling at 800 MHz (idle floor) and dragging the "average" down to
~1850 MHz — hence the false impression that boost wasn't working.

### The real finding: EPP was balance_performance, not performance
no_turbo=0 (turbo enabled), governor=powersave (intel_pstate, this is normal for
this driver — don't confuse it with the old-style cpufreq governor).
energy_performance_preference = balance_performance on all cores.
Available options: default performance balance_performance balance_power power.

### Fixed
Set performance on all cores immediately (echo > .../energy_performance_preference).
Locked in for autostart in BOTH places:
  /etc/local.d/performance.start — added a loop over all cpu*/energy_performance_preference
  /lib/elogind/system-sleep/90-power-limits-rearm — the same in the post (resume) block
Both passed sh -n.

### Confirmed on an actual reboot (not a simulation)
uptime showed `up 9 min` at the time of this check -> the system had already
rebooted with the new throttled.conf, and PL1=80W PL2=115W were already in MSR+MMIO
automatically, with no manual intervention. The boot script really does
work in practice, not just in last session's simulation.

## 2026-07-25 — Session 18: disabled the C3 idle state (deep core sleep)

At the user's request — to disable "deep idle modes" to reduce
input micro-latency in games.

States on cpu0 (driver=intel_idle, governor=menu):
  state0 POLL      latency=0us
  state1 C1_ACPI   latency=1us
  state2 C2_ACPI   latency=127us
  state3 C3_ACPI   latency=1048us  <- the deepest, disabled by the user's choice

Disabled /sys/devices/system/cpu/cpu*/cpuidle/state3/disable=1 on all 24
threads immediately. C1/C2 left alone — minimal impact on idle draw/temp.

Locked in for autostart in both places:
  /etc/local.d/performance.start — added a loop over state3/disable
  /lib/elogind/system-sleep/90-power-limits-rearm — the same in post (resume)
Both passed sh -n.

Cost: slightly higher idle draw/temperature at idle (not measured separately; the
cores are active during gaming so it's barely noticeable). Compensated for in the resume
hook in case of sleep/wake.

## 2026-07-25 — Session 19: installed games-util/gamemode (Feral GameMode)

At the user's request, on top of the already-set PERMANENT parameters
(PL1/PL2, EPP=performance, C3 off) — GameMode adds TEMPORARY optimizations
while a game is running (renice/ionice, governor, GPU mode as needed).

### Installation
The package is masked (~amd64 keyword) — unmasked:
  /etc/portage/package.accept_keywords/gamemode: games-util/gamemode ~amd64
USE required exactly-one-of(systemd,elogind); the system is on elogind:
  /etc/portage/package.use/gamemode:
    games-util/gamemode elogind -systemd
    >=sys-apps/dbus-1.16.2 elogind
dbus was rebuilt with elogind support (extra, nothing lost).
emerge games-util/gamemode-1.8.2 — succeeded, 3 packages (acct-group/gamemode,
dbus reinstall, gamemode).

### Post-install
gpasswd -a tarilka0gg gamemode — user added to the gamemode group
(needed to permit PAM limits/scheduling/L3/mitigations).
gamemoded -t: basic client tests PASSED. The "reaper thread" test failed —
EXPECTED, since it was tested in the same session right after gpasswd; group
membership takes effect only after a fresh login/reboot.
The com.feralinteractive.GameMode.service daemon is D-Bus-activated on demand
(per-user), doesn't need an OpenRC runlevel entry.

### How to use it
In Steam: Rust -> Properties -> Launch Options -> add `gamemoderun %command%`
Or directly: `gamemoderun ./game`
After the NEXT login (so gamemode group membership takes effect), can be
verified independently: `gamemoded -t`

Our manual configuration (throttled 80/115, EPP, C3 off) stays in place permanently
and independently of GameMode — they don't conflict, they complement each other.

## 2026-07-25 — Session 20: RESULT CONFIRMED — 130 FPS, a record

User: "insane FPS, even hit 130 for the first time" — in Rust with gamemoderun,
after the full stack of this session's settings.

### Live state during play (passive, no synthetic load)
  MSR/MMIO PL1=80W PL2=115W — consistent
  CPU draw=41W freq_avg=2492MHz temp=80°C
  EPP=performance on all cores, C3 disabled on all cores, profile=performance
  GPU 94% util, 77W, 2535MHz  <- now the GPU is the bottleneck, as it should be
  gamemoded -d active (PID 5161), connected without issue this time

### Side incident (sessions 19-20): dbus-launch fork chain
Once, a chained self-fork of dbus-launch occurred (71403 processes, 25GB RAM) on the
first launch of the game with gamemoderun in the launch options — likely a one-off
failure initializing the D-Bus session in Steam Runtime's pressure-vessel/bwrap sandbox,
not a system-wide problem. The second launch went cleanly, with no
repeat. The watchdog victus-unlock/dbus-launch-watchdog.sh keeps
running in the background (threshold 100, kill+log) in case it recurs.

### SUMMARY OF THE WHOLE TDP/PERF SETTINGS STACK (sessions 13-20)
Permanent changes (survive a reboot):
  /etc/throttled.conf [AC]: PL1_Tdp_W=80 PL2_Tdp_W=115 Update_Rate_s=1
  /etc/local.d/performance.start: platform_profile=performance (re-arm EC) +
    EPP=performance on all cores + C3 disable on all cores
  /lib/elogind/system-sleep/90-power-limits-rearm: the same on resume from sleep
  games-util/gamemode-1.8.2 installed and configured (elogind USE)
Volatile/manual: none — everything is automated via boot/resume hooks.
BIOS NOT flashed — the whole stack is software, as found back in Session 4.

## 2026-07-26 — Session 21: FLASHING DONE — THE UNLOCK WORKS, THE MAILBOX CAME ALIVE

The user flashed biosunlock-oc-max.bin (the extended version, 28 bytes, all 5 copies
of CpuSetup). The system booted normally. uptime ~9 min at the time of the check.

### STEP 1: the CpuSetup variable from efivarfs — EVERYTHING APPLIED
attrs=0x7, body 961 bytes. All 12 checked bytes = the target values:
| offset | option | needed | now |
|---|---|---|---|
| 0x1D9 | OverClocking Feature | 1 | **1** OK |
| 0x43 | CFG Lock | 0 | 0 OK |
| 0x10E | Overclocking Lock | 0 | 0 OK |
| 0x381 | third lock | 0 | 0 OK |
| 0x7D | PROCHOT Lock | 0 | 0 OK |
| 0x228 | HwP Lock | 0 | 0 OK |
| 0x1CD | Tcc Offset Lock | 0 | 0 OK |
| 0x45/0x30/0x1B4-6 | remaining locks | 0 | 0 OK |
The reseed from DEFAULTS worked exactly as predicted.

### STEP 2: THE OC MAILBOX CAME ALIVE — THE MAIN RESULT
`intel-undervolt read` alone is ambiguous (zero could mean either "not working"
or "offset genuinely 0"). The decisive test is whether a write HOLDS.
Stopped throttled (it writes offset=0 every second at Update_Rate_s=1).
`intel-undervolt apply` (config -50/-30/-50/-30):
  YESTERDAY: "Values do not equal" on every plane, read-back = 0
  TODAY: CPU -49.80mV, GPU -30.27mV, Cache -49.80mV, SA -30.27mV
         read-back — the SAME values, meaning the WRITE HELD
Manual mailbox verification per plane (wrmsr 0x150 read-cmd + rdmsr):
  CPU Core     0x00000000f9a00000  -49.8 mV
  iGPU         0x00000000fc200000  -30.3 mV
  CPU Cache    0x00000000f9a00000  -49.8 mV
  System Agent 0x00000000fc200000  -30.3 mV
  Analog I/O   0x0000000000000000   +0.0 mV
Yesterday EVERY plane read as 0x0. Now they return real encoded offsets.
=> MSR 0x150 is active. THE UNDERVOLT IS NOW POSSIBLE. The hypothesis (session 5) that
   OverClocking Feature=1 is a necessary condition — finally confirmed.

### STEP 3: locks on the live CPU
  0xE2  bit15 CFG Lock = 0 — CLEARED
  0x194 bit20 OC Lock  = 0 — CLEARED
  0x150 reads without error

### STEP 4: power limits
  MSR 0x610 = MMIO 0x59A0 = PL1=29W PL2=44W
  THIS IS NOT A REGRESSION: the laptop is on BATTERY (ACAD online=0), throttled applied
  the [BATTERY] section (PL1=29 PL2=44). The [AC] config 80/115 is untouched.
  throttled started, profile=performance, Update_Rate_s=1.

### OPEN CONFLICT FOR THE NEXT STEP
throttled and intel-undervolt both control MSR 0x150. throttled has
UNDERVOLT.AC/BATTERY = 0 and overwrites any offset from intel-undervolt
every second (confirmed: after `rc-service throttled start`, offset->0).
Decision: put the undervolt values in throttled.conf [UNDERVOLT.AC]/
[UNDERVOLT.BATTERY], not through intel-undervolt — one tool, no race.
Current state: offset reset to 0 (safe baseline), the undervolt is NOT
applied permanently — waiting on a campaign to find stable values with stability tests.

## 2026-07-29 — Session 22: undervolt campaign + diagnosing the 45W ceiling

### PL-bound discovery (methodology fix)
Mixed load (--cpu all + --vm) only pulled ~60% of PL1 and ran at
2462 MHz -> the undervolt couldn't show a frequency gain, because frequency wasn't
bound by power. Switched to pure matrixprod (PL-bound).
A/B on PL-bound at the same 80W:
  baseline 0/0    : Vcore 950mV, 2733 MHz
  -100/-100       : Vcore 908mV, 3553 MHz
  => +820 MHz (+30%) at the same budget. THIS is the real undervolt gain.
Old CSV rows (2258-2465 MHz) flagged MIXED-INVALID — underloaded.

### EC turbo budget: 80W lasts only ~2min, then drops
Found: the EC gives full 80W for roughly 2-2.5 min, then sharply drops to 45W/2586MHz.
Rearming (echo performance > platform_profile) MID-LOAD
immediately brings back 80W/3552MHz. The campaign now rearms every 90s —
confirmed to hold 3483 MHz at t+200s.

### DIAGNOSING the cause — it's the EC, not the BIOS or RAPL
At the moment of the droop (diag-45w.log, diag-hwp.log):
  MSR 0x610      = 80W/115W   <- RAPL allows it, NOT the cause
  MMIO 0x59A0    = 80W/115W   <- same
  PSYS 0x65C     en=0         <- disabled, not the cause
  PROCHOT 0x19C  b2=0 b3=0    <- didn't twitch even in the log
  thermal        35C headroom <- not heat
  CONFIG_TDP_CONTROL = 0      <- didn't switch
THE ONLY thing that changes:
  PERF_STATUS ratio 38 -> 28, Vcore 920 -> 784mV
  HWP_CAPABILITIES.guaranteed = 28  <- drops EXACTLY to guaranteed
  HWP_REQUEST (min/max/epp) does NOT change
=> This is a platform turbo budget: the EC withdraws the turbo permission, the CPU
   drops to P1. The mechanism is NOT RAPL-based, so unlocked PL locks don't touch it.
   45W is a CONSEQUENCE of the frequency drop, not the cause (the coincidence with
   CONFIG_TDP_LEVEL1 is misleading).

### Attempts to work around it
- MSR 0x649 (CONFIG_TDP_LEVEL1=45W): READ-ONLY, the hardware rejects the write
  ("wrmsr: cannot set MSR 0x649") — cannot be raised directly.
- HWP min (scaling_min_freq 800MHz -> 3000MHz, HWP_REQUEST.min 11 -> 39):
  the droop happened ANYWAY, ratio fell to 28. The platform overrides the OS's request.
  Reverted back to 800000.
- The only working lever: periodic rearming via platform_profile.

### Campaign status (CSV uv-campaign.csv)
| offset | Vcore | freq | temp | draw | load | result |
|---|---|---|---|---|---|---|
| 0/0 baseline | 850 | 2258 | 64 | 56.8 | MIXED-INVALID | PASS |
| -60/-50 | 815 | 2412 | 60 | 48.5 | MIXED-INVALID | PASS |
| -80/-70 | 809 | 2465 | 60 | 48.6 | MIXED-INVALID | PASS |
| -100/-100 | 795 | 2462 | 61 | 48.7 | MIXED-INVALID | PASS |
| **-100/-100 rearm** | **922** | **3567** | **78** | **79.9** | **PLBOUND** | **PASS** |
0 MCE, 0 WHEA at every step. After a reboot, -100/-100 came back up automatically
from throttled.conf, 0 errors.

Adjusted strategy: move CORE and CACHE EVENLY (not CACHE 10 lower), because
CACHE was dictating the plateau — after equalizing, the per-step Vcore drop doubled
(6mV -> 14mV).

## 2026-07-29 — Session 23: UNDERVOLT CAMPAIGN + a critical methodology mistake

### Results (PL-bound, all-core)
| CORE | CACHE | Vcore | P-freq | WHEA | verdict |
|---|---|---|---|---|---|
| 0/0 baseline | | 950 | 3435 | 0 | — |
| -100/-100 | | 922 | — | 0 | PASS |
| -120/-120 | | 913 | 3894 | 0 | PASS |
| -140/-140 | | 905 | 3890 | 0 | PASS |
| -160/-140 | | 893 | 3894 | 0 | PASS |
| -165..-180 | | ~890 | — | 0 | FAIL_COMPUTE |

### "Who's holding it" METHOD (asymmetry)
Repeated three times in a row: CORE dictates the VccIA rail, CACHE doesn't move it at
all (deltas of +2/+5 mV = noise). So CACHE was fixed at -140, only CORE was moved.

### THE MAIN METHODOLOGY MISTAKE (found after the user questioned it)
The user was skeptical of the FAIL at -165/-175. Checking showed he was
right — but for a different reason than either of us thought.

Chain of checks:
  -175 static (throttled stopped)        -> PASS 300s, 6 tests
  -175 with throttled (rewrites 1/s)     -> PASS 120s, 3 tests
  -175 via validate.sh                   -> FAIL after 2min, core 4
  -175 manual + EC rearming              -> FAIL, core 5
=> The trigger is EC REARMING before the test, not the mailbox rewrites.

WHY: measuring the ratio under LIGHT load after rearming:
  ratio=47, max P-core 4920 MHz, Vcore 1029-1129 mV
vs. all-core PL-bound:
  ratio=39, 3894 MHz, Vcore 893 mV
So the whole campaign validated ONE V/F point (3.9GHz/0.89V), while the
undervolt actually breaks at a DIFFERENT one — light load, high boost 4.9GHz/1.03V.
All-core matrixprod simply never reaches that point.

METHODOLOGY CONCLUSION: the undervolt must be validated at AT LEAST two points:
  1) all-core sustained (low frequency, low voltage)
  2) light-load boost (4.7-4.9 GHz, high voltage) <- this is where it breaks
I never tested the second point at all. WHEA was 0 in both cases —
confirming again that WHEA is useless, only y-cruncher settles it.

### STATUS
-160/-140 remains the last point that passed the harness WITH rearming,
i.e. the only one validated at the boost point too. The system is set back to it.
-175 is stable for sustained all-core, but NOT for light boost -> in
everyday use (where light loads are constant) it would produce silent errors.

## 2026-07-29 — Session 24: UNDERVOLT FINALIZED

### Domain limits (each point: y-cruncher all-core 5min + light-boost 3min)
CORE (with CACHE=-140/-175):
  -140 PASS/PASS | -150 PASS/PASS | -160 PASS/FAIL(x2) | -165 FAIL/FAIL
CACHE (with a stable CORE=-140):
  -150..-175 PASS/PASS | -180 PASS/FAIL
GPU: 0..-150 stable, hang=0

### KEY METHODOLOGY CONCLUSIONS
1. NEED TWO V/F POINTS. All-core matrixprod = 3.9GHz/0.89V. Light-load boost
   (1-4 threads) = 4.6-4.9GHz/1.03-1.13V. The undervolt breaks at the SECOND one, and
   the all-core test never sees it. The whole early campaign (-100..-140) only validated
   the first -> the conclusions were incomplete.
2. WHEA IS USELESS. Every FAIL point showed WHEA=0 and MCE=0. Only y-cruncher
   caught it (Bottom word mismatch / Checksum Mismatch on specific cores).
3. CACHE DOESN'T MOVE Vcore (deltas of +2/+5mV = noise), but has its OWN limit, and it's
   DEEPER than the core's (-175 vs -150). The asymmetry is the opposite of the initial
   assumption that Ring would be weaker.
4. Sweeping CACHE with an unstable CORE is INVALID — every point failed because of the cores.
   Needs a control: the same harness on a known-stable CORE.

### POWER BY DOMAIN (RAPL PP0/PP1/PKG)
  idle:     package 34.2W = cores 22.3 + uncore 10.6 + iGPU 1.3
  all-core: package 80.0W = cores 67.1 + uncore 12.1 + iGPU 0.8
Uncore (Ring/LLC/IMC) ~10-13W and barely depends on load.
CACHE undervolt -175 vs 0: difference 0.1W = NOISE. So there's NO benefit,
the entire value of the undervolt is in the cores.
iGPU ceiling 3.0W at 1600MHz. GPU offset -150 gives 3.38 -> 2.32W (-1.06W).

### FINAL CONFIGURATION (/etc/throttled.conf)
  [UNDERVOLT.AC]      CORE -150, CACHE -175, GPU -150
  [UNDERVOLT.BATTERY] CORE -140, CACHE -175, GPU -150  (CORE more conservative)
Confirmed: -150/-175 PASS in both modes. throttled is in runlevel default,
applies automatically on boot.
Backup: backup/throttled.conf.FINAL-150-175-150
Rollback: victus-unlock/ROLLBACK.txt

## 2026-07-29 — Session 25: System Agent / Analog I/O — DECIDED NOT TO TOUCH

Measurement under a workload targeting memory specifically (stress-ng --vm 8 --vm-bytes 1G):
| UNCORE | package | cores | uncore |
|---|---|---|---|
| 0 | 64.80W | 52.45W | 12.35W |
| -100 | 64.58W | 52.28W | 12.30W |
Difference 0.05W = NOISE. No gain, same as with CACHE.

REASON FOR DECLINING (not just zero gain):
System Agent = memory controller + PCIe + display engine. Its instability
doesn't produce a compute error but CORRUPTED DATA IN MEMORY, which lands on disk and
surfaces weeks later. None of our tests catch this reliably: y-cruncher
checks arithmetic, not memory-path integrity. So the risk is qualitatively
worse than for the cores, for zero reward.
Analog I/O — microscopic power draw, touches the analog block. Also no.
UNCORE set back to 0.

### FINAL CONFIGURATION (both sections identical)
  CORE -150, CACHE -175, GPU -150, UNCORE 0, ANALOGIO 0
BATTERY equalized to -150 (initially set -140 out of caution, but on battery
PL1=29W -> lower frequencies/voltages -> less V/F stress, meaning it's SAFER
there than on AC, where -150 was validated).
Backup: backup/throttled.conf.FINAL-150-175-150 (synced with the live config)

### VALUE SUMMARY BY DOMAIN
  CORE   -150 -> +459 MHz on the P-cores, Vcore 950->~900mV  <- ALL the value is here
  CACHE  -175 -> 0.1W (noise), but stable, may as well leave it
  GPU    -150 -> 1.06W (3.38->2.32W)
  UNCORE/ANALOGIO -> 0.05W of noise, risk disproportionate. DO NOT touch.

## 2026-07-29 — Session 26: CONFIG_TDP levels — switching HURTS, doesn't help

MSR levels: 0x649 LEVEL1(down)=45W ratio18, 0x64A LEVEL2(up)=65W ratio24,
both READ-ONLY (checked earlier, wrmsr rejected by the hardware).
The only writable one is 0x64B CONTROL, the switch BETWEEN the fixed levels.

The first rough test gave contradictory numbers (Nominal 94.9W/4200MHz vs
Level2 86.5W/4600MHz) — explanation: hitting different phases of the EC's 2-minute
turbo window (see the 45W-ceiling session), a single snapshot isn't representative.

CONTROLLED REPEAT (fixed point t+30..50s from rearming, 3 trials):
  Nominal        : 77.7W  avg P-core 4397 MHz
  Level2 (65W)    : 78.5W  avg P-core 2196 MHz  <- TWICE AS BAD at the same W
  Nominal repeat : 75.5W  avg P-core 4368 MHz
CONCLUSION: switching to Level2 does NOT raise the actual ceiling — this laptop's
EC interprets the cTDP control change as a signal to cut the turbo ratio limit,
not as permission for a higher TDP. The effect is the opposite of expected.
No point testing Level1 (45W down) — that's a deliberate downgrade.

DECISION: 0x64B reset to Nominal (0x0), not to be touched going forward. All the power
gain on this system comes through throttled PL1/PL2 (RAPL), not cTDP.

## 2026-07-30 — Session 27: sustained-turbo — the long-lived process hangs

Observation: the auto-mode daemon was silent for 43 min (last log 10:46:22) despite
real compile load from clang++ at 88-95% the whole time. The accumulation logic
(above/below counters), when replayed manually with the same code on real
/proc/stat data, worked correctly within 60s — so the bug is NOT in the algorithm.
The script file hadn't changed since the process started (checked /proc/PID/exe,
fd 255 -> the current file) — not a stale-version issue.
Most likely cause: a one-off diff_total<=0 miscalculation in this specific
long-lived bash process permanently zeroed the accumulation (prev_idle/prev_total
persist in process variables, not reread from scratch).

FIX: rc-service sustained-turbo restart. The new process activated
exactly 60s later under the same load (ACTIVATION 11:37:46, PL1 95W confirmed by
real draw). PRACTICAL RULE: if auto mode isn't reacting despite obvious
load — just restart it, don't debug the logic.

## 2026-07-31 — Session 28: sustained-turbo kept dying; MODE=always instead of auto

During an actual kernel compile (total CPU=2452%, genuine 100% load),
draw=45.0W, P-avg only 2863MHz — the daemon hadn't rearmed.
The log showed 3 restarts in an hour (21:13/21:17/21:24) with no ACTIVATION
between them -> auto mode kept losing its 60s accumulation counter on every death.

INVESTIGATION of the cause (nothing found):
  dmesg: zero mentions of sustained-turbo/oom/kill at the relevant moments
  cgroup /openrc.sustained-turbo: memory.events oom_kill=0, pids.max=max,
    memory.max=max, cpu.max=max -> NOT a cgroup limit
  process etimes showed the current instance had just started (13s) -> died
    literally while being diagnosed
THE CAUSE REMAINS UNESTABLISHED. Documented as an open question.

FIX (practical, doesn't address the cause): /etc/conf.d/sustained-turbo
MODE="${MODE:-always}" instead of auto. always rearms on EVERY cycle start
with no state -> even frequent unexplained deaths self-heal, because there's
no need to reaccumulate 60s of load.

CORRECTING MY OWN MISTAKE: first I told the user that always "holds
78-80C constantly regardless of load" — this is WRONG. The user
corrected it: rearming only lifts the EC's power ceiling, it's not a
forced boost. Verified empirically: always active, compile
finished, real load dropped -> draw=14.8W temp=55C fans=0 RPM.
The mechanism is free at idle. MODE=auto as an "idle heat saving" measure was
an unnecessary complication with no benefit — always can be left on permanently.

## 2026-08-01 — Session 29: cause of the silent fans + a custom curve

### Cause (found in the driver code /usr/src/linux-*/drivers/platform/x86/hp/hp-wmi.c)
Every write to platform_profile calls hp_wmi_get_fan_count_userdefine_trigger(),
which holds the EC in a "user-defined thermal/fan state" for 120s. sustained-turbo always
rearms every 90s (< 120s) -> the EC NEVER returns to the fallback that
pwm1_enable=2 (auto) depends on on the 8C99 board (upstream "Unknown EC layout",
no fallback table for this board). So the auto curve never worked at all
while the daemon was active — not just in always, but in auto too while under load.

### Fix
/usr/local/bin/sustained-turbo now manages the fans itself (pwm1_enable=1)
for the whole time it's rearming; returns the EC (pwm1_enable=2) when not intervening
(auto: on deactivation; always: until the service stops).
Curve (CPU Package temp, coretemp, found dynamically via hwmon *name*):
  <70C  -> pwm=90  (~1900 RPM, minimum floor, NEVER 0 — per requirement)
  70-80 -> pwm=140
  80-90 -> pwm=193 (~4300-4400 RPM, verified value)
  >=90  -> pwm=255 (maximum)
Calibrated: pwm=90 -> readback=83 -> 1900/1900 RPM (exact measurement, not an estimate).
Verified through a full load cycle: 55C->0(old version)/90(new),
75C->140, 88C->193, 91C->255, and back the same way while cooling.
The fan hwmon (hp) and CPU temp (coretemp Package) are looked up by sensor name
dynamically — the hwmoN number shifts between kernels (5->6 from trim7->trim8).
