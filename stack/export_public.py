#!/usr/bin/env python3
"""Builds a public copy of the lab from an allow-list and sanitizes it.

  python3 stack/export_public.py /path/to/system-lab-public

Nothing not in ALLOW reaches the public copy. After copying, it scans
for THIS machine's identifiers (serials, UUIDs, MACs, machine-id,
hostname, partition PARTUUIDs/UUIDs) and typical secrets. Anything found -> exit 1.
"""
import fnmatch, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALLOW = [
    "README.md", "Makefile", "LICENSE", "LICENSE-docs",
    "stack/build_db.py", "stack/queries.sql", "stack/export_public.py",
    "victus-tuning/docs/*", "victus-tuning/scripts/*", "victus-tuning/data/*",
    "victus-tuning/logs/*",
    "victus-tuning/bios/*",
    "victus-tuning/backup/throttled.conf.*",  # minus EXCLUDE below
    "victus-tuning/backup/20260724-162905/manifest.txt",
    "victus-tuning/backup/20260724-162905/msr-snapshot.txt",
    "victus-tuning/usb-payload/README-flash.md", "victus-tuning/usb-payload/sha256.txt",
    "kernel/LICENSE", "kernel/config/*", "kernel/scripts/*", "kernel/grub/*",
    "kernel/logs/trim10-build.log", "kernel/logs/trim11-build.log",
    "kernel/logs/kernel-7.1.8-build*.log", "kernel/logs/kernel-autofdo-build.log",
    "kernel/logs/perf-record*.log", "kernel/logs/combo-list.txt",
    "kernel/logs/compile-workload.log",
]
EXCLUDE = ["victus-tuning/backup/throttled.conf.last-stable-160"]  # -160 is unstable; not published as "stable"
TEXT_EXT = (".md", ".txt", ".sh", ".py", ".sql", ".csv", ".tsv", ".log", ".conf", ".status", ".sha256", "")


def is_text(path):
    try:
        b = open(path, "rb").read(4096)
    except OSError:
        return False
    return b"\0" not in b


def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.stdout.strip()


def machine_ids():
    """Exact values that must never appear in the public copy."""
    ids = {}
    for name in ("product_serial", "board_serial", "chassis_serial", "product_uuid"):
        v = sh(f"cat /sys/class/dmi/id/{name} 2>/dev/null")
        if len(v) >= 6 and "To be filled" not in v:
            ids[name] = v
    ids["machine-id"] = sh("cat /etc/machine-id 2>/dev/null")
    for i, m in enumerate(sh("ip -o link | awk '{print $17}'").split()):
        if re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", m) and set(m.replace(":", "")) != {"0"}:
            ids[f"mac{i}"] = m
    for i, u in enumerate(sh("blkid -s UUID -s PARTUUID -o value").split()):
        ids[f"blk{i}"] = u
    em = sh("git -C %s config user.email 2>/dev/null" % ROOT)
    if em and "noreply" not in em:
        ids["email"] = em
    return {k: v for k, v in ids.items() if v}


def sanitize(text, rel, ids):
    # paths
    text = text.replace("root@gentoo", "builder@host")
    text = text.replace("/home/tarilka0gg/Documents/system-lab", "~/system-lab")
    text = text.replace("/home/tarilka0gg", "~" if not rel.endswith((".sh", ".py")) else "$HOME")
    # partition identifiers in logs/configs (already gone from the scripts)
    for k, v in ids.items():
        if k.startswith("blk"):
            text = text.replace(v, "<UUID>")
    return text


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = os.path.abspath(sys.argv[1])
    if os.path.exists(out) and os.listdir(out):
        sys.exit(f"{out} is not empty — remove it by hand")
    ids = machine_ids()
    files = []
    for dp, dn, fn in os.walk(ROOT):
        dn[:] = [d for d in dn if d not in (".git", "__pycache__")]
        for f in fn:
            full = os.path.join(dp, f)
            rel = os.path.relpath(full, ROOT)
            if os.path.islink(full):
                continue
            if any(fnmatch.fnmatch(rel, pat) for pat in ALLOW) and rel not in EXCLUDE:
                files.append(rel)
    for rel in sorted(files):
        src, dst = os.path.join(ROOT, rel), os.path.join(out, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if is_text(src):
            t = open(src, encoding="utf-8", errors="replace").read()
            open(dst, "w", encoding="utf-8").write(sanitize(t, rel, ids))
            shutil.copymode(src, dst)
        else:
            shutil.copy2(src, dst)
    # allow-list .gitignore: everything denied by default, allowed files named explicitly
    dirs = sorted({os.path.dirname(f) for f in files if os.path.dirname(f)})
    lines = ["# allow-list: EVERYTHING is ignored by default", "*", "!*/", "!.gitignore"]
    for f in sorted(files):
        lines.append("!/" + f)
    open(os.path.join(out, ".gitignore"), "w").write("\n".join(lines) + "\n")
    # scan
    bad = []
    for rel in files + [".gitignore"]:
        p = os.path.join(out, rel)
        if not is_text(p):
            continue
        t = open(p, encoding="utf-8", errors="replace").read()
        for k, v in ids.items():
            if v in t:
                bad.append((rel, k))
        for pat, name in ((r"(?!(?:00:){5}00)([0-9a-f]{2}:){5}[0-9a-f]{2}", "MAC"),
                          (r"(?<![\w+])(?!\d+\+[\w-]+@users\.noreply)[\w.+-]+@(?!users\.noreply)[\w-]+\.[\w.]+", "email"),
                          (r"(?i)(api[_-]?key|secret[_-]?key|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,})", "secret")):
            m = re.search(pat, t)
            if m:
                bad.append((rel, f"{name}: {m.group(0)[:30]}"))
    print(f"copied {len(files)} files to {out}")
    if bad:
        print("SCAN: found sensitive data:")
        for b in bad:
            print("  ", *b)
        sys.exit(1)
    print("SCAN: clean")


if __name__ == "__main__":
    main()
