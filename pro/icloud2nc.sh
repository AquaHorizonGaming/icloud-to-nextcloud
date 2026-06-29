#!/bin/bash
# ============================================================================
#  icloud2nc  --  all-in-one iCloud Photos -> Nextcloud/Memories migration
# ----------------------------------------------------------------------------
#  One self-contained tool. Edit the CONFIG block, then:
#     ./icloud2nc.sh doctor      # preflight checks (encryption, tools, disk)
#     ./icloud2nc.sh tools       # install exiftool + static ffmpeg (no root)
#     ./icloud2nc.sh download    # parallel server-side download from parts.txt
#     ./icloud2nc.sh import      # extract + restore photo EXIF + fix video dates + scan + index
#     ./icloud2nc.sh albums      # Memories albums + matching folders + Favorites stars + Hidden
#     ./icloud2nc.sh extras      # geocoding + Recognize (AI) + Preview Generator
#     ./icloud2nc.sh crons       # going-forward automation (index + filename-dates)
#     ./icloud2nc.sh status      # progress / counts
#     ./icloud2nc.sh all         # download -> import -> albums -> extras -> crons
#     ./icloud2nc.sh watch       # background watchdog that restarts a dead import
# ============================================================================
set -uo pipefail

# ============================== CONFIG ======================================
NC_USER="Aqua"                                  # photo-owning uid (case-sensitive)
NC_FILES="/storage/${NC_USER}/files"            # user's files root in the data dir
ICLOUD_DIR="${NC_FILES}/Icloud"                 # where media is imported
ALBUMS_DIR="${NC_FILES}/Albums"                 # physical album folders
OCC="php ${HOME}/public_html/occ"               # how to run occ (edit for AIO/docker)
WORK="${HOME}/icloud_migration"                 # scratch: downloads, metadata, logs
ALBUMS_PART=1                                   # which part holds the Albums/ folder
DB_HOST="127.0.0.1"; DB_PORT="3306"
# ============================================================================

EXIFTOOL="${WORK}/tools/bin/exiftool"
FFMPEG="${WORK}/tools/bin/ffmpeg"
FFPROBE="${WORK}/tools/bin/ffprobe"
LOG="${WORK}/work/icloud2nc.log"
REL_ICLOUD="${ICLOUD_DIR#${NC_FILES}/}"         # e.g. "Icloud"
mkdir -p "$WORK/incoming" "$WORK/metadata" "$WORK/work" "$WORK/tools/bin" "$ICLOUD_DIR"

c(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%T)" "$*"; }
err(){ printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%T)" "$*" >&2; }
occ(){ $OCC "$@" 2>/dev/null; }
nostderr(){ grep -viE "PHP Warning|raphf|GEOSGeometry|arginfo|imagick|Deprecated"; }
_dbget(){ $OCC config:system:get "$1" 2>/dev/null; }
q(){ local p u pw n; n=$(_dbget dbname); u=$(_dbget dbuser); pw=$(_dbget dbpassword);
     mysql -h"$DB_HOST" -P"$DB_PORT" -u"$u" -p"$pw" "$n" -N -e "$1" 2>/dev/null; }

# --------------------------------------------------------------------------
doctor(){
  c "Preflight checks"
  echo "  occ version : $(occ status | grep versionstring | tr -d ' ')"
  local enc; enc=$(occ encryption:status | grep -i 'enabled:' | tr -d ' ')
  echo "  encryption  : $enc"
  case "$enc" in *true*) err "Server-side encryption is ON. Memories video transcoding will fail and direct file placement won't work.";
     echo "    Fix (BACK UP FIRST):  occ encryption:decrypt-all && occ encryption:disable && occ app:disable encryption";; esac
  echo "  memories    : $(occ app:list 2>/dev/null | grep -c -i ' memories:' >/dev/null && echo installed || echo 'NOT installed (occ app:install memories)')"
  echo "  bg jobs     : $(occ config:app:get core backgroundjobs_mode)"
  echo "  exiftool    : $([ -x "$EXIFTOOL" ] && "$EXIFTOOL" -ver || echo 'missing (run: icloud2nc tools)')"
  echo "  ffmpeg      : $([ -x "$FFMPEG" ] && echo ok || echo 'missing (run: icloud2nc tools)')"
  echo "  data free   : $(df -h "$NC_FILES" | tail -1 | awk '{print $4}')"
  echo "  GPU (/dev/dri): $([ -d /dev/dri ] && echo yes || echo 'none (software transcode; still fine on many cores)')"
}

tools(){
  c "Installing exiftool (pure perl) + static ffmpeg/ffprobe (no root)"
  if [ ! -x "$WORK/tools/exiftool/exiftool" ]; then
    git clone --depth 1 https://github.com/exiftool/exiftool.git "$WORK/tools/exiftool" 2>&1 | tail -1
  fi
  ln -sf "$WORK/tools/exiftool/exiftool" "$EXIFTOOL"
  if [ ! -x "$FFMPEG" ]; then
    c "fetching static ffmpeg"
    curl -sL -o "$WORK/tools/ff.tar.xz" https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz
    tar -xf "$WORK/tools/ff.tar.xz" -C "$WORK/tools"
    d=$(find "$WORK/tools" -maxdepth 1 -type d -name 'ffmpeg-*linux64*' | head -1)
    cp "$d/bin/ffmpeg" "$d/bin/ffprobe" "$WORK/tools/bin/"; rm -rf "$WORK/tools/ff.tar.xz" "$d"
  fi
  "$EXIFTOOL" -ver && "$FFMPEG" -version | head -1
  occ config:system:set preview_ffmpeg_path --value="$FFMPEG" >/dev/null
  occ config:system:set memories.vod.ffmpeg --value="$FFMPEG" >/dev/null
  occ config:system:set memories.vod.ffprobe --value="$FFPROBE" >/dev/null
  c "tools ready and wired into Nextcloud/Memories"
}

download(){
  local list="${1:-$WORK/parts.txt}"
  [ -f "$list" ] || { err "Need $list with lines: <part-number> <url>  (links from privacy.apple.com, they expire fast)"; return 1; }
  cd "$WORK/incoming"
  while read -r num url; do
    [ -z "${num:-}" ] && continue; case "$num" in \#*) continue;; esac
    c "download part $num"
    nohup curl -sL -o "iCloud Photos Part ${num} of 21.zip" "$url" >/dev/null 2>&1 &
  done < "$list"
  disown -a
  c "downloads started + detached (survive disconnect). Check: ls -lah $WORK/incoming"
}

_extract(){
  c "STAGE 1/5  extracting media + per-part metadata"
  shopt -s nullglob
  for z in "$WORK"/incoming/*.zip; do
    [ -f "$z" ] || continue
    if ! unzip -l "$z" >/dev/null 2>&1; then err "skip (incomplete/corrupt): $z"; continue; fi
    local pn; pn=$(echo "$z" | grep -oE 'Part [0-9]+' | grep -oE '[0-9]+')
    mkdir -p "$WORK/metadata/part${pn}"
    unzip -Cojo "$z" "*/Photos/Photo Details*.csv" -d "$WORK/metadata/part${pn}" >/dev/null 2>&1
    unzip -Cojo "$z" "*/Photos/*" -x "*/Photos/Photo Details*.csv" -d "$ICLOUD_DIR" >/dev/null 2>&1
    # preserve the Albums folder (lives in one part only)
    unzip -Cojo "$z" "*/Albums/*" -d "$WORK/metadata/Albums" >/dev/null 2>&1
    c "   part $pn done ($(find "$ICLOUD_DIR" -type f | wc -l) files in library)"
  done
}

import(){
  _extract
  c "STAGE 2/5  restoring photo EXIF dates (single exiftool batch)"
  OUT_CSV="$WORK/work/photo_exif.csv" METADATA_DIR="$WORK/metadata" ICLOUD_DIR="$ICLOUD_DIR" \
    python3 "$WORK/lib/build_photo_dates.py"
  [ -s "$WORK/work/photo_exif.csv" ] && "$EXIFTOOL" -q -m -overwrite_original \
     -csv="$WORK/work/photo_exif.csv" "$ICLOUD_DIR" 2>&1 | tail -2
  c "STAGE 3/5  fixing video dates (fast mtime method)"
  METADATA_DIR="$WORK/metadata" ICLOUD_DIR="$ICLOUD_DIR" python3 "$WORK/lib/fix_video_dates.py"
  c "STAGE 4/5  files:scan"
  occ files:scan --path="${NC_USER}/files/${REL_ICLOUD}" | nostderr | tail -4
  c "STAGE 5/5  memories:index"
  occ memories:index | nostderr | tail -3
  c "IMPORT COMPLETE  ($(find "$ICLOUD_DIR" -type f | wc -l) files)"
}

albums(){
  local A="$WORK/metadata/Albums"
  [ -d "$A" ] || { err "No Albums metadata at $A (was part $ALBUMS_PART imported?)"; return 1; }
  mkdir -p "$ALBUMS_DIR"; touch "$ALBUMS_DIR/.nomedia"
  c "Reconstructing albums (Memories albums + hardlinked folders)"
  local tot=0
  for csv in "$A"/*.csv; do
    local name; name=$(basename "$csv" .csv)
    occ photos:albums:create "$NC_USER" "$name" >/dev/null 2>&1
    mkdir -p "$ALBUMS_DIR/$name"; local n=0
    while IFS= read -r img; do
      img=$(printf '%s' "$img" | tr -d '\r' | sed 's/^"//;s/"$//')
      [ -z "$img" ] && continue
      [ -f "$ICLOUD_DIR/$img" ] || continue
      occ photos:albums:add "$NC_USER" "$name" "${REL_ICLOUD}/$img" >/dev/null 2>&1
      ln -f "$ICLOUD_DIR/$img" "$ALBUMS_DIR/$name/$img" 2>/dev/null
      n=$((n+1))
    done < <(tail -n +2 "$csv")
    tot=$((tot+n)); c "   $name: $n"
  done
  occ files:scan --path="${NC_USER}/files/Albums" >/dev/null 2>&1
  _star_favorites "$A/Favorites.csv"
  c "ALBUMS DONE (added $tot file-memberships)"
}

_star_favorites(){
  local fav="$1"; [ -f "$fav" ] || return 0
  c "Starring Favorites (real Nextcloud favorite flag, powers /apps/memories/favorites)"
  local pfx; pfx=$(_dbget dbtableprefix); pfx=${pfx:-oc_}
  # ensure favorite tag exists for the user
  q "INSERT INTO ${pfx}vcategory (uid,type,category)
       SELECT '${NC_USER}','files','_\$!<Favorite>!\$_' FROM DUAL
       WHERE NOT EXISTS (SELECT 1 FROM ${pfx}vcategory
         WHERE uid='${NC_USER}' AND type='files' AND category='_\$!<Favorite>!\$_');"
  local cid; cid=$(q "SELECT id FROM ${pfx}vcategory WHERE uid='${NC_USER}' AND type='files' AND category='_\$!<Favorite>!\$_';")
  local n=0
  while IFS= read -r img; do
    img=$(printf '%s' "$img" | tr -d '\r' | sed 's/^"//;s/"$//'); [ -z "$img" ] && continue
    local fid; fid=$(q "SELECT fileid FROM ${pfx}filecache WHERE name='$(printf "%s" "$img" | sed "s/'/''/g")' LIMIT 1;")
    [ -z "$fid" ] && continue
    q "INSERT IGNORE INTO ${pfx}vcategory_to_object (objid,categoryid,type) VALUES ($fid,$cid,'files');"
    n=$((n+1))
  done < <(tail -n +2 "$fav")
  c "   starred $n favorites"
}

extras(){
  c "Geocoding (reverse-geocode GPS -> place names + map)"
  occ memories:places-setup -n | nostderr | tail -3
  c "Recognize (on-device AI faces + objects) -- installs + downloads models"
  occ app:install recognize >/dev/null 2>&1; occ app:enable recognize >/dev/null 2>&1
  occ recognize:download-models | nostderr | tail -2
  c "Preview Generator (pre-render thumbnails)"
  occ app:install previewgenerator >/dev/null 2>&1; occ app:enable previewgenerator >/dev/null 2>&1
  occ config:system:set preview_max_x --value=2048 >/dev/null
  occ config:system:set preview_max_y --value=2048 >/dev/null
  nohup $OCC preview:generate-all >/dev/null 2>&1 & disown
  c "extras done (Recognize classification + preview pre-gen continue via cron)"
}

crons(){
  c "Installing going-forward automation"
  ( crontab -l 2>/dev/null | grep -v "memories:index" | grep -v "autodate.py"
    echo "*/15 * * * * cd $(dirname "${OCC##* }") && ${OCC} memories:index >/dev/null 2>&1"
    echo "*/30 * * * * ICLOUD_DIR=$ICLOUD_DIR EXIFTOOL=$EXIFTOOL /usr/bin/python3 $WORK/lib/autodate.py >> $WORK/work/autodate.log 2>&1"
  ) | crontab -
  ICLOUD_DIR="$ICLOUD_DIR" EXIFTOOL="$EXIFTOOL" python3 "$WORK/lib/autodate.py" >/dev/null 2>&1   # init marker
  crontab -l | grep -E "memories:index|autodate"
  c "crons installed (index every 15m, filename-date fixup every 30m)"
}

status(){
  echo "library files : $(find "$ICLOUD_DIR" -type f 2>/dev/null | wc -l)"
  echo "library size  : $(du -sh "$ICLOUD_DIR" 2>/dev/null | cut -f1)"
  echo "memories rows : $(q "SELECT COUNT(*) FROM $(_dbget dbtableprefix)memories;")"
  echo "albums        : $(q "SELECT COUNT(*) FROM $(_dbget dbtableprefix)photos_albums WHERE \`user\`='${NC_USER}';")"
  echo "album folders : $(ls "$ALBUMS_DIR" 2>/dev/null | grep -v '^\.' | wc -l)"
}

watch(){
  c "watchdog: will restart 'import' if it dies before completion"
  ( while true; do sleep 120
      grep -q "IMPORT COMPLETE" "$LOG" 2>/dev/null && break
      pgrep -f "icloud2nc.sh import" >/dev/null || { c "import died -> restarting"; nohup "$0" import >>"$LOG" 2>&1 & disown; }
    done ) >/dev/null 2>&1 & disown
}

all(){ doctor; tools; download || true; import | tee -a "$LOG"; albums; extras; crons; status; }

# helpers expected next to this script (build_photo_dates.py, fix_video_dates.py, autodate.py)
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$WORK/lib"
for h in build_photo_dates.py fix_video_dates.py autodate.py; do
  [ -f "$SELF_DIR/$h" ] && cp -f "$SELF_DIR/$h" "$WORK/lib/$h"
done

cmd="${1:-help}"
case "$cmd" in
  doctor) doctor;;
  tools) tools;;
  download) shift; download "$@";;
  import) import | tee -a "$LOG";;
  albums) albums;;
  extras) extras;;
  crons) crons;;
  status) status;;
  watch) watch;;
  all) all;;
  *) sed -n '2,22p' "$0";;
esac
