# HP Victus 16-r1xxx — system reference

Last verified: 2026-07-29. Source of detail — `victus-unlock/journal.md` (full chronological log, 1000+ lines).

## Hardware

- **Model**: HP Victus by HP Gaming Laptop 16-r1xxx
- **CPU**: Intel Core i7-14650HX (Raptor Lake HX, 8P+8E)
  - P-cores: `cpu0-15` (8 physical × HT), ceiling 5.0–5.2 GHz
  - E-cores: `cpu16-23`, ceiling 3.7 GHz, no HT
- **GPU**: iGPU Intel UHD (Raptor Lake-S) — drives the **internal display** (`card1-eDP-1`, i915); dGPU NVIDIA RTX 4070 Max-Q — drives the external output (`card0-DP-1`)
- **BIOS**: Insyde H2O, version **F.15**, dated 01/13/2025

---

## 1. BIOS — overclocking unlock

### State
Flashed with the custom image `biosunlock-oc-max.bin` (lives at `~/biosunlock-oc-max.bin`, 16 MB). Unlocked:
- `OverClocking Feature` (CpuSetup `0x1D9`) = 1
- `CFG Lock` (`0x43`), `Overclocking Lock` (`0x10E`), a third lock (`0x381`) = 0
- `PROCHOT Lock` (`0x7D`), `HwP Lock` (`0x228`), `Tcc Offset Lock` (`0x1CD`) = 0

Patched in **all 5 copies** of CpuSetup inside the image (DEFAULTS-1/2/3 + NVRAM working + backup) so a reset to defaults doesn't roll the settings back.

### Effect
The OC mailbox (**MSR 0x150**) came alive — without this patch, `intel-undervolt`/throttled writes to the voltage offset were silently ignored (`Values do not equal`). This is the precondition for everything about undervolting below.

### Rollback / emergency files
- `~/biosunlock.bin` — original image BEFORE the patch (can be reflashed)
- `~/victus-unlock/backup/` — backups of every `throttled.conf` iteration
- `~/victus-unlock/ROLLBACK.txt` — quick undervolt rollback instructions (not BIOS)

---

## 2. Undervolt (campaign in `victus-unlock/uv-*.csv`, `journal.md` sessions 13–26)

### Control
**Only through `/etc/throttled.conf`**, sections `[UNDERVOLT.AC]` / `[UNDERVOLT.BATTERY]`. Do NOT use `intel-undervolt apply` at the same time — both write to the same MSR 0x150, a write race.

### Stability limits found (at PL1=80W/PL2=115W — the validation conditions!)

| domain | what it controls | safe limit | break point |
|---|---|---|---|
| **CORE** | drives the shared VccIA rail voltage | **down to −150 mV** | `−160` already causes a silent compute error (boost point), `−165` — also on all-core |
| **CACHE** | does NOT move the rail voltage (checked three times, delta <5mV = noise), but has its own limit | **down to −175 mV** | `−180` fails on light-load boost |
| **GPU (iGPU)** | separate VccGT rail | down to −150 mV checked clean, no limit found yet (margin left) | — |
| **UNCORE (System Agent)** | memory controller + PCIe + display engine | **DO NOT TOUCH** | savings of 0.05W = noise, but the risk is silently corrupted memory that no test catches |
| **ANALOGIO** | analog block | DO NOT TOUCH | microscopic draw, no point |

### CRITICAL note on test methodology
A single all-core stress test is **not enough**. The CPU has two fundamentally different V/F points:
- **all-core** (all 24 threads, e.g. `stress-ng --cpu 24 --cpu-method matrixprod`) → ~3.9 GHz / 0.89 V
- **light-load boost** (1-4 threads free) → **4.6–4.9 GHz / 1.03–1.13 V** — a completely different point, and exactly where the undervolt breaks

Test BOTH points. `CORE −160` passed all-core but failed on boost — found only after a targeted test on 1-2 threads.

**WHEA counters (dmesg) are useless for detection.** Every failing point showed `WHEA=0, MCE=0`. The only reliable detector is compute correctness: **y-cruncher** (`/opt/y-cruncher/y-cruncher stress`), command:
```
./y-cruncher stress -M:4G -D:60 -TL:<seconds>
```
Signs of a real failure in the log: `Exception Encountered`, `Mismatch`, `: Failed`, `error(s) encountered` (search with `grep -i`, case varies). Do NOT confuse this with the harmless config line `Stop on Error: Enabled`.

### Current live config (verified 2026-07-29, after this reference was written)
```
[UNDERVOLT.AC]       CORE -150   GPU -120   CACHE -150   UNCORE 0   ANALOGIO 0
[UNDERVOLT.BATTERY]  CORE -160   GPU -120   CACHE -150   UNCORE 0   ANALOGIO 0
```
Mailbox confirms: CPU −150.39, GPU −120.12, Cache −150.39 mV.

> ⚠️ **IMPORTANT — discrepancy with validation.** The campaign validated `CORE −150 / CACHE −175 / GPU −150` **at PL1=80W/PL2=115W**. The live config now has different CACHE (−150, more conservative — OK) and GPU (−120, also more conservative — OK), BUT **PL1/PL2 are raised to 95W/135W** — **nobody has tested** this power combination with the undervolt. A higher PL2 means the possibility of a deeper V/F dive (lower frequency at higher current) — i.e., a zone where new instability could show up. **Before trusting this config, run y-cruncher (10min all-core + 3min boost on 1-2 threads) at exactly these PLs.**

### Quick rollback (if instability is suspected — corrupted files, odd crashes, compile errors)
Stopping `throttled` does NOT clear the offset: what's written to MSR `0x150` holds until overwritten with zeros or a reboot.
```bash
# 1) set every offset in [UNDERVOLT.AC] and [UNDERVOLT.BATTERY] to 0 in /etc/throttled.conf
# 2) throttled writes zeros to the mailbox every second:
rc-service throttled restart          # if things look off, reboot
```
Verify the rollback took: `python3 victus-tuning/scripts/read-mailbox.py` (read-only) — all 5 domains should read `+0.0 mV`.

Only after that, if needed, restore the last PASSING point (not a "safe" one, PL 80/115!):
`cp ~/victus-unlock/backup/throttled.conf.FINAL-150-175-150 /etc/throttled.conf`

**Sign of silent instability**: NOT a crash and NOT a dmesg entry. Shows up as corrupted archives, compile errors that don't reproduce, odd compute results. If suspected, the first thing to do: `/opt/y-cruncher/y-cruncher stress -M:4G -D:60 -TL:600` for 10 minutes.

---

## 3. Power Limits (RAPL, not to be confused with BIOS cTDP)

### Mechanism
Managed by `throttled` (sys-power/throttled), an OpenRC service, autostarts (`rc-update show` confirms). Writes to **both** registers at once:
- **MSR 0x610** (RAPL package power limit)
- **MMIO MCHBAR+0x59A0** (the same limit, duplicated; if these ever desync, MMIO wins)

Config: `/etc/throttled.conf`, sections `[AC]` / `[BATTERY]`, fields `PL1_Tdp_W`, `PL2_Tdp_W`, `Update_Rate_s`.

Current: **AC: PL1=95W, PL2=135W**, `Update_Rate_s=1`, `Trip_Temp_C=95`.

### ⚠️ EC turbo budget — the main power trap
The EC gives full PL1 for only **~2–2.5 minutes** after rearming, then hard-throttles to ~45W / ratio 28 (HWP guaranteed level), **regardless** of what's written in the RAPL MSR/MMIO (they keep showing 80W+ allowed — this isn't a RAPL limit).

**Workaround**: writing `performance` to `/sys/firmware/acpi/platform_profile` (even if it's already `performance` — the WRITE itself matters, not the value) instantly "rearms" the EC and turbo comes back for ~2 min. The `powerprofilesctl set performance` daemon does NOT do this if the profile is already the same (no-op) — a direct `echo` is needed.

For sustained workloads (compiling, rendering) there's a service:
```
/usr/local/bin/sustained-turbo
rc-service sustained-turbo start|stop|status
```
**In autostart** (`rc-update add sustained-turbo default`) — comes up on its own after reboot.

**MODE=always (current, since 2026-07-31)**, not `auto`. Reason for the switch: `auto`
died silently several times a day with NO trace in dmesg/oom_kill/cgroup
events — the cause of the failures was never established. `auto` lost its accumulated 60s
load counter on every such failure and never managed to activate in time,
so kernel compiles silently ran at ~45W instead of 95W without the user noticing.
`always` is more resilient: it rearms IMMEDIATELY on every cycle start,
with no state that can be lost — even frequent failures self-heal.

**Important about the mechanism**: rearming is just the write `echo performance >
platform_profile`, which lifts the EC's power ceiling. It does NOT force a
boost and costs NOTHING on its own. Actual draw is still dictated by
the real workload. Verified empirically: always active, compile
finished, load dropped to background -> draw=14.8W, temp=55C, fans at
zero. So always can be left on permanently with no cost at idle; auto as
an "idle heat saving" mechanism turned out unnecessary — there was nothing to save.

**Supervised by `supervise-daemon`** (respawn_delay=5, max=10 in 60s) —
restarts on failure, checked with `kill -9` -> recovers in 6s.

**If turbo still doesn't hold** — diagnose in order:
1. `rc-service sustained-turbo status` + `ps aux | grep sustained-turbo`
2. `tail /var/log/sustained-turbo.log` — is the daemon alive at all, or stuck in a crash loop
3. Real draw (not MSR!): MSR 0x610 always shows the config, that is NOT proof.
   Measure with the energy counter 0x611 — see examples in journal.md
4. Manual rearm: `echo performance > /sys/firmware/acpi/platform_profile`

### cTDP (BIOS level, MSR 0x648-0x64B) — DO NOT TOUCH
- `0x649` (Level1/down, 45W) and `0x64A` (Level2/up, 65W) — **read-only**, `wrmsr` is rejected by the hardware
- `0x64B` (control switch between levels) is writable, BUT a controlled test showed: switching to Level2 **halves** the real clock (4397→2196 MHz) at the same power. The EC interprets the change as a signal to lower the turbo ratio limit, not as permission. Left at `Nominal (0x0)`.

---

## 4. Fans

### Hardware
- 2 fans, `hp_wmi` driver (rare — HP usually doesn't expose direct access)
- Sensors: `/sys/devices/platform/hp-wmi/hwmon/hwmon5/fan1_input`, `fan2_input`
- Control: `pwm1` (0-255, shared by both fans — there's no separate control for fan2), `pwm1_enable` (2=auto/EC, 1=manual)

### Verified in practice
Switching `pwm1_enable=1` and writing to `pwm1` **actually works** — a test jump gave 3900/4200 → 4400/4400 RPM in 3s. Values are rounded by the driver to discrete steps (wrote 220, got 193).

**Auto mode restored (`pwm1_enable=2`)** — manual mode was NOT left active. A full pwm→RPM map (min/max, step, linearity) hasn't been taken yet.

### Risk of manual mode
With no temperature binding, a low PWM under load means overheating with no software protection (only the hardware thermal shutdown remains). If a permanent manual curve is ever set up, it must be tied to `x86_pkg_temp` (currently `62°C` idle, `78-83°C` under PL-bound load with the undervolt).

---

## 5. C-states / idle

`state3` (C3_ACPI, latency 1048µs) — **disabled on AC** (`disable=1`) to eliminate input micro-stutters in games. Cost: a significant rise in idle draw on battery (found: 44W instead of ~26W with C3 restored).

**Recommendation not implemented**: C3 and `platform_profile` should depend on power source (AC=off/performance, Battery=on/balanced) — currently both are static via `/etc/local.d/performance.start`, the same regardless of power source.

---

## 6. Measured power breakdown (for reference)

Under all-core load (~80W package): cores ~67W, uncore ~12W, iGPU ~0.8W.
Idle on battery (~26-40W whole system): the CPU package is only ~10W (cores ~2W, uncore ~8W), the rest (display+dGPU+NVMe+WiFi) is **60-70% of total draw**. The biggest lever for battery life is NOT CPU undervolt but C3/profile (above) and dGPU state (the RTX 4070 holds ~2.5-4W even idle, doesn't always drop to D3cold).

---

## Key files

| file | purpose |
|---|---|
| `victus-unlock/journal.md` | full chronological log of every session, with exact numbers and methodology mistakes |
| `victus-unlock/ROLLBACK.txt` | emergency undervolt rollback |
| `victus-unlock/backup/throttled.conf.FINAL-150-175-150` | last FULLY validated configuration (at PL 80/115!) |
| `victus-unlock/uv-*.csv` | raw undervolt campaign results (Vcore/freq/temp/WHEA per point) |
| `~/biosunlock-oc-max.bin` / `~/biosunlock.bin` | flashed image / original before the patch |
| `/opt/y-cruncher/` | tool for the compute-correctness test (undervolt stability) |
| `/usr/local/bin/sustained-turbo` + `/etc/conf.d/sustained-turbo` | daemon holding turbo under sustained load (manual start) |
