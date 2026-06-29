# Security Policy

## Reporting a vulnerability
Please open a **private** report or contact the maintainer rather than filing a
public issue for anything sensitive. We'll acknowledge and address it as quickly
as we can.

## Handling secrets (important for users)
This tool touches real accounts. Protect yourself:
- **GitHub tokens / Apple IDs / Nextcloud passwords are never stored by the tool.**
  Don't paste them into scripts, commits, or issues.
- `parts.txt` contains short-lived **signed Apple download URLs** — it is
  git-ignored on purpose. Don't commit it.
- If you ever expose a token (e.g. in a paste), **revoke it immediately**
  (GitHub: Settings -> Developer settings -> Tokens).
- Disabling server-side encryption is a deliberate, documented trade-off — back
  up before doing it.
