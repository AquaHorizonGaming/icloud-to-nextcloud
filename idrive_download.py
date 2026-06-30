#!/usr/bin/env python3
"""Download an entire iCloud Drive into a local folder, in PARALLEL (incremental).

Auth is interactive (Apple password + 2FA). Nothing is stored beyond icloudpy's
own session cookie. Re-run any time -- files already present at the same size are
skipped. Used by icloud2nc 'drive-pull'.
"""
import argparse, os, sys, getpass, shutil, threading, concurrent.futures

_plock = threading.Lock()
def say(msg):
    with _plock: print(msg, flush=True)

def get_service(apple_id):
    try:
        from icloudpy import ICloudPyService as Svc
    except Exception:
        from pyicloud import PyiCloudService as Svc
    pw = os.environ.get("APPLE_PW") or getpass.getpass("iCloud password for %s: " % apple_id)
    api = Svc(apple_id, pw)
    if getattr(api, "requires_2fa", False):
        try:
            if hasattr(api, "trigger_2fa_push_notification"):
                api.trigger_2fa_push_notification()
                print(">> A 6-digit code was just sent to your trusted Apple devices (iPhone/iPad/Mac).")
            else:
                print(">> Check your trusted Apple devices for a 6-digit code.")
        except Exception as e:
            print(">> Could not trigger the push (%s). Check your devices for a code anyway." % e)
        code = input("Enter the 2FA code: ").strip()
        if not api.validate_2fa_code(code):
            print("ERROR: that 2FA code was not accepted."); sys.exit(2)
        if not getattr(api, "is_trusted_session", True):
            try: api.trust_session()
            except Exception: pass
    elif getattr(api, "requires_2sa", False):
        devs = api.trusted_devices
        if not devs:
            print("ERROR: needs verification but no trusted devices/phones available."); sys.exit(2)
        print("Where should Apple send the verification code?")
        for i, d in enumerate(devs):
            print("  %d: %s" % (i, d.get("deviceName") or ("SMS to " + d.get("phoneNumber", "?")) or str(d)))
        sel = input("Choose [0]: ").strip() or "0"
        try: dev = devs[int(sel)]
        except Exception: dev = devs[0]
        if not api.send_verification_code(dev):
            print("ERROR: could not send a verification code."); sys.exit(2)
        code = input("Enter the verification code: ").strip()
        if not api.validate_verification_code(dev, code):
            print("ERROR: that code was not accepted."); sys.exit(2)
    else:
        print(">> Session already trusted; no 2FA needed.")
    return api

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
