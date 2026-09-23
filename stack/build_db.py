#!/usr/bin/env python3
"""Builds data/lab.db (SQLite) from all of the lab's structured data.

Sources stay where they live (CSV, logs, the journal) — the database is always
derived and rebuilt from scratch:  make db   or   python3 stack/build_db.py
stdlib only, no dependencies.
"""
import csv, configparser, hashlib, os, re, sqlite3, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, "data", "lab.db")
VT = os.path.join(ROOT, "victus-tuning")
KR = os.path.join(ROOT, "kernel")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def p(*a):
    return os.path.join(ROOT, *a)


def load_csv(db, table, path, delimiter=","):
    """Creates a table from the CSV header; every column is TEXT with SQLite affinity."""
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f, delimiter=delimiter))
    head = [h.strip() for h in rows[0]]
    cols = ", ".join(f'"{h}"' for h in head)
    db.execute(f'CREATE TABLE "{table}" ({cols})')
    good = [r for r in rows[1:] if len(r) == len(head)]
    db.executemany(f'INSERT INTO "{table}" VALUES ({",".join("?" * len(head))})', good)
    return len(good)


def journal_sessions(db):
    db.execute("CREATE TABLE journal_sessions (session INT, date TEXT, title TEXT, line_start INT, line_end INT)")
    path = os.path.join(VT, "docs", "journal.md")
    lines = open(path, encoding="utf-8").read().splitlines()
    hits = []
    for i, l in enumerate(lines, 1):
        m = re.match(r"## (\d{4}-\d\d-\d\d) — Session (\d+): (.*)", l)
        if m:
            hits.append((int(m.group(2)), m.group(1), m.group(3).strip(), i))
    for k, (n, d, t, s) in enumerate(hits):
        end = hits[k + 1][3] - 1 if k + 1 < len(hits) else len(lines)
        db.execute("INSERT INTO journal_sessions VALUES (?,?,?,?,?)", (n, d, t, s, end))
    return len(hits)


def ycruncher(db):
    """y-cruncher logs: 'Passed' = tests that passed, everything else is a failure marker."""
    db.execute("CREATE TABLE yc_runs (label TEXT, bytes INT, passed INT, failed_markers INT, verdict TEXT)")
    d = os.path.join(VT, "logs")
    n = 0
    for f in sorted(os.listdir(d)):
        if not (f.startswith("yc-") and f.endswith(".log")):
            continue
        txt = ANSI.sub("", open(os.path.join(d, f), errors="replace").read())
        passed = len(re.findall(r"Passed", txt))
        bad = [l for l in txt.splitlines()
               if re.search(r"exception encountered|mismatch|: failed|error\(s\) encountered", l, re.I)
               and not re.search(r"stop on error", l, re.I)]
        verdict = "FAIL" if bad else ("PASS" if passed else "NO_RESULT")
        db.execute("INSERT INTO yc_runs VALUES (?,?,?,?,?)",
                   (f[3:-4], os.path.getsize(os.path.join(d, f)), passed, len(bad), verdict))
        n += 1
    return n


def kernel_build_logs(db):
    db.execute("CREATE TABLE kernel_build_logs (file TEXT, lines INT, bytes INT, outcome TEXT)")
    d = os.path.join(KR, "logs")
    n = 0
    for f in sorted(os.listdir(d)):
        if not f.endswith(".log") or not re.search(r"(build|trim)", f):
            continue
        txt = open(os.path.join(d, f), errors="replace").read()
        if "is ready" in txt:
            out = "bzImage_ready"
        elif re.search(r"\*\*\* .*Error|Stop\.", txt):
            out = "make_error"
        else:
            out = "unknown"
        db.execute("INSERT INTO kernel_build_logs VALUES (?,?,?,?)",
                   (f, txt.count("\n"), len(txt.encode()), out))
        n += 1
    return n


def diag_files(db):
    db.execute("CREATE TABLE diag_files (n INT, bytes INT, first_line TEXT)")
    d = p("diag")
    n = 0
    for f in os.listdir(d):
        m = re.fullmatch(r"diag(\d*)\.txt", f)
        if not m:
            continue
        with open(os.path.join(d, f), errors="replace") as fh:
            first = fh.readline().strip()[:160]
        db.execute("INSERT INTO diag_files VALUES (?,?,?)",
                   (int(m.group(1) or 0), os.path.getsize(os.path.join(d, f)), first))
        n += 1
    return n


def throttled_configs(db):
    """Every version of throttled.conf (backups + live) in key/value form."""
    db.execute("CREATE TABLE throttled_configs (version TEXT, section TEXT, key TEXT, value TEXT)")
    srcs = {f: os.path.join(VT, "backup", f) for f in os.listdir(os.path.join(VT, "backup"))
            if f.startswith("throttled.conf")}
    if os.path.exists("/etc/throttled.conf"):
        srcs["LIVE"] = "/etc/throttled.conf"
    n = 0
    for name, path in sorted(srcs.items()):
        cp = configparser.ConfigParser(delimiters=(":",), interpolation=None, strict=False)
        cp.optionxform = str
        try:
            cp.read(path, encoding="utf-8")
        except configparser.Error:
            continue
        for sec in cp.sections():
            for k, v in cp[sec].items():
                db.execute("INSERT INTO throttled_configs VALUES (?,?,?,?)", (name, sec, k, v.strip()))
                n += 1
    return n


GROUPS = [  # (path prefix, group)
    ("victus-tuning/docs", "victus/docs"), ("victus-tuning/scripts", "victus/scripts"),
    ("victus-tuning/data", "victus/data"), ("victus-tuning/logs", "victus/logs"),
    ("victus-tuning/backup", "victus/backup"), ("victus-tuning/usb-payload", "victus/bios-payload"),
    ("victus-tuning", "victus/other"), ("kernel/logs", "kernel/logs"),
    ("kernel/config", "kernel/config"), ("kernel/scripts", "kernel/scripts"),
    ("kernel/grub", "kernel/grub"), ("kernel/autofdo-work", "kernel/autofdo"),
    ("diag", "diag"), ("flashing", "flashing"),
    ("tools", "tools"), ("misc", "misc"), ("stack", "stack"),
]


def inventory(db):
    db.execute("CREATE TABLE files (path TEXT PRIMARY KEY, grp TEXT, bytes INT, sha256 TEXT)")
    n = 0
    for dirpath, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for f in names:
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, ROOT)
            if os.path.islink(full) or rel.startswith("data/lab.db"):
                continue
            grp = next((g for pre, g in GROUPS if rel.startswith(pre + "/") or rel == pre), "root")
            size = os.path.getsize(full)
            sha = ""
            if size < 8 * 1024 * 1024:  # don't hash large binaries
                sha = hashlib.sha256(open(full, "rb").read()).hexdigest()
            db.execute("INSERT INTO files VALUES (?,?,?,?)", (rel, grp, size, sha))
            n += 1
    return n


def main():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    if os.path.exists(DB):
        os.remove(DB)
    db = sqlite3.connect(DB)
    stats = {}
    for t in ("uv_asym", "uv_cache", "uv_boost", "uv_campaign", "uv_percore", "uv_plbound", "profile_sweep"):
        stats[t] = load_csv(db, t, os.path.join(VT, "data", t.replace("_", "-") + ".csv"))
    stats["journal_sessions"] = journal_sessions(db)
    stats["yc_runs"] = ycruncher(db)
    stats["kernel_build_logs"] = kernel_build_logs(db)
    stats["diag_files"] = diag_files(db)
    stats["throttled_configs"] = throttled_configs(db)
    stats["files"] = inventory(db)
    db.commit()
    db.close()
    w = max(map(len, stats))
    for k, v in stats.items():
        print(f"  {k:<{w}}  {v:>5} rows")
    print(f"OK -> {os.path.relpath(DB, ROOT)}")


if __name__ == "__main__":
    sys.exit(main())
