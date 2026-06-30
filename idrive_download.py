#!/usr/bin/env python3
"""Download an entire iCloud Drive into a local folder -- parallel + streaming.

Auth via shared iauth (2FA/SMS, persistent trust). Downloads start as folders
are scanned (no long silent pre-scan), so you see progress immediately.
Incremental (skips files already present at the same size) + resumable.
"""
import argparse, os, sys, shutil, concurrent.futures, threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iauth import get_service  # noqa

_plock = threading.Lock()
def say(m):
    with _plock:
        print(m, flush=True)

def fetch(item, out):
    resp = item.open(stream=True)
    raw = getattr(resp, "raw", None)
    tmp = out + ".part"
    with open(tmp, "wb") as fh:
        if raw is not None:
            shutil.copyfileobj(raw, fh)
        else:
            for chunk in resp.iter_content(262144):
                if chunk:
                    fh.write(chunk)
    os.replace(tmp, out)

def download_one(item, out):
    try:
        fetch(item, out)
        dm = getattr(item, "date_modified", None)
        if dm:
            try:
                ts = dm.timestamp(); os.utime(out, (ts, ts))
            except Exception:
                pass
        return ("ok", os.path.getsize(out), None)
    except Exception as e:
        return ("err", 0, str(e))

def walk_stream(node, dest, rel, st, submit):
    say(">> scanning /%s" % (rel or ""))
    try:
        names = node.dir()
    except Exception as e:
        say("WARN cannot list /%s: %s" % (rel, e)); return
    for name in names or []:
        try:
            item = node[name]
        except Exception as e:
            say("WARN skip %s/%s: %s" % (rel, name, e)); continue
        t = getattr(item, "type", None)
        relpath = (rel + "/" + name).lstrip("/")
        if t in ("folder", "app_library"):
            walk_stream(item, dest, relpath, st, submit)
        else:
            out = os.path.join(dest, relpath)
            os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
            size = getattr(item, "size", None) or 0
            if os.path.exists(out) and size and os.path.getsize(out) == size:
                st["skip"] += 1; continue
            submit(item, out, relpath)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apple-id", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--workers", type=int, default=int(os.environ.get("IDRIVE_WORKERS", "8")))
    a = ap.parse_args()
    workers = max(1, min(a.workers, 32))
    api = get_service(a.apple_id)
    try:
        drive = api.drive
    except Exception as e:
        print("ERROR: no accessible iCloud Drive for this account: %s" % e); sys.exit(3)
    st = {"got": 0, "skip": 0, "fail": 0, "bytes": 0}
    print("Walking iCloud Drive with %d workers (downloads start as folders are scanned)..." % workers, flush=True)
    ex = concurrent.futures.ThreadPoolExecutor(max_workers=workers)
    futs = []
    def submit(item, out, rel):
        futs.append((ex.submit(download_one, item, out), rel))
    walk_stream(drive, a.dest, "", st, submit)
    say(">> scan done: %d files to download, %d already present. Finishing..." % (len(futs), st["skip"]))
    done = 0
    for f, rel in futs:
        status, b, err = f.result(); done += 1
        if status == "ok":
            st["got"] += 1; st["bytes"] += b; say("[%d/%d] OK   %s" % (done, len(futs), rel))
        else:
            st["fail"] += 1; say("[%d/%d] FAIL %s: %s" % (done, len(futs), rel, err))
    ex.shutdown()
    print("DONE downloaded=%d skipped=%d failed=%d bytes=%d" % (st["got"], st["skip"], st["fail"], st["bytes"]))

if __name__ == "__main__":
    main()
