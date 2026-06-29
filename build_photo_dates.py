#!/usr/bin/env python3
"""
Build an exiftool -csv= batch file that restores DateTimeOriginal/CreateDate
on PHOTOS from Apple's "Photo Details*.csv" metadata.

Apple strips EXIF from exported photos but the per-part CSVs carry
`originalCreationDate`. Doing this as a single exiftool batch (one process,
one CSV) is dramatically faster than per-file exiftool calls.

Env (exported by import_media.sh): ICLOUD_DIR, METADATA_DIR, OUT_CSV
"""
import csv, os, glob, sys
from datetime import datetime as D

ICLOUD = os.environ["ICLOUD_DIR"]
META   = os.environ["METADATA_DIR"]            # contains part*/Photo Details*.csv
OUT    = os.environ.get("OUT_CSV", os.path.join(META, "..", "photo_exif.csv"))

PHOTO_EXT = {".heic", ".jpg", ".jpeg", ".png", ".dng", ".gif", ".tiff", ".tif"}

# Apple format e.g.  "Thursday June 4,2026 5:43 AM GMT"
DATE_FORMATS = ("%A %B %d,%Y %I:%M %p %Z", "%A %B %d,%Y %I:%M %p")

def parse(s):
    s = (s or "").strip().strip('"')
    for f in DATE_FORMATS:
        try:
            return D.strptime(s, f).strftime("%Y:%m:%d %H:%M:%S")
        except ValueError:
            pass
    return None

# name -> exif date string
m = {}
for c in glob.glob(os.path.join(META, "part*", "Photo Details*.csv")):
    with open(c, newline="") as fh:
        for row in csv.DictReader(fh):
            n = (row.get("imgName") or "").strip().strip('"')
            d = row.get("originalCreationDate")
            if n and d and n not in m:
                v = parse(d)
                if v:
                    m[n] = v

rows = 0
with open(OUT, "w", newline="") as o:
    w = csv.writer(o)
    w.writerow(["SourceFile", "DateTimeOriginal", "CreateDate"])
    for f in os.listdir(ICLOUD):
        if os.path.splitext(f)[1].lower() in PHOTO_EXT and f in m:
            w.writerow([os.path.join(ICLOUD, f), m[f], m[f]])
            rows += 1

print(f"photo dates mapped={len(m)} batch_rows={rows} -> {OUT}")
# Apply with:
#   exiftool -q -m -overwrite_original -csv=OUT  ICLOUD_DIR
