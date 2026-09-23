# system-lab

My lab for the HP Victus 16 (i7-14650HX + RTX 4070 Max-Q, Gentoo/OpenRC, CachyOS kernel built with Clang). This holds everything I've done to the machine itself, not the software on it: BIOS unlock, undervolt, power limits, fans, custom kernel builds, and service files.

This isn't one project but an archive of experiments with conclusions. I keep it in git to see what changed and why. The journal in `victus-tuning/docs/journal.md` (29 sessions, Jul 24 – Aug 1 2026) remains the primary source. This README compresses it and points to where things live.

> ⚠️ **Every numeric value here (undervolt, PL, fan curves, BIOS offsets) is for my silicon: i7-14650HX, HP board 8C99, BIOS F.15.** Every die has its own stability margin, and on a different board the MSR/NVRAM offsets mean something else. Don't carry these over as a recommendation. A mistake can silently corrupt data or leave the laptop unbootable. Scripts that write to MSR, sysfs, or EFI refuse to run on a different board on their own (`victus-tuning/scripts/board-guard.sh`, exit code 64).

> State as of 2026-09-19.

---

## 1. Repository map

```
system-lab/
├── README.md              ← you are here
├── Makefile               make db | queries | check
├── stack/                 data stack: build_db.py + queries.sql
├── data/lab.db             SQLite, derived; local only, built by `make db`
├── victus-tuning/         BIOS unlock, undervolt, RAPL, fans
│   ├── docs/              journal.md, SYSTEM-REFERENCE.md, ROLLBACK.txt
│   ├── scripts/           18 test/diagnostic/build/BIOS-analysis scripts
│   ├── data/               7 undervolt-campaign CSVs + profile-sweep + uv-campaign.status
│   ├── logs/               61 logs: y-cruncher (yc-*), stress-ng (uv-*), validation, diagnostics
│   ├── bios/               patch-*.csv (byte-level changes), apply_patch.py, README (no images)
│   ├── backup/             throttled.conf versions; locally also raw BIOS variable dumps (not public)
│   ├── usb-payload/       UEFI Shell + setup_var.efi + README-flash.md (.efi not public)
│   └── restore.sh          restores CpuSetup/SaSetup/Setup from backup (local only)
├── kernel/
│   ├── config/             kernel 7.1.3 trim9 .config (Full LTO, BORE)
│   ├── scripts/            build-kernel-7.1.3.sh, build-trim9.sh
│   ├── logs/                build logs for 7.1.8, trim10/11, AutoFDO, perf, emerge
│   ├── grub/                40_custom (old GRUB entry for trim3)
│   └── autofdo-work/       perf profile (62 GB) and the generated .afdo (local only)
├── diag/                   133 text diagnostic snapshots (local only)
├── flashing/               Pixel "mustang" firmware and PixelFlasher (local only)
├── tools/                  Ventoy (local only)
└── misc/                   benches, csv snippets, native.dtb (local only)
```

**The public copy is built from an allow-list** (`python3 stack/export_public.py <dir>`): only what's explicitly allowed goes in, and that copy's `.gitignore` is `*` plus `!/path` for each allowed file. A new file I add later doesn't reach the public repo by itself. The script sanitizes paths (`/home/…` → `~`/`$HOME`), replaces partition UUIDs, and aborts the build if it finds this machine's serial numbers, UUIDs, MACs, machine-id, hostname, email, or secret-looking strings.

**Not included in the public copy** (stays only in my local repo or on disk):

| What | Why |
|---|---|
| The BIOS images themselves (`~/Documents/Bios Binaries/`) | They contain my machine's serial number (confirmed by direct comparison), the ME region, live NVRAM, and HP/Insyde code. I publish only hashes and the patch description in `victus-tuning/bios/`. |
| `diag/`, `misc/` | Raw noise: 5 MB of snapshots, assorted files. |
| `kernel/autofdo-work/` (62 GB) | Generated large files. |
| `flashing/`, `tools/`, `usb-payload/*.efi` | Third-party binaries (Google, Ventoy, PixelFlasher, UEFI Shell, `setup_var.efi`). Get these from upstream. |
| `data/lab.db` | Derived database. The CSVs live in the repo; `make db` builds the database (can be shipped as a release artifact). |

**BIOS.** No images and no NVRAM dumps are in the public copy. A deep scan (ASCII, UTF-16LE, UUIDs in both byte orders, raw-byte MACs, machine-id, disk GUIDs) showed that all my images contain the serial number, board serial, chassis serial, SKU, product UUID, and disk GUID. The `Setup`-variable dumps turned out clean, but I don't publish those either: their layout depends on the BIOS version, and restoring a dump from a different version breaks the settings. Instead I publish byte-level CSV patches and `apply_patch.py`, which checks the old byte at every offset and refuses to run if they don't match (`victus-tuning/bios/`). `restore.sh` stays only in my working copy, along with the dumps it restores.

---

## 2. History: how I got here

**The starting problem.** Under full load the laptop sat at 44 W and ~2.1 GHz, even though I remembered it pulling 120 W. The game (Rust) had frame drops. I wanted an undervolt to get more clock at the same power budget.

What came out, in order (sessions 1–21, 24–26 July):

1. **The locks were already off, but the master switch wasn't.** `CFG Lock` and `OC Lock` were 0 in the live system, but `OverClocking Feature` (CpuSetup, offset `0x1D9`) was 0. Because of that, the OC mailbox (MSR `0x150`) silently ignored writes, and `intel-undervolt`/`throttled` reported `Values do not equal`.
2. **Writing the variable from the OS didn't work.** Insyde H2O rejects runtime `SetVariable` for Setup variables (`EROFS`). It's only possible from boot services — a UEFI Shell or the chip itself. I prepared a USB stick with `setup_var.efi` (`usb-payload/`), and in the end flashed a patched image.
3. **The BIOS image.** I analyzed three images, parsed the VSS store (`vss-parse.py`), found every `*Lock` in the IFR (`ifr-locks.py`), and verified before flashing (`verify-final.py`, 14 bytes, 5 copies of CpuSetup). On July 26 I flashed `biosunlock-oc-max.bin`, and the mailbox came alive.
4. **The "44 W" cause wasn't the EC — it was software.** It's `throttled`, which writes PL1/PL2 to both MSR `0x610` and MMIO `MCHBAR+0x59A0`. MMIO wins. Then a second effect showed up: the EC gives full PL1 for only ~2–2.5 min, then throttles to ~45 W. The workaround is writing `performance` to `/sys/firmware/acpi/platform_profile` (the *write* is what matters, not the value). That grew into the `sustained-turbo` daemon.
5. **Undervolt (28–29 July).** A real gain only shows up on PL-bound load: at 80 W the all-core clock rose from 2733 to 3553 MHz (**+30%**) at −100 mV. Mixed load looked like "nothing" only because it wasn't loading the CPU enough (those CSV rows are flagged `MIXED-INVALID`).
6. **The most important methodology mistake.** One all-core test isn't enough. The CPU has two V/F points: all-core (~3.9 GHz / 0.89 V) and light-load boost (4.6–4.9 GHz / 1.03–1.13 V). `CORE −160` passed all-core and failed on boost. WHEA/MCE were 0 on every failure, so the only reliable detector is y-cruncher (`Mismatch`, `Exception`, `: Failed`).
7. **Fans (Aug 1).** `hp_wmi` holds the EC in a "user-defined" state for 120 s after every write to `platform_profile`. The daemon rewrites every 90 s, so the EC never returns to auto. So `sustained-turbo` now drives its own curve by temperature and load.

In parallel (Sep 2026) I built my own kernel with all of this in mind: Full LTO on Clang 22, an AutoFDO profile, and a mass build across thousands of hardware combinations — now its own project, [`kernel-matrix`](https://github.com/tarilka0gg/kernel-matrix).

---

## 3. victus-tuning: what's there and what I know

### BIOS
Unlocked: `OverClocking Feature`, `CFG Lock`, `Overclocking Lock`, a third lock at `0x381`, `PROCHOT Lock`, `HwP Lock`, `Tcc Offset Lock`. Patched in all 5 copies of CpuSetup inside the image. Rollback is reflashing the original.

### Undervolt limits (PL1=80 W / PL2=115 W)

| Domain | Last passing point | Break point |
|---|---|---|
| CORE | **−150 mV** | −160 → silent failure on boost, −165 → also on all-core |
| CACHE | **−175 mV** | −180 → fails on light-load boost |
| GPU (iGPU) | −150 mV, no break point found | — |
| UNCORE / System Agent | **do not touch** | risk of silently corrupted memory |
| ANALOGIO | don't touch | gives nothing |

"Passing" only means the point survived y-cruncher (all-core and light-load boost) at PL 80/115 W. It's not a guarantee of everyday stability, and not a value to carry over to another die.

CORE drives the shared VccIA rail voltage (method: "who's holding it" — CORE −20 gives +17 mV of delta, CACHE −20 gives +2 mV = noise). CACHE doesn't move the voltage but has its own limit.

### Power
- `throttled` (OpenRC, autostart) writes PL1/PL2 to both registers. Config: `/etc/throttled.conf`.
- cTDP (MSR `0x648–0x64B`): don't touch. Switching to Level2 halves the clock (4397 → 2196 MHz) at the same power (session 26).
- EC turbo budget: rearmed by writing to `platform_profile` every 90 s (`sustained-turbo` daemon under `supervise-daemon`; mode is currently `auto`, see section 6).
- Resume hook: `/lib/elogind/system-sleep/90-power-limits-rearm`.

### Gaming tuning
EPP=`performance`, C3 disabled (input micro-stutters), `gamemode` set up. Result: Rust at 130 FPS, GPU became the bottleneck. Side effect: a one-off `dbus-launch` fork chain (71,403 processes, 25 GB) when launched via `gamemoderun`. `dbus-launch-watchdog.sh` guards against it.

### Scripts (`victus-tuning/scripts/`)

| Group | Scripts |
|---|---|
| Undervolt campaign | `uv-campaign.sh`, `uv-plbound-ab.sh`, `uv-test.sh`, `measure-pcore.sh` |
| Mailbox state | `read-mailbox.py` (read-only, rollback check) |
| Strict validation | `validate.sh` (y-cruncher + PL-bound + idle), `run-bracket.sh`, `boost-test.sh`, `cache-sweep.sh`, `who-holds.sh` |
| 45 W diagnostics | `diag-45w.sh`, `diag-hwp.sh`, `profile-sweep.sh` |
| Services | `dbus-launch-watchdog.sh` |
| Kernel builds | `build-trim10.sh`, `build-trim11.sh` |
| BIOS analysis | `ifr-locks.py`, `vss-parse.py`, `verify-final.py`, `../bios/apply_patch.py` (plus local-only `../restore.sh`) |

Paths in the scripts are relative: `BASE` is derived from the script's location, and output goes to `data/` and `logs/`. The scripts load the system and write to MSR/sysfs, so after moving paths around only syntax has been checked (`make check`).

---

## 4. kernel: builds

- **Evolution:** `7.1.3-trim9` (Full LTO) → `trim10` → `trim11` (7.1.6 sources) → **`7.1.8-cachyos1-tuned`**, which is running now. Built with Clang 22.1.8, `AUTOFDO_CLANG=y` and `PROPELLER_CLANG=y`, BORE, `HZ=1000`, `X86_NATIVE_CPU`, `PREEMPT_DYNAMIC`. `LTO_CLANG` is absent from the live config (`/proc/config.gz`). The `.config` in `kernel/config/` belongs to the old `trim9` (Full LTO), not the current kernel.
- **Bootloader:** now Limine (GRUB removed 07-30). The menu has three kernels: 7.1.8 (primary, tagged "autofdo+profile applied, propeller baseline"), 7.1.6 trim11, and 7.1.3 trim10 as `[fallback]`. The build script copies `vmlinuz` and microcode to the ESP, writes `limine.conf` to both locations (`/EFI/limine/` and the fallback `/EFI/boot/`), and keeps the previous kernel as `[fallback]`. `timeout: 0`, menu opened with Shift/Esc.
- **Protection against a broken .config:** the build script diffs the tree against a backup (Portage already re-unpacked the sources once and reset the config).
- **AutoFDO:** `perf record` during kernel compilation (three attempts, 19 → 26 → 62 GB); `kernel-compilation.afdo` (2.8 MB) was produced from the profile. The raw 62 GB `.data` file is no longer needed. Build logs for 7.1.8: 6 successful, 1 with an error (`build3`: `.qmi_interface.o.cmd: unterminated call to function 'wildcard'`).
- **GRUB:** `grub/40_custom.bak-20260728` — the `trim3` entry without an initramfs, a leftover from before the move to Limine.

The mass build across thousands of CPU × GPU × platform × EC combinations now lives in its own repo, [`kernel-matrix`](https://github.com/tarilka0gg/kernel-matrix), and isn't part of system-lab anymore.

---

## 5. Data stack

All structured data is consolidated into `data/lab.db` (SQLite, stdlib only). The database is derived: `make db` builds it from CSVs, logs, the journal, and the filesystem.

| Table | What's in it | Rows |
|---|---|---|
| `uv_asym`, `uv_cache`, `uv_boost`, `uv_campaign`, `uv_percore`, `uv_plbound` | undervolt campaign results | 5 / 14 / 1 / 7 / 2 / 2 |
| `profile_sweep` | draw/frequency/temp by `platform_profile` | 72 |
| `yc_runs` | parsed from 25 y-cruncher logs: PASS / FAIL / NO_RESULT | 25 |
| `throttled_configs` | every version of `throttled.conf` + `LIVE` (key/value) | 174 |
| `journal_sessions` | 29 sessions: date, title, line range | 29 |
| `diag_files` | index of diagnostic snapshots | 132 |
| `files` | inventory: path, group, size, sha256 | ~1100 |

```bash
make db        # rebuild
make queries   # canned queries from stack/queries.sql
sqlite3 data/lab.db "select * from uv_cache order by core_mv"
```

---

## 6. Discrepancies and open questions

1. **The live config diverges from what was validated.** `queries.sql` (query 2) compares it against `FINAL-150-175-150`:
   - AC: PL1/PL2 = **95/135 W** (validation was at 80/115), CACHE = **0** (was passing up to −175), GPU = −120. CORE = −150 matches.
   - BATTERY: **CORE = −210 mV**. The journal (session 25) records −150 for battery, and the −210 value isn't described anywhere and has no y-cruncher logs backing it. Battery has different PLs (11.5/14 W), so the V/F regime differs, but that's an assumption, not a tested result.
2. **The check at 95/135 was never finished.** `logs/validate-pl95-135-live.log` and `yc-pl95-135-live.log` cut off at 0.5 s. No verdict. SYSTEM-REFERENCE explicitly asks for a 10-min all-core and 3-min boost run at these PLs.
3. **`ROLLBACK.txt` is stale.** It names "last stable: CORE −160 / CACHE −140", but `-160` fails on light-load boost (`uv_cache`, `yc-*.log`). A note about this was added to the file's header, and `throttled.conf.last-stable-160` was removed from the public copy.
4. **The BIOS images exist, but not where the docs point, and aren't public.** They're at `~/Documents/Bios Binaries/` (`08C99.bin`, `biosstock.bin`, `biosstock.bin.bak`, `biosunlock`, `biosunlock-oc.bin`, `biosunlock-oc-max.bin`, and `FLASH-ORDER.txt`), while `SYSTEM-REFERENCE.md` points to `~/biosunlock*.bin`. SHA256s match the journal: `biosstock.bin.bak` = `87ac5970…` (the real stock image), `biosunlock` = `3106c79c…`. A BIOS rollback is possible: reflash `biosstock.bin.bak`. The files aren't in git and weren't moved. `apply_patch.py` reproduces the flashed image from `biosunlock` byte-for-byte (checked, SHA matches).
5. **`sustained-turbo`: `auto` or `always`.** The journal (session 28) records switching to `always` on July 31, but `/etc/conf.d/sustained-turbo` has `MODE="${MODE:-auto}"`, and the Sep 19 log says "mode auto". The cause of the earlier `auto` failures is marked unresolved in the journal.
6. **Image names are confusing** (session 8): `biosstock.bin` contains patched content; the real stock image is `biosstock.bin.bak`.
7. **Paths in the docs are historical.** The journal and `SYSTEM-REFERENCE.md` were written when the folder was called `~/victus-unlock`; I never corrected them.
8. **Disk space.** `autofdo-work/kernel-compilation.data` (62 GB) and `flashing/` (23 GB) are ~85 of ~87 GB. `.data` can be deleted since `.afdo` exists.

---

## 6a. What's actually running right now (checked 2026-09-19, uptime 8h)

Not from old notes — read straight from the live system:

| What | Value | How checked |
|---|---|---|
| Kernel | `7.1.8-cachyos1-tuned`, Clang 22.1.8, AutoFDO + Propeller, no LTO | `uname`, `/proc/config.gz` |
| Power | AC, battery `Full` | `power_supply` |
| PL1 / PL2 | **95 / 135 W**, enable=1 | MSR `0x610` |
| Undervolt (mailbox) | CORE **−150.4**, GPU **−120.1**, CACHE 0, UNCORE 0, ANALOGIO 0 mV | MSR `0x150`, read |
| Locks | `0x194 = 0xf0000`, `0xE2 = 0x74000008` (CFG/OC off) | MSR |
| Services | `throttled` and `sustained-turbo` `started`, under `supervise-daemon` | `rc-status` |
| Turbo mode | **auto** (threshold 70% / hold 60s / release 45s), fan curve always active | config and log |
| Fans | manual mode (`pwm1_enable=1`), ~2000 RPM idle, pwm≈103 at 67°C | `hwmon`, `sensors` |
| Fan curve | by temperature `60:45 70:110 80:150 88:190 92:225 95:255` and by power `25:45 … 140:255` | `/etc/conf.d/sustained-turbo` |
| platform_profile / governor / EPP | `performance` / `powersave` / `performance` | sysfs |
| C3 | disabled on all 24 threads | `state3/disable` |
| turbo | enabled (`no_turbo=0`) | sysfs |
| Autostart | `/etc/local.d/performance.start` and resume hook `90-power-limits-rearm` in place | files |
| Bootloader | Limine, three kernels (7.1.8 / 7.1.6 / 7.1.3 fallback) | `limine.conf` |
| dGPU | RTX 4070 Laptop, P0, max 3105 MHz | `nvidia-smi` |

**Not running at the time of the check:** `gamemoded` and `dbus-launch-watchdog.sh`. The resume hook, per the journal (session 16), is marked as never verified against a real suspend/resume.

**Discrepancies with the journal and reference:**
- The fan curve in `/etc/conf.d/sustained-turbo` differs from what session 29 describes (there: thresholds 70/80/90 and pwm 90/140/193/255): now there are curves by both temperature and power. The journal doesn't describe this.
- `performance.start` does more than the journal says: besides rearming the EC, EPP, and C3, it sets THP to `madvise`, `shmem_enabled=advise`, and backstops a 16 GB zram swap (zstd).
- The kernel now isn't what the build scripts describe (`trim9`, Full LTO).

**Still unverified:** behavior on battery (CORE −210), stability at PL 95/135 (y-cruncher never finished), the cause of past `auto` failures.

---

## 7. Quick recipes

**Emergency undervolt rollback** (not BIOS). Stopping `throttled` does **not** clear the offset already written to MSR `0x150`: it holds until overwritten with zeros or a reboot happens. So:
1. In `/etc/throttled.conf` set every value in `[UNDERVOLT.AC]` and `[UNDERVOLT.BATTERY]` (`CORE`, `GPU`, `CACHE`, `UNCORE`, `ANALOGIO`) to `0`.
2. `rc-service throttled restart`: it writes zeros to the mailbox every second. If the system misbehaves, reboot.
3. Only after that, if needed, restore a point that passed testing: `victus-tuning/backup/throttled.conf.FINAL-150-175-150` (CORE −150, CACHE −175, GPU −150 at PL 80/115). This is "the last passing point," not a safe default.

4. **Verify the rollback actually took:** `sudo python3 victus-tuning/scripts/read-mailbox.py` reads the mailbox (MSR `0x150`) and should show `+0.0 mV` in all five domains and "ALL ZERO" (exit code 0). A nonzero value means the offset is still applied and the rollback isn't done.

`throttled` reapplies its config on boot, so an unstable value survives a reboot. Right after startup, run `rc-service throttled stop` and fix the config.

**Stability test:** `/opt/y-cruncher/y-cruncher stress -M:4G -D:60 -TL:600`, then the same on 1–2 threads via `taskset` (`scripts/boost-test.sh`). Look for `Exception`, `Mismatch`, `: Failed`. Don't confuse this with `Stop on Error: Enabled`.

**Kernel build:** `kernel/scripts/build-kernel-7.1.3.sh` (as yourself, via `doas`) or `build-trim9.sh` (as root). Both take the config from `kernel/config/kernel-config-7.1.3-cachyos-trim9-tuned`.

**If turbo doesn't hold:**
1. `rc-service sustained-turbo status`, `tail /var/log/sustained-turbo.log`
2. Measure real draw via counter `0x611`; MSR `0x610` only shows the config.
3. Manually: `echo performance > /sys/firmware/acpi/platform_profile`
4. Just `restart` the service — don't debug the logic (session 27).

---

## 8. Local-only folders

Not in the public repo:

- **`diag/`**: 133 text snapshots (temperatures, `cpu_capacity`, build-log tails), a byproduct of local diagnostics.
- **`flashing/`**: Pixel `mustang-cp2a.260805.005` firmware image and PixelFlasher.
- **`tools/`**: Ventoy 1.1.17.
- **`misc/`**: `benches` (Ring-2Zero v0.176 benchmark output), two `nvidia-smi` snippets, `native.dtb`.
- **`data/lab.db`**: SQLite, built by `make db`.

---

## 9. Git and licenses

- **Licenses:** scripts and code — MIT (`LICENSE`), docs and data — CC BY 4.0 (`LICENSE-docs`), `kernel/` — GPL-2.0 (`kernel/LICENSE`).
- **New experiment:** write it up in `docs/journal.md`, drop CSVs and logs into `data/` and `logs/`, run `make db`, commit. For a file to reach the public repo, add its path to `ALLOW` in `stack/export_public.py`.
