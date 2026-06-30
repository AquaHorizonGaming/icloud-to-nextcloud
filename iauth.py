#!/usr/bin/env python3
"""Shared interactive iCloud auth for icloud2nc (icloudpy).

Handles modern 2FA (code pushed to trusted devices) with an **SMS-to-phone
fallback**, the older 2SA device picker, persistent session cookies, and session
trust so 2FA is only needed once (~30 days). No credentials are stored.
"""
import os, sys, json, getpass


def _svc(apple_id, pw):
    try:
        from icloudpy import ICloudPyService as Svc
    except Exception:
        from pyicloud import PyiCloudService as Svc
    cdir = os.environ.get("ICLOUD2NC_COOKIE_DIR") or os.path.expanduser("~/.icloud2nc-cookies")
    try: os.makedirs(cdir, exist_ok=True)
    except Exception: pass
    try:
        return Svc(apple_id, pw, cookie_directory=cdir), cdir
    except TypeError:
        return Svc(apple_id, pw), cdir


def _auth_headers(api):
    h = api._get_auth_headers({"Accept": "application/json"})
    sd = getattr(api, "session_data", {}) or {}
    if sd.get("scnt"): h["scnt"] = sd["scnt"]
    if sd.get("session_id"): h["X-Apple-ID-Session-Id"] = sd["session_id"]
    return h


def _list_phones(api):
    """Best-effort: return [(id, label)] of trusted phone numbers, if Apple exposes them."""
    try:
        r = api.session.get(api.auth_endpoint, headers=_auth_headers(api))
        data = r.json() if hasattr(r, "json") else {}
    except Exception:
        return []
    out = []
    for p in (data.get("trustedPhoneNumbers") or []):
        pid = p.get("id")
        label = p.get("numberWithDialCode") or p.get("numberWithDialCodeAndPushMode") or p.get("number") or ("#%s" % pid)
        if pid is not None:
            out.append((pid, label))
    return out


def _sms_send(api, pid):
    try:
        r = api.session.put(api.auth_endpoint + "/verify/phone",
                            data=json.dumps({"phoneNumber": {"id": pid}, "mode": "sms"}),
                            headers=_auth_headers(api))
        return 200 <= getattr(r, "status_code", 0) < 300
    except Exception as e:
        print(">> SMS request error: %s" % e)
        return False


def _sms_validate(api, pid, code):
    try:
        r = api.session.post(api.auth_endpoint + "/verify/phone/securitycode",
                             data=json.dumps({"phoneNumber": {"id": pid},
                                              "securityCode": {"code": code}, "mode": "sms"}),
                             headers=_auth_headers(api))
        return 200 <= getattr(r, "status_code", 0) < 300
    except Exception as e:
        print(">> SMS code rejected: %s" % e)
        return False


def _trust(api, cdir):
    try:
        if api.trust_session():
            print(">> Session trusted -- 2FA won't be needed again for ~30 days (%s)." % cdir)
        else:
            print(">> Note: could not fully trust the session; 2FA may be asked again.")
    except Exception as e:
        print(">> trust_session note: %s" % e)


def _do_sms(api):
    phones = _list_phones(api)
    if phones:
        print("Trusted phone numbers:")
        for i, (pid, label) in enumerate(phones):
            print("  %d: %s" % (i, label))
        sel = input("Text the code to which number [0]: ").strip() or "0"
        try: pid = phones[int(sel)][0]
        except Exception: pid = phones[0][0]
    else:
        pid_in = input("Phone number id to text (usually 1) [1]: ").strip() or "1"
        try: pid = int(pid_in)
        except ValueError: pid = 1
    if not _sms_send(api, pid):
        print("ERROR: could not send the SMS (try a different id, or use the on-device code)."); sys.exit(2)
    code = input("Enter the SMS code: ").strip()
    if not _sms_validate(api, pid, code):
        print("ERROR: that SMS code was not accepted."); sys.exit(2)


def get_service(apple_id):
    pw = os.environ.get("APPLE_PW") or getpass.getpass("iCloud password for %s: " % apple_id)
    api, cdir = _svc(apple_id, pw)

    if getattr(api, "requires_2fa", False):
        try:
            if hasattr(api, "trigger_2fa_push_notification") and api.trigger_2fa_push_notification():
                print(">> A 6-digit code was sent to your trusted Apple devices.")
        except Exception as e:
            print(">> (push trigger note: %s)" % e)
        print("Enter the code shown on your device, or type 'sms' to have Apple TEXT it to a phone instead.")
        ans = input("2FA code (or 'sms'): ").strip()
        if ans.lower() == "sms":
            _do_sms(api)
        else:
            if not api.validate_2fa_code(ans):
                print("ERROR: that 2FA code was not accepted."); sys.exit(2)
        _trust(api, cdir)

    elif getattr(api, "requires_2sa", False):
        devs = api.trusted_devices
        if not devs:
            print("ERROR: verification required but no trusted devices/phones available."); sys.exit(2)
        print("Where should Apple send the code?")
        for i, d in enumerate(devs):
            print("  %d: %s" % (i, d.get("deviceName") or ("SMS to " + d.get("phoneNumber", "?"))))
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
