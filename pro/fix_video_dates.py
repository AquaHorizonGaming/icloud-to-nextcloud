#!/usr/bin/env python3
"""
Fast video-date repair.

Many videos export with a junk 0000:00:00 CreateDate, so Memories shows them
at "today". Rewriting QuickTime tags with exiftool is far too slow on
networked storage (it rewrites the whole file -> days for thousands of clips).

Instead we set the file's MODIFICATION TIME to the real date from the metadata
CSVs. Memories uses file mtime as its date fallback when there's no usable EXIF
date. This is instant. Then files:scan + memories:index picks it up.

Env (exported by import_media.sh): ICLOUD_DIR, METADATA_DIR
"""
import csv, os, glob
from datetime import datetime as D

ICLOUD = os.environ["ICLOUD_DIR"]
META   = os.environ["METADATA_DIR"]
VIDEO_EXT = {".mov", ".mp4", ".m4v"}
DATE_FORMATS = ("%A %B %d,%Y %I:%M %p %Z", "%A %B %d,%Y %I:%M %p")

def parse(s):
    s = (s or "").strip().strip('"')
    for f in DATE_FORMATS:
        try:
            return D.strptime(s, f)
        except ValueError:
            pass
    return None

m = {}
for c in glob.glob(os.path.join(META, "part*", "Photo Details*.csv")):
    with open(c, newline="") as fh:
        for row in csv.DictReader(fh):
            n = (row.get("imgName") or "").strip().strip('"')
            d = row.get("originalCreationDate")
            if n and d and n not in m:
                dt = parse(d)
                if dt:
                    m[n] = dt

n = 0
for f in os.listdir(ICLOUD):
    if os.path.splitext(f)[1].lower() in VIDEO_EXT and f in m:
        ts = m[f].timestamp()
        try:
            os.utime(os.path.join(ICLOUD, f), (ts, ts))
            n += 1
        except OSError:
            pass

print(f"video timestamps set: {n}")
