# iCloud → Nextcloud Migration (Pro Edition)

A battle-tested toolkit for migrating an **iCloud Photos** export into **Nextcloud + the Memories app**, including everything the original guides leave out. Built and proven on a real ~500 GB / ~54,000-item library.

> Improves on [platelminto/icloud-to-nextcloud](https://github.com/platelminto/icloud-to-nextcloud) with the fixes that actually matter at scale: encryption handling, fast video-date repair, server-side parallel downloads, real Favorites/Hidden mapping, album folders **and** Memories albums kept in sync, geocoding, and a self-maintaining "new photos" pipeline.

---

## ⚠️ Read this first — the gotchas that will waste your time

These are the things that broke (or nearly broke) the migration and cost hours to diagnose. Handle them up front.

### 1. Server-side encryption must be OFF
If Nextcloud **server-side encryption** is enabled, the files on disk are AES-encrypted. Consequences:
- **Memories video transcoding silently fails** — `go-vod` reads files straight off disk and can't decrypt them, so HEVC playback is broken/slow.
- You **cannot** place files directly into the data directory (Nextcloud rejects unencrypted files).
- Everything is slower (per-read decryption).

Check: `occ encryption:status`. If enabled, decrypt (master-key mode needs no user passwords):
```bash
occ encryption:decrypt-all      # answer "yes"; runs in single-user mode
occ encryption:disable
occ app:disable encryption
```
**Back up first** (DB + data). This is a one-way, instance-wide operation. If interrupted you can re-run `decrypt-all`.

### 2. Videos lose their dates too — but DON'T use exiftool to fix them
Many videos (TikToks, screen recordings, re-encodes) export with a **`0000:00:00` CreateDate**, so Memories dumps them at "today." The obvious fix — rewriting QuickTime tags with exiftool — is a **trap**: on networked/seedbox storage it rewrites the whole file and runs at ~40s/file (days for thousands of videos).

**Do this instead:** set the file's **modification time** to the real date (instant — no rewrite). Memories uses file mtime as its date fallback when there's no EXIF date. Then `files:scan` + `memories:index`. See `fix_video_dates.py`. (Photos are different — see #3.)

### 3. Photos lose EXIF → restore in ONE batch
Apple strips EXIF from exported **photos**. Restore `DateTimeOriginal`/`CreateDate` from the `Photo Details*.csv` files, but do it as a **single `exiftool -csv=` batch**, not per-file — orders of magnitude faster. See `build_photo_dates.py`.

### 4. The export layout (varies, but this is common)
- Parts come as `iCloud Photos Part N of 21.zip`. Apple may **front-load videos** into the early parts and put the **photos in later parts** — don't assume part order.
- Each part's `Photos/` holds its media **and** its own `Photo Details*.csv` (per-part metadata).
- The **`Albums/` folder lives in ONE part** (usually Part 1) — it has one CSV per album (incl. `Favorites.csv`, `Hidden.csv`). Album CSV filenames are sometimes **quoted** — strip the quotes.
- `Memories/` CSVs are Apple's auto-generated "memory" slideshows — **skip them** (Nextcloud Memories makes its own).

### 5. Download to the SERVER, not via your laptop
Re-uploading ~500 GB from a home connection is painful. Instead, grab each part's download link from `privacy.apple.com` and `curl` it **directly onto the server** in parallel — datacenter bandwidth, and it survives disconnects with `disown`. Apple's links expire in minutes, so move fast. See `download_parts.sh`.

### 6. Favorites = a real "star", not just an album
The Memories **Favorites view** (`/apps/memories/favorites`) shows files tagged with Nextcloud's favorite flag, **not** an album named "Favorites." Map `Favorites.csv` to the actual star tag (see `reconstruct_albums.sh`).

### 7. No GPU? HEVC still transcodes fine on a big CPU
Without `/dev/dri`, transcoding is software-only. On a many-core box it's still fast (we measured 1080p HEVC at ~6x real-time). Just make sure `ffmpeg`/`ffprobe` paths are set for Memories and encryption is off (#1).

---

## What's in here

It's **one tool** — `icloud2nc.sh` — with subcommands. The Python files are its helpers (auto-copied next to it on first run).

| File | Purpose |
|---|---|
| **`icloud2nc.sh`** | **The all-in-one tool.** Edit the CONFIG block at the top, then run subcommands (below). |
| `build_photo_dates.py` | Helper: builds the exiftool `-csv` batch that restores photo dates. |
| `fix_video_dates.py` | Helper: fast video-date fix (sets file mtime from the metadata CSVs). |
| `autodate.py` | Helper + cron: gives newly-arrived dateless files a date from their **filename**. |
| `config.sh`, `download_parts.sh` | Optional standalone variants (the all-in-one already includes these). |

### Subcommands
```text
./icloud2nc.sh doctor     preflight: encryption status, tools, disk, Memories, GPU
./icloud2nc.sh tools      install exiftool + static ffmpeg/ffprobe (no root) and wire into Nextcloud
./icloud2nc.sh download    parallel, detach-safe server-side download from parts.txt
./icloud2nc.sh import      extract -> restore photo EXIF -> fix video dates -> scan -> index
./icloud2nc.sh albums      Memories albums + matching /Albums folders + Favorites stars + Hidden
./icloud2nc.sh extras      geocoding (places) + Recognize (AI) + Preview Generator
./icloud2nc.sh crons       going-forward automation (index 15m, filename-dates 30m)
./icloud2nc.sh status      counts: library files, memories rows, albums, folders
./icloud2nc.sh watch       background watchdog that restarts a dead import
./icloud2nc.sh all         download -> import -> albums -> extras -> crons
```

## Order of operations
```bash
nano icloud2nc.sh                 # edit the CONFIG block (NC_USER, paths, OCC)
./icloud2nc.sh doctor             # fix anything it flags (esp. encryption -- gotcha #1)
./icloud2nc.sh tools              # exiftool + ffmpeg
# put your part links in ~/icloud_migration/parts.txt  (lines: "6  https://...")
./icloud2nc.sh download           # downloads to the server, survives disconnects
./icloud2nc.sh import             # the long one (hours); run `watch` alongside for auto-restart
./icloud2nc.sh albums
./icloud2nc.sh extras
./icloud2nc.sh crons
./icloud2nc.sh status
# ...or just: ./icloud2nc.sh all
```

`parts.txt` format (one per line):
```text
6   https://cvws.icloud-content.com/.....Part+6+of+21.zip?....
7   https://cvws.icloud-content.com/.....Part+7+of+21.zip?....
```

## Requirements
- Shell access to the Nextcloud server and the ability to run `occ`.
- `unzip`, `python3`, `perl` (for exiftool), and a static `ffmpeg`/`ffprobe` (no root needed -- see `setup_extras.sh`).
- `exiftool` (clone `https://github.com/exiftool/exiftool` -- pure Perl, no root).
- The Memories app installed; Nextcloud background jobs set to **cron**.

## Going forward (new phone photos)
1. Install the **Nextcloud mobile app** -> enable **Auto Upload** to your photo folder.
2. `install_crons.sh` adds: `memories:index` every 15 min (new photos appear) and `autodate.py` every 30 min (filename-based dates for dateless files).
3. Photos with GPS are reverse-geocoded automatically once `setup_extras.sh` has run `places-setup`.

## Notes & limits
- **Location can't be invented.** A photo with no embedded GPS has no source for a location. Only GPS-bearing photos get mapped.
- **Album folders use hardlinks** (`ln`), so duplicating a photo across albums costs ~no extra disk. A `.nomedia` in `/Albums` keeps those copies out of the Memories timeline (no doubles).
- Run heavy steps **without** concurrent downloads -- extraction + indexing are disk-bound and will fight a download for I/O.
