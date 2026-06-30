#!/usr/bin/env python3
"""Download an entire iCloud Drive into a local folder, in PARALLEL (incremental).

Auth is interactive (Apple password + 2FA). Nothing is stored beyond icloudpy's
own session cookie. Re-run any time -- files already present at the same size are
skipped. Used by icloud2nc 'drive-pull'.
"""
import argparse, os, sys, getpass, shutil, threading, concurrent.futures
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iauth import get_service  # shared auth (2FA + SMS fallback)

_plock = threading.Lock()
def say(msg):
    with _plock: print(msg, flush=True)

def fetch(item, out):
    resp = item.open(stream=True)
    raw = getattr(resp, "raw", None)
    tmp = out + ".part"
    with open(tmp, "wb") as fh:
        if raw is not None:
            shutil.copyfileobj(raw, fh)
        else:
            for chunk in resp.iter_content(262144):
                if chunk: fh.write(chunk)
    os.replace(tmp, out)

def download_one(item, out):
    try:
        fetch(item, out)
        dm = getattr(item, "date_modified", None)
        if dm:
            try: ts = dm.timestamp(); os.utime(out, (ts, ts))
            except Exception: pass
        return ("ok", os.path.getsize(out), None)
    except Exception as e:
        return ("err", 0, str(e))

def collect(node, dest, rel, files):
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
            collect(item, dest, relpath, files)
        else:
            files.append((item, os.path.join(dest, relpath), getattr(item, "size", None) or 0, relpath))

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

    print("Scanning iCloud Drive (building file list)...")
    files = []
    collect(drive, a.dest, "", files)

    todo = []; skip = 0
    for item, out, size, relpath in files:
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        if os.path.exists(out) and size and os.path.getsize(out) == size:
            skip += 1; continue
        todo.append((item, out, relpath))
    total = len(todo)
    print("Files: %d total | %d to download | %d already present | %d parallel workers"
          % (len(files), total, skip, workers))

    got = failed = done = 0; nbytes = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(download_one, item, out): relpath for item, out, relpath in todo}
        for fut in concurrent.futures.as_completed(futs):
            relpath = futs[fut]; done += 1
            status, b, err = fut.result()
            if status == "ok":
                got += 1; nbytes += b
                say("[%d/%d] OK   %s" % (done, total, relpath))
            else:
                failed += 1
                say("[%d/%d] FAIL %s: %s" % (done, total, relpath, err))
    print("DONE downloaded=%d failed=%d skipped=%d bytes=%d" % (got, failed, skip, nbytes))
    if failed: print("Some files failed -- safe to re-run; it resumes and skips finished ones.")

if __name__ == "__main__":
    main()
