#!/usr/bin/env python3
"""Build album-membership CSVs from a LIVE iCloud Photos account (icloudpy),
in the same one-filename-per-line format the privacy.apple.com export uses, so
icloud2nc's 'albums' step can rebuild Memories albums + folder views + favorites
WITHOUT a download. Interactive Apple auth (password + 2FA); nothing stored.
"""
import argparse, os, sys, getpass
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iauth import get_service  # shared auth (2FA + SMS fallback)

# Smart/system albums we don't want to recreate as albums (All Photos == timeline).
SKIP = {"all photos", "all videos", "time-lapse", "videos", "slo-mo", "bursts", "live",
        "panoramas", "screenshots", "selfies", "live photos", "portrait",
        "long exposure", "animated", "recently added",
        "recently deleted", "imports", "shared", "my photo stream"}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apple-id", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    api = get_service(a.apple_id)
    os.makedirs(a.out, exist_ok=True)
    try:
        albums = api.photos.albums
        names = list(albums.keys())
    except Exception as e:
        print("ERROR: cannot read photo albums: %s" % e); sys.exit(3)
    print("Found %d albums; writing membership CSVs to %s" % (len(names), a.out))
    written = 0
    for name in names:
        if (name or "").strip().lower() in SKIP:
            continue
        safe = (name or "").replace("/", "_").strip()
        if not safe:
            continue
        try:
            files = []
            for p in albums[name]:
                fn = getattr(p, "filename", None)
                if fn: files.append(fn)
        except Exception as e:
            print("WARN album '%s': %s" % (name, e)); continue
        if not files:
            continue
        low = name.strip().lower()
        out_name = "Favorites" if low == "favorites" else ("Hidden" if low == "hidden" else safe)
        with open(os.path.join(a.out, out_name + ".csv"), "w", encoding="utf-8") as fh:
            fh.write("imgName\n")
            for fn in files:
                fh.write(fn + "\n")
        written += 1
        print("  %-30s %d photos" % (name, len(files)))
    print("DONE wrote %d album CSV(s). Now run the 'albums' step to apply them." % written)

if __name__ == "__main__":
    main()
