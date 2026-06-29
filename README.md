# iCloud → Nextcloud Migration (Pro Edition)

**`icloud2nc`** — one command-line tool to migrate your entire **iCloud Photos** export into **Nextcloud + Memories**, with dates, locations, albums, and favorites intact. Battle-tested on a real ~500 GB / ~54,000-item library.

```bash
nano icloud2nc.sh     # edit the CONFIG block (NC_USER, paths, OCC)
./icloud2nc.sh        # interactive menu
./icloud2nc.sh all    # guided full run, with time estimates + confirmations
```

It does what the basic guides skip: handles server-side **encryption**, repairs **video dates** the fast way, restores **photo EXIF** in one batch, downloads parts straight to the server, sets **real Favorites stars**, builds Memories albums **and** matching folders, adds geocoding + AI tagging, and installs a self-maintaining pipeline for new phone photos.

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
| `prune`    | Delete the downloaded part zips to reclaim space |
| `clean`    | Clear scratch (metadata/state/logs) — library untouched |

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

## Going forward (new phone photos)

1. Nextcloud mobile app → **Auto Upload** to your photo folder.
2. `crons` installs `memories:index` every 15 min (new photos appear) and `autodate.py` every 30 min (filename-based dates for dateless files like screenshots).
3. Photos with GPS are reverse-geocoded automatically (after `extras`).

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

---

## Requirements

Shell access + `occ`; `unzip`, `python3`, `perl`, `curl`; the Memories app installed; background jobs in **cron** mode. `tools` installs exiftool + ffmpeg without root.

## Files

`icloud2nc.sh` (the tool) · `build_photo_dates.py` · `fix_video_dates.py` · `autodate.py` · `get_links.js` · `config.sh` / `download_parts.sh` (optional standalone).

## License

MIT. Use at your own risk; **always back up** before destructive steps (decryption, archive).
