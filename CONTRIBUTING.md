# Contributing

Thanks for helping improve **icloud2nc**! This tool was forged during a real
~500 GB / 54k-item migration; patches that make it more robust or broaden support
(other DBs, AIO/Docker `occ`, other export layouts) are very welcome.

## Ground rules
- **Never commit credentials.** No Apple IDs, Nextcloud passwords,  tokens,
  or `parts.txt` (it holds private, expiring URLs). `.gitignore` covers the
  usual suspects — keep it that way.
- **The Apple login stays manual.** We do not automate Apple ID sign-in: it needs
  a password + 2FA, violates Apple's terms, and can lock accounts. patches that add
  credential-based Apple automation will be declined.
- Keep `icloud2nc.sh` POSIX-ish bash; keep helpers in plain Python 3 (stdlib only).
- Run `bash -n icloud2nc.sh` and `python3 -m py_compile *.py` before opening a change.
- Prefer **non-destructive** defaults. Anything that deletes/moves user data must
  confirm first and be documented.

## Dev quickstart
```bash
shellcheck icloud2nc.sh        # if available
bash -n icloud2nc.sh
./icloud2nc.sh doctor          # against a test Nextcloud
```

## Reporting bugs / ideas
file a report. Include your
Nextcloud version, how you run `occ`, and the relevant `~/icloud_migration/logs/`
output (scrub anything private).
