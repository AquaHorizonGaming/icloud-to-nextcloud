#!/usr/bin/env python3
"""
Ongoing date fixer for NEW dateless files (screenshots, downloads, saved clips).

Runs from cron. For files that arrived since the last run and have no usable
EXIF date, it pulls a date from the FILENAME (e.g. Screenshot_2024-01-15,
ScreenRecording_05-20-2018, PXL_20240115, IMG_20240115) and sets the file's
modification time so Memories places it correctly. New iPhone photos already
carry EXIF, so they're skipped.

Env: ICLOUD_DIR (folder to watch), EXIFTOOL (path to exiftool)
"""
import os, re, subprocess
from datetime import datetime as D

ICLOUD = os.environ["ICLOUD_DIR"]
ET     = os.environ.get("EXIFTOOL", "exiftool")
MARKER = os.path.join(os.path.dirname(ICLOUD.rstrip("/")), ".autodate_marker")
EXT = {".heic", ".jpg", ".jpeg", ".png", ".gif", ".dng", ".tiff", ".tif",
       ".mov", ".mp4", ".m4v"}

# filename date patterns -> (regex, order)
PATTERNS = [
    (re.compile(r"(20\d\d)[-_]?(\d\d)[-_]?(\d\d)"), "ymd"),   # 2024-01-15 / 20240115
    (re.compile(r"(\d\d)[-_](\d\d)[-_](20\d\d)"),  "mdy"),   # 01-15-2024 / 05-20-2018
]

def date_from_name(name):
    for rx, order in PATTERNS:
        m = rx.search(name)
        if not m:
            continue
        try:
            if order == "ymd":
                y, mo, da = map(int, m.groups())
            else:
                mo, da, y = map(int, m.groups())
            if 1 <= mo <= 12 and 1 <= da <= 31:
                return D(y, mo, da, 12, 0, 0)
        except ValueError:
            pass
    return None

# first run: set marker, process nothing (existing library already handled)
if not os.path.exists(MARKER):
    open(MARKER, "w").close()
    print("init marker; first run processes nothing")
    raise SystemExit

last = os.path.getmtime(MARKER)
checked = corrected = 0
for f in os.listdir(ICLOUD):
    if os.path.splitext(f)[1].lower() not in EXT:
        continue
    p = os.path.join(ICLOUD, f)
    try:
        if os.stat(p).st_ctime <= last:   # only files that arrived since last run
            continue
    except OSError:
        continue
    checked += 1
    r = subprocess.run([ET, "-s3", "-DateTimeOriginal", "-CreateDate", p],
                       capture_output=True, text=True)
    out = r.stdout.strip()
    if out and "0000" not in out:         # already has a real date
        continue
    dt = date_from_name(f)
    if dt:
        ts = dt.timestamp()
        os.utime(p, (ts, ts))
        corrected += 1

os.utime(MARKER, None)
print(f"new files checked={checked} date-corrected={corrected}")
