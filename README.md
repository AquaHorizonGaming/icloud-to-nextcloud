# iCloud → Nextcloud Migration (Pro Edition)

**`icloud2nc`** — one command-line tool to migrate your entire **iCloud Photos** (and **iCloud Drive**) into **Nextcloud + Memories**, with dates, locations, albums, and favorites intact. Battle-tested on a real ~500 GB / ~54,000-item library.

```bash
nano icloud2nc.sh     # edit the CONFIG block (NC_USER, paths, OCC)
./icloud2nc.sh        # interactive menu
./icloud2nc.sh all    # guided full run, with time estimates + confirmations
```

It does what the basic guides skip: handles server-side **encryption**, repairs **video dates** the fast way, restores **photo EXIF** in one batch, downloads parts straight to the server, sets **real Favorites stars**, builds Memories albums **and** matching folders, adds geocoding + AI tagging, and installs a self-maintaining pipeline for new phone photos.

### Highlights

- **Two ways to fetch photos** — the privacy.apple.com export (`download`) *or* a direct live pull via [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader) (`pull`).
- **Clean separation** — photos live in `/Photos` (the Memories timeline); iCloud Drive documents land in `/Files/iCloud` (Files app only).
- **Multiple accounts** — save a profile per Nextcloud user and switch which one everything targets (`accounts`).
- **Correct dates** — photo EXIF + video mtime restored from the export metadata, so the timeline isn't a pile of "today."
- **Albums, Favorites, Hidden** — reconstructed as real Memories albums, folder views, favorite stars, and an out-of-timeline archive.
- **AI + maps** — Recognize (faces/objects), reverse-geocoding, preview pre-generation.
- **Safe by design** — every stage is resumable, logged, run-locked; destructive steps confirm and support `--dry-run`.

> **New in v2.4:** `drive` (iCloud Drive import), `pull` (icloudpd direct download), and `accounts` (multi-account targeting).

---

## ⚠️ Read first — the gotchas that waste hours

**1. Server-side encryption must be OFF.**
Encrypted-at-rest files break Memories video transcoding (`go-vod` can't read them) and can't be placed directly into the data dir. `doctor` detects it. Fix (**back up first**):

```bash
occ encryption:decrypt-all     # answer "yes"; master-key mode needs no user passwords
occ encryption:disable
occ app:disable encryption
```

**2. Videos lose dates too — but don't fix them with exiftool.**
Many videos export with a junk `0000:00:00` date, so Memories dumps them at "today." Rewriting QuickTime tags with exiftool is a trap (whole-file rewrite ≈ days on networked storage). The tool sets each video's **mtime** from the metadata CSV instead — instant — and Memories uses that as its date fallback.

**3. Photos lose EXIF** — restored in a single fast `exiftool -csv` batch.

**4. Export layout** — videos are often front-loaded into the early parts and photos land in later parts; the `Albums/` folder lives in just one part; album-CSV filenames are sometimes quoted; the `Memories/` slideshow CSVs are skipped.

**5. Download to the server, not your laptop** — pull the part links directly with `curl`, in parallel; they survive disconnects.

**6. Favorites = a real star** (the Memories *Favorites* view), not an album. The tool sets the actual favorite flag.

**7. No GPU is fine** — software HEVC transcode runs several times faster than real-time on a many-core box once encryption is off.

---

## Commands

| Command | What it does |
|---|---|
| `doctor`   | Preflight: encryption, occ, user, Memories, cron mode, tools, disk, GPU |
| `tools`    | Install `exiftool` + static `ffmpeg`/`ffprobe` (no root) and wire into Memories |
| `links`    | How to harvest all part links in one click (see `get_links.js`) |
| `download` | Parallel, detach-safe server-side download from `parts.txt` |
| `pull`     | **Direct** download from iCloud via [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader) — interactive Apple login (no export needed) |
| `import`   | Extract → restore photo EXIF → fix video dates → scan → index |
| `albums`   | Memories albums + matching `/Albums/` folders (hardlinks) + Favorites stars |
| `archive`  | Optional: move **Hidden** items out of the main timeline |
| `extras`   | Geocoding + Recognize (AI faces/objects) + Preview Generator |
| `crons`    | Going-forward automation (index /15 min, filename-date fixup /30 min) |
| `status`   | Quick counts (files, indexed items, albums, folders, favorites, free space) |
| `verify`   | Deep check: dates, albums↔folders match, duplicate albums, favorites |
| `report`   | Write a Markdown migration report |
| `logs`     | Tail the run log |
| `resume`   | Re-run only the stages not yet marked complete |
| `all`      | Guided full run end-to-end |
| `backup`   | Dump the database + config before destructive steps |
| `dedupe`   | Find duplicate media by content hash (`dedupe --remove` deletes extras) |
| `faces`    | Cluster faces into People (Recognize) |
| `hwaccel`  | Enable GPU/VAAPI transcoding if `/dev/dri` exists |
| `contacts` | Merge exported vCards into one file for import (`--strip-photos` optional) |
| `calendars`| Collect exported `.ics` files for import |
| `drive`    | Migrate **iCloud Drive** documents into `/Files/iCloud` (Files app only, kept out of the Memories timeline) |
| `prune`    | Delete the downloaded part zips to reclaim space |
| `clean`    | Clear scratch (metadata/state/logs) — library untouched |
| `accounts` | Manage **multiple Nextcloud accounts** and pick which one all photos/files target |

Run with **no argument** for an interactive menu. Every stage is **resumable** (state under `~/icloud_migration/state/`), fully **logged** (`~/icloud_migration/logs/`), and guarded by a **run-lock** so two heavy runs can't collide.

---

## ⏱️ Rough time estimates

_From a ~500 GB / 54k-item run. `all` prints these and confirms before starting._

| Stage | Time | Bound by |
|---|---|---|
| download            | minutes–hours | your bandwidth |
| import → extract    | ~45–75 min    | disk I/O |
| import → photo EXIF | ~20–40 min    | exiftool batch (42k photos) |
| import → video dates| seconds       | mtime only (the key fix) |
| import → scan+index | ~25–40 min    | file count (54k) |
| albums              | ~30–40 min    | one occ call per membership (~1.4k) |
| extras              | minutes, then background | model download; previews continue via cron |

> Don't run extraction while downloads are active — they fight for the same disk.

---

## Quickstart

```bash
nano icloud2nc.sh        # set NC_USER, NC_FILES, OCC, ...
./icloud2nc.sh doctor    # fix whatever it flags (especially encryption)
./icloud2nc.sh tools

# get links: log into privacy.apple.com, run get_links.js,
# save the output to ~/icloud_migration/parts.txt
./icloud2nc.sh download

./icloud2nc.sh import &   # the long one; runs in background
./icloud2nc.sh logs       # watch progress
./icloud2nc.sh albums
./icloud2nc.sh extras
./icloud2nc.sh crons
./icloud2nc.sh verify
# ...or just:  ./icloud2nc.sh all
```

`parts.txt` is one part per line — a number, whitespace, then the URL:

```text
6   https://cvws.icloud-content.com/.../iCloud+Photos+Part+6+of+21.zip?...
7   https://cvws.icloud-content.com/.../iCloud+Photos+Part+7+of+21.zip?...
```

---

## Getting the part links (`get_links.js`)

The Apple login is **never automated** — it needs your password + 2FA, and scripting Apple ID sign-in violates Apple's terms and can lock your account. Instead: log in yourself, open the data-download page, paste `get_links.js` into the browser console (F12), and it prints + copies every part link in `parts.txt` format. One paste instead of 21.

---

## Two ways to get your photos

**A) privacy.apple.com export** (`links` → `download` → `import`) — Apple builds a one-time archive you download in parts. Includes album membership, favorites, and hidden flags (which `albums`/`archive` then reconstruct). Best for a complete one-shot migration.

**B) Direct download** (`pull`) — uses [**icloudpd**](https://github.com/icloud-photos-downloader/icloud_photos_downloader) to pull straight from your iCloud library over the API. No waiting on an export, and great for **incremental** top-ups later.

```bash
./icloud2nc.sh pull                      # prompts for Apple ID, then password + 2FA
./icloud2nc.sh pull you@example.com      # or pass the Apple ID
APPLE_ID=you@example.com ./icloud2nc.sh pull
```

- **Auth is interactive and yours** — icloudpd prompts for your Apple **password + 2FA** in the terminal. This tool never stores or reads your credentials; a session cookie is cached by icloudpd so re-runs don't re-prompt. Needs an interactive terminal for the 2FA step.
- Files download already-dated (icloudpd sets EXIF), straight into `/Photos/Icloud`, then the tool runs `files:scan` + `memories:index`.
- Tune with `ICLOUDPD_OPTS`, e.g. `ICLOUDPD_OPTS='--until-found 50'` for fast incremental syncs, or `--recent 500` for just the latest.
- Note: the `pull` path brings **media only** — album/favorite/hidden reconstruction is exclusive to the export path (those live in the export CSVs).

> First `pull` auto-installs icloudpd with `pip install --user icloudpd` (no root).

---

## Going forward (new phone photos)

1. Nextcloud mobile app → **Auto Upload** to your photo folder.
2. `crons` installs `memories:index` every 15 min (new photos appear) and `autodate.py` every 30 min (filename-based dates for dateless files like screenshots).
3. Photos with GPS are reverse-geocoded automatically (after `extras`).

---

## Multiple accounts

Migrate more than one person's library — each Nextcloud user is a saved **profile**, and a command picks which one everything targets.

```bash
./icloud2nc.sh accounts add mom        # create/link a profile (offers to create the NC user)
./icloud2nc.sh accounts list           # see all profiles; * marks the active one
./icloud2nc.sh accounts use mom        # switch — every later command now targets 'mom'
./icloud2nc.sh accounts current        # show the active account
./icloud2nc.sh pull                    # ...downloads into mom's library
./icloud2nc.sh accounts use me         # switch back
```

- `accounts add` asks for the Nextcloud username, offers to **create that user** if it doesn't exist (you type the password — the tool passes it straight to `occ user:add` and never stores it), optionally saves an Apple ID for `pull`, then prepares that user's `Photos/Icloud` + `Files/iCloud` folders and points Memories at the right path.
- The active account is remembered in `~/.config/icloud2nc/current`; profiles live in `~/.config/icloud2nc/accounts/<name>.conf`.
- Every command (`download`, `pull`, `import`, `albums`, `drive`, `status`, …) automatically uses the selected account's user and paths. No active account = the default in the CONFIG block.

## Layout: Photos vs Files

The tool keeps your **media** and your **documents** cleanly separated:

```
/Photos/
   Icloud/     ← all photos & videos (this is the Memories timeline)
   Albums/     ← album folders (hardlinks), excluded from the timeline via .nomedia
/Files/
   iCloud/     ← iCloud Drive documents (Files app only — NOT in Memories)
```

Memories' timeline path is set to `/Photos/Icloud`, so **Memories shows only your photos** and the **Files app** is where your documents live.

## Migrating iCloud Drive (the `drive` command)

iCloud *Photos* and iCloud *Drive* are separate exports. To bring your Drive documents over:

1. On [privacy.apple.com](https://privacy.apple.com), request/download your **iCloud Drive** data (delivered as one or more `.zip`s that already preserve folder structure and modified-times).
2. Put the zip(s) in `~/icloud_migration/drive_incoming/` (or anywhere), then run:

```bash
./icloud2nc.sh drive                       # uses drive_incoming/
./icloud2nc.sh drive /path/to/zips         # a folder of zips
./icloud2nc.sh drive /path/to/export.zip   # a single zip
./icloud2nc.sh drive /path/to/folder       # already-extracted files
```

It extracts into `/Files/iCloud` (stripping Apple's `iCloud Drive/` wrapper), preserves dates, runs a scan, and **keeps everything out of the Memories timeline** so your photo dates stay clean. For *ongoing* sync of new files, point the Nextcloud desktop/mobile app at the `Files/iCloud` folder.

---

## Recipes

**Full migration from the Apple export (the classic path):**

```bash
./icloud2nc.sh doctor      # fix flagged issues (esp. encryption OFF)
./icloud2nc.sh tools       # exiftool + ffmpeg
# harvest links with get_links.js -> parts.txt
./icloud2nc.sh download
./icloud2nc.sh import       # extract + restore dates + scan + index
./icloud2nc.sh albums       # albums + folders + favorites
./icloud2nc.sh extras       # geocode + AI + previews
./icloud2nc.sh crons        # going-forward automation
./icloud2nc.sh verify
```

**Skip the export — pull straight from iCloud:**

```bash
./icloud2nc.sh doctor && ./icloud2nc.sh tools
./icloud2nc.sh pull you@example.com   # interactive Apple password + 2FA
./icloud2nc.sh extras && ./icloud2nc.sh crons
```

**Migrate a second person onto the same server:**

```bash
./icloud2nc.sh accounts add partner   # creates the NC user + folders
./icloud2nc.sh pull partner@icloud.com
# ...later, switch back:
./icloud2nc.sh accounts use me
```

**Bring in iCloud Drive documents (any account):**

```bash
./icloud2nc.sh accounts use partner   # optional: pick the target
./icloud2nc.sh drive ~/Downloads/iCloudDrive.zip
```

**Incremental top-up later (only new photos):**

```bash
ICLOUDPD_OPTS='--until-found 50' ./icloud2nc.sh pull
```

---

## Power-user options

- **External config** — drop settings in `~/.config/icloud2nc.conf` (or point `ICLOUD2NC_CONF` at a file) instead of editing the script; it's sourced at startup.
- **`--yes`** — skip confirmation prompts (for unattended runs).
- **`--dry-run`** — destructive commands (`prune`, `clean`, `dedupe --remove`) print what they'd do without doing it.

Example: `./icloud2nc.sh --yes import`  ·  `./icloud2nc.sh --dry-run dedupe --remove`

## Troubleshooting

- **Videos all show "today"** — encryption still on, or `import` hasn't reached `memories:index` yet. Run `doctor`; re-run `import` (resumable).
- **Video playback slow/black** — encryption on (#1), or `ffmpeg` path not set — run `tools`.
- **A part won't extract** — it downloaded incompletely; `download` again with a fresh link. `import` skips bad zips and warns.
- **Album shows 0 files** — that album was empty in your export (some app-created ones are).
- **Favorites view empty** — re-run `albums` (it stars `Favorites.csv`), then refresh the Favorites view.
- **Duplicate albums** — happens if `albums` was interrupted then re-run; `verify` reports them.
- **Location missing** — can't be invented; only photos with embedded GPS get mapped.
- **`pull` can't ask for 2FA** — icloudpd needs an interactive terminal for the code; run it in a real SSH/terminal session, not a non-interactive script. Re-run to resume; the session cookie is cached.
- **`pull` 2FA every time** — the cookie directory isn't persisting; keep the same `$HOME` between runs (icloudpd stores its session under it).
- **New account shows nothing / scan skipped** — a brand-new Nextcloud user's home isn't created until first login. Log into the web UI once as that user, then `accounts use <name>` and re-run `accounts prep`.
- **iCloud Drive files appear in the photo timeline** — make sure they went to `/Files/iCloud` (via `drive`), not under `/Photos`.

---

## Requirements

Shell access + `occ`; `unzip`, `python3`, `perl`, `curl`; the Memories app installed; background jobs in **cron** mode. `tools` installs exiftool + ffmpeg without root. The `pull` command auto-installs [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader) via `pip install --user` on first use (needs `python3`/`pip`). For `pull` you also need an interactive terminal so you can enter your Apple 2FA code.

## Files

`icloud2nc.sh` (the tool) · `build_photo_dates.py` · `fix_video_dates.py` · `autodate.py` · `get_links.js` · `config.sh` / `download_parts.sh` (optional standalone).

## License

MIT. Use at your own risk; **always back up** before destructive steps (decryption, archive).
