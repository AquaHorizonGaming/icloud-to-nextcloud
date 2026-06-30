#!/usr/bin/env python3
"""Export iCloud Contacts (vCard) or Calendar (iCal) live via icloudpy.

Shares iauth for interactive Apple login (2FA/SMS, persistent trust). Writes a
.vcf / .ics you import into Nextcloud Contacts/Calendar (Settings -> Import).
No credentials stored. Used by icloud2nc 'contacts-pull' / 'calendars-pull'.
"""
import argparse, os, sys, datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iauth import get_service  # noqa


def esc(s):
    if s is None:
        return ""
    return str(s).replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\r", "").replace("\n", "\\n")


def vcards(contacts):
    out = []
    for c in contacts or []:
        first = c.get("firstName", ""); last = c.get("lastName", ""); middle = c.get("middleName", "")
        prefix = c.get("prefix", ""); suffix = c.get("suffix", "")
        company = c.get("companyName", "")
        fn = " ".join(x for x in [first, middle, last] if x).strip() or company or c.get("nickName", "") or "No Name"
        L = ["BEGIN:VCARD", "VERSION:3.0",
             "N:%s;%s;%s;%s;%s" % (esc(last), esc(first), esc(middle), esc(prefix), esc(suffix)),
             "FN:%s" % esc(fn)]
        if company:
            L.append("ORG:%s;%s" % (esc(company), esc(c.get("department", ""))))
        if c.get("jobTitle"):
            L.append("TITLE:%s" % esc(c["jobTitle"]))
        if c.get("nickName"):
            L.append("NICKNAME:%s" % esc(c["nickName"]))
        for p in c.get("phones", []) or []:
            L.append("TEL;TYPE=%s:%s" % (esc((p.get("label") or "VOICE").upper()), esc(p.get("field", ""))))
        for e in c.get("emailAddresses", []) or []:
            L.append("EMAIL;TYPE=%s:%s" % (esc((e.get("label") or "INTERNET").upper()), esc(e.get("field", ""))))
        for a in c.get("streetAddresses", []) or []:
            f = a.get("field", {}) or {}
            L.append("ADR;TYPE=%s:;;%s;%s;%s;%s;%s" % (esc((a.get("label") or "HOME").upper()),
                     esc(f.get("street", "")), esc(f.get("city", "")), esc(f.get("state", "")),
                     esc(f.get("postalCode", "")), esc(f.get("country", ""))))
        for u in c.get("urls", []) or []:
            L.append("URL:%s" % esc(u.get("field", "")))
        if c.get("birthday"):
            L.append("BDAY:%s" % esc(c["birthday"]))
        if c.get("notes"):
            L.append("NOTE:%s" % esc(c["notes"]))
        L.append("END:VCARD")
        out.append("\r\n".join(L))
    return "\r\n".join(out) + "\r\n"


def _dt(arr, all_day):
    try:
        y, mo, d = arr[1], arr[2], arr[3]
        h = arr[4] if len(arr) > 4 else 0
        mi = arr[5] if len(arr) > 5 else 0
    except Exception:
        return None
    if all_day:
        return ("%04d%02d%02d" % (y, mo, d), True)
    return ("%04d%02d%02dT%02d%02d00" % (y, mo, d, h, mi), False)


def ics(events):
    stamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    out = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//icloud2nc//iCloud export//EN", "CALSCALE:GREGORIAN"]
    for ev in events or []:
        guid = ev.get("guid") or stamp
        allday = bool(ev.get("allDay"))
        st = _dt(ev.get("startDate") or [], allday)
        en = _dt(ev.get("endDate") or [], allday)
        out.append("BEGIN:VEVENT")
        out.append("UID:%s" % guid)
        out.append("DTSTAMP:%s" % stamp)
        if st:
            out.append(("DTSTART;VALUE=DATE:%s" if st[1] else "DTSTART:%s") % st[0])
        if en:
            out.append(("DTEND;VALUE=DATE:%s" if en[1] else "DTEND:%s") % en[0])
        out.append("SUMMARY:%s" % esc(ev.get("title", "")))
        if ev.get("location"):
            out.append("LOCATION:%s" % esc(ev.get("location")))
        desc = ev.get("description") or ev.get("notes")
        if desc:
            out.append("DESCRIPTION:%s" % esc(desc))
        out.append("END:VEVENT")
    out.append("END:VCALENDAR")
    return "\r\n".join(out) + "\r\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apple-id", required=True)
    ap.add_argument("--kind", required=True, choices=["contacts", "calendar"])
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    api = get_service(a.apple_id)
    if a.kind == "contacts":
        cs = api.contacts.all() or []
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(vcards(cs))
        print("DONE wrote %d contacts -> %s" % (len(cs), a.out))
    else:
        allev = {}
        thisyear = datetime.datetime.today().year
        for yr in range(2008, thisyear + 3):
            try:
                evs = api.calendar.events(datetime.datetime(yr, 1, 1), datetime.datetime(yr, 12, 31)) or []
            except Exception as e:
                print("  (year %d skipped: %s)" % (yr, e)); evs = []
            for ev in evs:
                allev[ev.get("guid") or repr(ev)] = ev
            if evs:
                print("  %d: %d events (total %d)" % (yr, len(evs), len(allev)))
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(ics(list(allev.values())))
        print("DONE wrote %d events -> %s" % (len(allev), a.out))


if __name__ == "__main__":
    main()
