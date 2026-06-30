#!/usr/bin/env python3
"""Download an entire iCloud Drive into a local folder (incremental).

Auth is interactive (Apple password + 2FA). Nothing is stored by this script
beyond icloudpy's own session cookie. Re-run any time -- files already present
at the same size are skipped. Used by icloud2nc 'drive-pull'.
"""
import argparse, os, sys, getpass, shutil

def get_service(apple_id):
    try:
        from icloudpy import ICloudPyService as Svc
    except Exception:
        from pyicloud import PyiCloudService as Svc
    pw = os.environ.get("APPLE_PW") or getpass.getpass("iCloud password for %s: " % apple_id)
    api = Svc(apple_id, pw)

    # Modern two-factor (2FA): Apple pushes a 6-digit code to trusted devices.
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

    # Older two-step (2SA): pick a device (incl. SMS phone numbers) to send a code.
    elif getattr(api, "requires_2sa", False):
        devs = api.trusted_devices
        if not devs:
            print("ERROR: account needs verification but no trusted devices/phones are available."); sys.exit(2)
        print("Where should Apple send the verification code?")
        for i, d in enumerate(devs):
            label = d.get("deviceName") or ("SMS to " + d.get("phoneNumber", "?")) or str(d)
            print("  %d: %s" % (i, label))
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

def walk(node, dest, rel, st):
    try:
        names = node.dir()
    except Exception as e:
        print("WARN cannot list /%s: %s" % (rel, e)); return
    for name in names or []:
        try:
            item = node[name]
        except Exception as e:
            print("WARN skip %s/%s: %s" % (rel, name, e)); continue
        t = getattr(item, "type", None)
        relpath = (rel + "/" + name).lstrip("/")
        if t in ("folder", "app_library"):
            walk(item, dest, relpath, st)
        else:
            out = os.path.join(dest, relpath)
            os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
            size = getattr(item, "size", None) or 0
            if os.path.exists(out) and size and os.path.getsize(out) == size:
                st["skip"] += 1; continue
            try:
                fetch(item, out)
                dm = getattr(item, "date_modified", None)
                if dm:
                    try: ts = dm.timestamp(); os.utime(out, (ts, ts))
                    except Exception: pass
                st["got"] += 1; st["bytes"] += os.path.getsize(out)
                print("OK  %s" % relpath)
            except Exception as e:
                print("WARN download failed %s: %s" % (relpath, e))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apple-id", required=True)
    ap.add_argument("--dest", required=True)
    a = ap.parse_args()
    api = get_service(a.apple_id)
    try:
        drive = api.drive
    except Exception as e:
        print("ERROR: no accessible iCloud Drive for this account: %s" % e); sys.exit(3)
    st = {"got": 0, "skip": 0, "bytes": 0}
    print("Downloading iCloud Drive -> %s" % a.dest)
    walk(drive, a.dest, "", st)
    print("DONE downloaded=%d skipped=%d bytes=%d" % (st["got"], st["skip"], st["bytes"]))

if __name__ == "__main__":
    main()
