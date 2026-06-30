# icloud2nc — Full Documentation

A complete manual for **`icloud2nc`**, the all-in-one tool that migrates **iCloud Photos** and **iCloud Drive** into **Nextcloud + Memories** and keeps them up to date.

- [1. What it does](#1-what-it-does)
- [2. Requirements](#2-requirements)
- [3. Install & configure](#3-install--configure)
- [4. The folder layout](#4-the-folder-layout)
- [5. Getting your photos in](#5-getting-your-photos-in)
- [6. Getting your iCloud Drive files in](#6-getting-your-icloud-drive-files-in)
- [7. Multiple accounts](#7-multiple-accounts)
- [8. Keeping things up to date (automation)](#8-keeping-things-up-to-date-automation)
- [9. Command reference](#9-command-reference)
- [10. Configuration variables](#10-configuration-variables)
- [11. How the tricky bits work](#11-how-the-tricky-bits-work)
- [12. Troubleshooting](#12-troubleshooting)
- [13. Security & privacy](#13-security--privacy)
- [14. FAQ](#14-faq)

---

## 1. What it does

`icloud2nc` is a single Bash script that automates a full iCloud → Nextcloud migration and the ongoing sync afterward:

- **Two ways to fetch photos:** the official privacy.apple.com export, or a direct live pull via [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader).
- **iCloud Drive files** via the official export zip, or a direct live (parallel) download via [icloudpy](https://pypi.org/project/icloudpy/).
- **Correct dates** restored from the export metadata (photo EXIF + video timestamps) so your Memories timeline isn't a wall of "today."
- **Albums, Favorites, Hidden** rebuilt as real Memories albums, folder views, favorite stars, and an out-of-timeline archive.
- **AI + maps:** Recognize faces/objects, reverse-geocoding, preview pre-generation.
- **Multiple Nextcloud accounts**, each a switchable target.
- **Automation:** scheduled incremental pulls so new photos flow in by themselves.

Everything is **resumable**, **logged**, and **run-locked**; destructive steps confirm and support `--dry-run`.

---

## 2. Requirements

- Shell access to the server running Nextcloud, and a working `occ` (the script auto-detects `php <path>/occ`).
- `unzip`, `python3` (with the `venv` module), `perl`, `curl`.
- The **Memories** app installed; Nextcloud background jobs set to **cron** mode.
- Server-side **encryption OFF** (see [§11](#11-how-the-tricky-bits-work)).
- `tools` installs `exiftool` + static `ffmpeg`/`ffprobe` without root. `pull`/`drive-pull` auto-install `icloudpd`/`icloudpy` into an isolated venv (works even on minimized / PEP 668 hosts with no system pip).

---

## 3. Install & configure

```bash
# put icloud2nc.sh (and the .py helpers) somewhere on the server, e.g. ~/icloud_migration
chmod +x icloud2nc.sh
nano icloud2nc.sh        # edit the CONFIG block if defaults don't match your install
./icloud2nc.sh doctor    # preflight — fix whatever it flags
```

`doctor` checks: occ runs, the user exists, encryption is off, Memories is installed, cron mode, tool presence (exiftool/ffmpeg/icloudpd), free disk, GPU, PHP memory, and memcache.

You can keep settings out of the script in `~/.config/icloud2nc.conf` (sourced at startup), or point `ICLOUD2NC_CONF` at any file.

---

## 4. The folder layout

```
<user>/files/
  Photos/
    Icloud/    ← all photos & videos — THIS is the Memories timeline
    Albums/    ← album folders (hardlinks), excluded from the timeline via .nomedia
  Files/
    iCloud/    ← iCloud Drive documents — shows in the Files app, NOT in Memories
```

Memories' timeline path is set to `/Photos/Icloud`, so **Memories shows only photos** and the **Files app** holds your documents. This keeps document dates from polluting the photo timeline.

---

## 5. Getting your photos in

### Option A — privacy.apple.com export (most complete)

Includes album membership, favorites, and hidden flags, so `albums`/`archive` can fully reconstruct them.

```bash
./icloud2nc.sh doctor
./icloud2nc.sh tools
# log into privacy.apple.com, run get_links.js in the browser console,
# save its output to ~/icloud_migration/parts.txt
./icloud2nc.sh download    # parallel, detach-safe server-side download
./icloud2nc.sh import      # extract → restore photo EXIF → fix video dates → scan → index
./icloud2nc.sh albums      # Memories albums + folder views + favorite stars
./icloud2nc.sh archive     # (optional) move Hidden items out of the timeline
./icloud2nc.sh extras      # geocoding + Recognize + preview pre-gen
./icloud2nc.sh crons       # going-forward automation
./icloud2nc.sh verify
```

### Option B — direct download via icloudpd (`pull`)

No waiting on an export; great for incremental top-ups. **Media only** (albums/favorites/hidden come only from the export path).

```bash
./icloud2nc.sh pull                     # prompts for Apple ID, password, 2FA
./icloud2nc.sh pull you@example.com
APPLE_ID=you@example.com ./icloud2nc.sh pull
```

Auth is interactive (password + 2FA). Nothing is stored beyond icloudpd's session cookie. Files land already-dated in `Photos/Icloud`, then `files:scan` + `memories:index` run automatically.

---

## 6. Getting your iCloud Drive files in

### Option A — export zip (`drive`)

```bash
./icloud2nc.sh drive                      # uses ~/icloud_migration/drive_incoming/
./icloud2nc.sh drive /path/to/export.zip
./icloud2nc.sh drive /path/to/folder
```

Extracts into `Files/iCloud` (strips Apple's `iCloud Drive/` wrapper), preserves dates, scans. Stays out of the Memories timeline.

### Option B — live, parallel download (`drive-pull`)

```bash
./icloud2nc.sh drive-pull                 # interactive Apple login (password + 2FA)
IDRIVE_WORKERS=16 ./icloud2nc.sh drive-pull   # more parallelism
IDRIVE_WORKERS=4  ./icloud2nc.sh drive-pull   # gentler on the connection
```

Walks your whole Drive and downloads into `Files/iCloud` **in parallel** (default 8 workers), preserving folder structure and modified-times. Incremental — files already present at the same size are skipped — and resumable. First run auto-installs `icloudpy` into the venv and triggers the 2FA push so Apple actually sends a code.

---

## 7. Multiple accounts

Each Nextcloud user can be a migration target. `accounts` sees **all** users on the server, not just ones the tool created.

```bash
./icloud2nc.sh accounts list            # every NC user; * = active, [profile] = configured
./icloud2nc.sh accounts use Aqua        # switch target (case-sensitive!)
./icloud2nc.sh accounts add mom you@icloud.com   # create/link + store email & Apple ID
./icloud2nc.sh accounts current
./icloud2nc.sh accounts remove mom      # removes the profile only, never the NC user/files
```

- `accounts use <name>` works for **any existing Nextcloud user** (auto-creates a lightweight profile). For a not-yet-existing user, `accounts add` offers to create it (you type the password — never stored), sets the email, and prepares its folders + Memories timeline.
- The active account is remembered in `~/.config/icloud2nc/current`; profiles live in `~/.config/icloud2nc/accounts/<name>.conf`.
- Every command targets the active account's user and paths.

---

## 8. Keeping things up to date (automation)

### Device-side
Nextcloud mobile app → **Auto Upload** into your photo folder. `crons` then runs `memories:index` every 15 min and a filename-date fixup every 30 min.

### Server-side from iCloud (`autopull`)
```bash
./icloud2nc.sh pull          # once, interactively, to establish the session
./icloud2nc.sh autopull on   # schedule incremental pulls (default every 6h)
./icloud2nc.sh autopull status
./icloud2nc.sh autopull off
```

`autopull` installs a cron per account that has a stored Apple ID, running an incremental `pull --auto` (stops after `ICLOUDPD_UNTIL` already-downloaded items). It **reuses the session cookie** from your interactive `pull` — no password is stored. When Apple expires the session, the cron logs a note (`~/icloud_migration/logs/autopull-<account>.log`) and you run `pull` once to re-authenticate.

---

## 9. Command reference

| Command | What it does |
|---|---|
| `doctor` | Preflight checks |
| `tools` | Install exiftool + ffmpeg/ffprobe (no root) and wire into Memories |
| `links` | How to harvest all export part links at once (`get_links.js`) |
| `download` | Parallel, detach-safe server-side download from `parts.txt` |
| `pull` | Live photo download via icloudpd (interactive login); `--auto` = incremental |
| `import` | Extract export → restore dates → scan → index |
| `albums` | Rebuild albums + folder views + favorite stars |
| `archive` | Move Hidden items out of the timeline |
| `extras` | Geocoding + Recognize + Preview Generator |
| `crons` | Going-forward index + filename-date automation |
| `autopull` | Schedule incremental icloudpd pulls per account (`on`/`off`/`status`) |
| `drive` | Import an iCloud Drive export zip into `Files/iCloud` |
| `drive-pull` | Live, parallel iCloud Drive download via icloudpy |
| `accounts` | List all NC users / pick the target (`list`/`add`/`use`/`current`/`remove`) |
| `status` | Quick counts (files, indexed items, albums, folders, favorites, free space) |
| `verify` | Deep integrity check |
| `report` | Write a Markdown migration report |
| `backup` | Dump the database + config before destructive steps |
| `dedupe` | Find/remove duplicate media by content hash |
| `faces` | Cluster faces into Memories → People |
| `hwaccel` | Enable VAAPI transcoding if `/dev/dri` exists |
| `contacts` | Merge exported vCards for import |
| `calendars` | Collect exported `.ics` for import |
| `prune` | Delete downloaded part zips |
| `clean` | Clear scratch (metadata/state/logs) — library untouched |
| `logs` / `resume` / `all` | Tail log / resume unfinished stages / guided full run |

Run with **no argument** for an interactive menu. Global flags: `--yes` (skip prompts), `--dry-run` (preview destructive commands).

---

## 10. Configuration variables

Set in the CONFIG block, in `~/.config/icloud2nc.conf`, or as environment variables.

| Variable | Default | Meaning |
|---|---|---|
| `NC_USER` | `Aqua` | Target Nextcloud user (overridden by the active account) |
| `NC_FILES` | `/storage/<user>/files` | That user's files root |
| `ICLOUD_DIR` | `<files>/Photos/Icloud` | Photo/video library (Memories timeline) |
| `ALBUMS_DIR` | `<files>/Photos/Albums` | Album folder views |
| `FILES_DIR` / `DRIVE_DIR` | `<files>/Files` / `…/iCloud` | Documents area / iCloud Drive landing |
| `OCC` | `php ~/public_html/occ` | How to run occ |
| `WORK` | `~/icloud_migration` | Scratch: downloads, metadata, logs, tools, venv |
| `APPLE_ID` | — | Apple ID for `pull`/`drive-pull` (stored per account profile) |
| `ICLOUDPD_OPTS` | — | Extra flags passed to icloudpd |
| `ICLOUDPD_UNTIL` | `100` | `pull --auto` stops after N already-downloaded |
| `AUTOPULL_CRON` | `0 */6 * * *` | autopull schedule |
| `IDRIVE_WORKERS` | `8` | Parallel iCloud Drive downloads |
| `GETPIP_URL` | bootstrap.pypa.io | pip bootstrap source for the venv |
| `ICLOUD2NC_ACCOUNT` | — | Force a specific account for one run (used by autopull cron) |

---

## 11. How the tricky bits work

- **Encryption must be OFF.** Server-side encrypted files can't be read by Memories' `go-vod` transcoder or placed directly into the data dir. `doctor` flags it; the fix is `occ encryption:decrypt-all` → `encryption:disable` → `app:disable encryption` (back up first).
- **Video dates the fast way.** Many exported videos carry a junk `0000:00:00` date. Rewriting QuickTime tags with exiftool would take days on networked storage; instead the tool sets each video's **mtime** from the metadata CSV (instant), which Memories uses as its date fallback.
- **Photo EXIF** is restored in a single `exiftool -csv` batch.
- **Favorites** are the real Memories *Favorites* star (a system tag), not an album.
- **Albums** become real Memories albums **and** hardlinked folder views (no extra disk use); the `Albums` folder is kept out of the timeline with `.nomedia`.
- **fileid-safe moves.** Reorganizing uses Nextcloud's own move so favorites, album membership, and face data survive (a raw disk move would reassign file IDs and lose them).

---

## 12. Troubleshooting

- **Videos all show "today"** — encryption still on, or `import` hasn't reached `memories:index`. Run `doctor`; re-run `import`.
- **Video playback slow/black** — encryption on, or `ffmpeg` path unset (`tools`).
- **A part won't extract** — it downloaded incompletely; `download` it again. `import` skips bad zips.
- **Album shows 0 files** — it was empty in your export.
- **Favorites view empty** — re-run `albums`, then refresh.
- **`pull`/`drive-pull` send no 2FA code** — the code is pushed to your **trusted Apple devices** (a phone/Mac signed into that exact Apple ID); check those. Older two-step accounts get a device/SMS picker.
- **`pull` "icloudpd install failed"** — Python lacks pip/ensurepip (minimized image). The tool falls back to an isolated venv; ensure `python3 -m venv` works and PyPI + bootstrap.pypa.io are reachable. Override the source with `GETPIP_URL=`.
- **`pull` can't ask for 2FA** — it needs an interactive terminal for the code; run it in a real shell, not a script. Re-run resumes via the cached session.
- **New account shows nothing** — a brand-new NC user's home is created on first web login; log in once, then `accounts use <name>` and re-run.
- **iCloud Drive files in the photo timeline** — make sure they went to `Files/iCloud` (via `drive`/`drive-pull`), not under `Photos`.

---

## 13. Security & privacy

- **Apple login is never automated.** You enter your password and 2FA directly into icloudpd/icloudpy; the tool never stores or reads them. Only the libraries' own session cookie persists.
- **Account creation** prompts you for the password and hands it straight to `occ user:add`; it isn't stored.
- **Destructive steps** (`archive`, `dedupe --remove`, `prune`, `clean`, decryption) confirm first and honor `--dry-run`.
- All processing is local to your server; nothing is sent anywhere except to Apple (to fetch your own data) and PyPI/exiftool.org/johnvansickle.com (to fetch tools).

---

## 14. FAQ

**Can I migrate more than one person?** Yes — `accounts add` each person, then `accounts use <name>` before running commands, or let `autopull` cover every account with a stored Apple ID.

**Does `pull` get my albums?** No — albums/favorites/hidden live only in the privacy.apple.com export. Use the export path for those.

**Is `drive-pull` safe to interrupt?** Yes. It's incremental and resumable; re-running skips finished files.

**Will autopull keep running forever?** It runs on a schedule, but Apple sessions expire periodically; when that happens you re-auth once with `pull`.

**No GPU — is that OK?** Yes; software HEVC transcoding runs several times faster than real-time on a many-core box once encryption is off. `hwaccel` enables VAAPI if `/dev/dri` exists.
