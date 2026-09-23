# kernel/: the AutoFDO profile for the 7.1.8 kernel, and how to reproduce it

Written 2026-09-19 before deleting `autofdo-work/kernel-compilation.data` (62 GB). The commands were reconstructed from the Sep 12, 2026 session history (they weren't in the build scripts: everything was run by hand).

## Artifacts

| File | Size | SHA-256 | Where it lives |
|---|---|---|---|
| `kernel-compilation.afdo` | 2,921,700 B | `ea88466bfee2e953a344c83c51f536464743bb0027a0645740083d738c2a52ee` | `kernel/autofdo-work/`, `kernel/backup/` (in `.gitignore`), `/usr/src/linux-7.1.8-cachyos1/tools/perf/` (source tree, Portage can overwrite it) |
| `kernel-compilation.data` | 65,295,473,436 B (62,270.6 MiB) | not computed | `kernel/autofdo-work/` (scheduled for deletion) |

## 1. Collecting perf data (workload: building the kernel)

A system-wide recording with branch stack, running alongside the usual compile. Stopped with SIGINT:

```bash
mkdir -p /usr/src/linux/tools/perf
nohup perf record -b -e cycles:kp -a -N -c 500009 \
      -o /usr/src/linux/tools/perf/kernel-compilation.data \
      > ~/perf-record3.log 2>&1 &
# ...once the workload finished:
kill -INT <PID perf>
```

- `perf` 7.1.6 (per `perf version` in the file header), 24 CPUs.
- There were three attempts. The **third** was used, 62,270.6 MiB (`kernel/logs/perf-record3.log`). The first (`perf record -a -g -e cycles`, 19 GB) had no branch stack. The second (26 GB), with the same command line as the third, went unused; the reason for the switch isn't established from the logs.
- The file was then moved to `~/autofdo-work/` (for conversion) and `chown root:root`'d.

## 2. Converting the perf data into `.afdo`

```bash
env TMPDIR=/home/tarilka0gg/autofdo-work \
  /usr/lib/llvm/22/bin/llvm-profgen --kernel \
      --perfdata=/home/tarilka0gg/autofdo-work/kernel-compilation.data \
      --binary=/usr/src/linux/vmlinux \
      -o /home/tarilka0gg/autofdo-work/kernel-compilation.afdo
```

- Tool: `llvm-profgen` from LLVM 22 (`/usr/lib/llvm/22/bin/`). `create_llvm_prof` wasn't used.
- `TMPDIR` was moved to `/home` because the conversion's temp files are large; going by the history, `/` was running short on space.
- The conversion took about 3.4 h (started around 21:22, `.afdo` written at 00:48).
- Afterward: `cp ~/autofdo-work/kernel-compilation.afdo /usr/src/linux/tools/perf/`.

## 3. How `.afdo` is fed into the build

The variable is called **`CLANG_AUTOFDO_PROFILE`** (not `AUTOFDO_PROFILE`; `AUTOFDO_PROFILE_foo.o := y` are separate per-object Makefile switches, see `Documentation/dev-tools/autofdo.rst`). The build command that produced kernel `7.1.8-cachyos1-tuned #4`:

```bash
cd /usr/src/linux
taskset -c 15-23 env PATH="/usr/lib/llvm/22/bin:$PATH" \
  make CC=clang LLVM=1 LLVM_IAS=1 LD=ld.bfd HOSTLD=ld.bfd \
       CLANG_AUTOFDO_PROFILE=/usr/src/linux/tools/perf/kernel-compilation.afdo \
       -j9 KCFLAGS+="-pipe" all
```

`.config` needs `CONFIG_AUTOFDO_CLANG=y` and `CONFIG_PROPELLER_CLANG=y` (both true in the live kernel). Log: `kernel/logs/kernel-autofdo-build.log`. Limine records the entry as: "autofdo+profile applied, propeller baseline".

## 4. Does `vmlinux` have the same build-id as the perf data? No, and it can't be checked

- The header of `kernel-compilation.data` **has no BUILD_ID section** (`perf report --header-only`: `missing features: … BUILD_ID …`; likely because the recording ended via signal rather than normally), so the build-ids can't be compared directly.
- The only `vmlinux` on disk: `/usr/src/linux-7.1.8-cachyos1/vmlinux` (and `vmlinux.unstripped`), build **#4** from 09-13 01:07, build-id **`5d4b9a578ffa0275be64d8badac04132ed6f151e`**. This is the same kernel running now (`/sys/kernel/notes` gives the same id).
- The timeline shows a **different** kernel was profiled: the perf data was recorded 09-12 around 21:12, `.afdo` was ready 09-13 00:48, and `vmlinux` #4 was built only **after** that (01:07). The profile was taken from the previous build (#3, in `/boot/vmlinuz-7.1.8-cachyos1-tuned.old` from 09-12 14:40), whose `vmlinux` was overwritten by build #4.
- Conclusion: the profile can no longer be re-derived from `.data` against the current `vmlinux`; that would need build #3's `vmlinux` with the matching build-id, which wasn't kept. `.data`'s value is archival only.

## How to redo this from scratch

1. Boot the kernel you need a profile for, and keep its `vmlinux` (unstripped, alongside its build-id: `readelf -n vmlinux | grep 'Build ID'`).
2. Collect perf data per section 1 under a realistic workload (the first attempt, 19 GB without `-b`, is unusable).
3. Convert per section 2 with `--binary=` pointing at the **same** `vmlinux`.
4. Build the new kernel per section 3.
