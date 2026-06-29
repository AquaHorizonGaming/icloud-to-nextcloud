#!/bin/bash
# ============================================================================
#  icloud2nc  v2.0  -- all-in-one iCloud Photos -> Nextcloud/Memories migration
#  No args = interactive menu. Subcommands: doctor tools links download import
#  albums archive extras crons status verify report logs resume all
#  Every stage is resumable + logged. Safe to re-run. Edit the CONFIG block.
# ============================================================================
set -uo pipefail
VERSION="2.0"

# ============================== CONFIG ======================================
NC_USER="${NC_USER:-Aqua}"
NC_FILES="${NC_FILES:-/storage/${NC_USER}/files}"
ICLOUD_DIR="${ICLOUD_DIR:-${NC_FILES}/Icloud}"
ALBUMS_DIR="${ALBUMS_DIR:-${NC_FILES}/Albums}"
OCC="${OCC:-php ${HOME}/public_html/occ}"
WORK="${WORK:-${HOME}/icloud_migration}"
ALBUMS_PART="${ALBUMS_PART:-1}"
DB_HOST="${DB_HOST:-127.0.0.1}"; DB_PORT="${DB_PORT:-3306}"
ASSUME_YES="${ASSUME_YES:-0}"
# ============================================================================

EXIFTOOL="${WORK}/tools/bin/exiftool"
FFMPEG="${WORK}/tools/bin/ffmpeg"; FFPROBE="${WORK}/tools/bin/ffprobe"
EXIFTOOL_URL="${EXIFTOOL_URL:-https://exiftool.org/Image-ExifTool-13.30.tar.gz}"
FFMPEG_URL="${FFMPEG_URL:-https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz}"
STATE="${WORK}/state"; LOGDIR="${WORK}/logs"; LIBDIR="${WORK}/lib"
LOG="${LOGDIR}/icloud2nc-$(date +%Y%m%d).log"
LOCK="${WORK}/.lock"
REL_ICLOUD="${ICLOUD_DIR#${NC_FILES}/}"
FAVCAT='_$!<Favorite>!$_'
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
mkdir -p "$WORK/incoming" "$WORK/metadata" "$STATE" "$LOGDIR" "$LIBDIR" "$ICLOUD_DIR" 2>/dev/null

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[0m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; E=$'\033[1;31m'
else B=; R=; G=; Y=; C=; E=; fi
_ts(){ date +%H:%M:%S; }
log(){  printf '%s %s\n' "${C}[$(_ts)]${R}" "$*" | tee -a "$LOG"; }
ok(){   printf '%s %s\n' "${G}[$(_ts)] OK${R}" "$*" | tee -a "$LOG"; }
warn(){ printf '%s %s\n' "${Y}[$(_ts)] WARN${R}" "$*" | tee -a "$LOG"; }
err(){  printf '%s %s\n' "${E}[$(_ts)] ERROR${R}" "$*" | tee -a "$LOG" >&2; }
die(){ err "$*"; release_lock; exit 1; }
banner(){ printf '\n%s== %s ==%s\n' "$B" "$*" "$R" | tee -a "$LOG"; }
confirm(){ [ "$ASSUME_YES" = 1 ] && return 0; read -r -p "$* [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

acquire_lock(){ if mkdir "$LOCK" 2>/dev/null; then echo $$ >"$LOCK/pid"; trap release_lock EXIT INT TERM
  else local p; p=$(cat "$LOCK/pid" 2>/dev/null); if kill -0 "$p" 2>/dev/null; then die "another run active (pid $p); remove $LOCK if stale"; else rm -rf "$LOCK"; acquire_lock; fi; fi; }
release_lock(){ rm -rf "$LOCK" 2>/dev/null; }

done_mark(){ [ -f "$STATE/$1.done" ]; }
mark(){ date +%s >"$STATE/$1.done"; }
fmt_dur(){ local s=$1; printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60)); }
stage(){ local key="$1" label="$2" est="$3" fn="$4"
  if done_mark "$key" && [ "${FORCE:-0}" != 1 ]; then warn "skip '$label' (done; FORCE=1 to redo)"; return 0; fi
  banner "$label  (~$est)"; local t0; t0=$(date +%s); "$fn"; local rc=$?; local dt=$(( $(date +%s)-t0 ))
  if [ $rc -eq 0 ]; then mark "$key"; ok "$label finished in $(fmt_dur $dt)"; else err "$label failed (rc=$rc)"; fi; return $rc; }

occ(){ $OCC "$@" 2>/dev/null; }
nostderr(){ grep -viE "PHP Warning|raphf|GEOSGeometry|arginfo|imagick|Deprecated"; }
_dbget(){ $OCC config:system:get "$1" 2>/dev/null; }
PFX_CACHE=""; pfx(){ [ -z "$PFX_CACHE" ] && PFX_CACHE="$(_dbget dbtableprefix)"; echo "${PFX_CACHE:-oc_}"; }
q(){ local u pw n; u=$(_dbget dbuser); pw=$(_dbget dbpassword); n=$(_dbget dbname)
  mysql -h"$DB_HOST" -P"$DB_PORT" -u"$u" -p"$pw" "$n" -N -e "$1" 2>/dev/null; }

gb(){ awk "BEGIN{printf \"%.1f\", $1/1073741824}"; }
free_gb(){ df -PB1 "$1" 2>/dev/null | awk 'NR==2{printf "%.0f",$4/1073741824}'; }
count_zip(){ ls "$WORK"/incoming/*.zip 2>/dev/null | wc -l; }
lib_files(){ find "$ICLOUD_DIR" -type f 2>/dev/null | wc -l; }
sync_helpers(){ local d; d=$(dirname "$SELF"); for h in build_photo_dates.py fix_video_dates.py autodate.py; do
  [ -f "$d/$h" ] && cp -f "$d/$h" "$LIBDIR/$h"; done; }

doctor(){ local fail=0
  echo "  tool version : icloud2nc v$VERSION"
  $OCC status >/dev/null 2>&1 || { err "occ not runnable as: $OCC"; fail=1; }
  echo "  nextcloud    : $(occ status | grep versionstring | awk -F: '{print $2}' | tr -d ' ')"
  occ user:info "$NC_USER" >/dev/null 2>&1 && echo "  user '$NC_USER' : exists" || { warn "user '$NC_USER' missing"; fail=1; }
  [ -d "$NC_FILES" ] || { warn "NC_FILES not found: $NC_FILES"; fail=1; }
  local enc; enc=$(occ encryption:status | grep -i 'enabled:' | awk '{print $NF}')
  if [ "$enc" = "true" ]; then err "server-side encryption is ON -> Memories video transcoding breaks & direct placement fails"
    echo "    fix (BACK UP FIRST): occ encryption:decrypt-all ; occ encryption:disable ; occ app:disable encryption"; fail=1
  else echo "  encryption   : off (good)"; fi
  occ app:list 2>/dev/null | grep -q ' memories:' && echo "  memories app : installed" || warn "memories app not installed"
  echo "  bg jobs mode : $(occ config:app:get core backgroundjobs_mode)  (want: cron)"
  echo "  exiftool     : $([ -x "$EXIFTOOL" ] && "$EXIFTOOL" -ver || echo 'missing -> run: tools')"
  echo "  ffmpeg       : $([ -x "$FFMPEG" ] && echo ok || echo 'missing -> run: tools')"
  echo "  data free    : $(free_gb "$NC_FILES") GB"
  echo "  GPU /dev/dri : $([ -d /dev/dri ] && echo yes || echo 'none (software transcode; fine on many cores)')"
  [ $fail -eq 0 ] && ok "preflight passed" || warn "preflight found issues (above)"; return 0; }

tools(){
  if command -v exiftool >/dev/null 2>&1; then ln -sf "$(command -v exiftool)" "$EXIFTOOL"
  elif [ ! -x "$EXIFTOOL" ]; then log "fetching exiftool from exiftool.org"
    mkdir -p "$WORK/tools/bin"
    curl -fsSL -o "$WORK/tools/et.tgz" "$EXIFTOOL_URL" || die "exiftool download failed (set EXIFTOOL_URL)"
    tar -xzf "$WORK/tools/et.tgz" -C "$WORK/tools"
    local ed; ed=$(find "$WORK/tools" -maxdepth 1 -type d -name 'Image-ExifTool-*' | head -1)
    ln -sf "$ed/exiftool" "$EXIFTOOL"; rm -f "$WORK/tools/et.tgz"; fi
  if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    ln -sf "$(command -v ffmpeg)" "$FFMPEG"; ln -sf "$(command -v ffprobe)" "$FFPROBE"
  elif [ ! -x "$FFMPEG" ]; then log "fetching static ffmpeg/ffprobe"
    mkdir -p "$WORK/tools/bin"
    curl -fsSL -o "$WORK/tools/ff.tar.xz" "$FFMPEG_URL" || die "ffmpeg download failed (set FFMPEG_URL)"
    tar -xf "$WORK/tools/ff.tar.xz" -C "$WORK/tools"
    local fd; fd=$(find "$WORK/tools" -maxdepth 1 -type d -name 'ffmpeg-*static*' | head -1)
    cp "$fd/ffmpeg" "$fd/ffprobe" "$WORK/tools/bin/"; rm -rf "$WORK/tools/ff.tar.xz" "$fd"; fi
  "$EXIFTOOL" -ver >/dev/null && "$FFMPEG" -version >/dev/null || die "tool self-test failed"
  occ config:system:set preview_ffmpeg_path --value="$FFMPEG" >/dev/null
  occ config:system:set memories.vod.ffmpeg --value="$FFMPEG" >/dev/null
  occ config:system:set memories.vod.ffprobe --value="$FFPROBE" >/dev/null
  ok "exiftool $($EXIFTOOL -ver) + ffmpeg ready and wired into Memories"; }

links(){ cat <<'EOF'
Collect all part links without 21 manual copies:
  1. Log in to https://privacy.apple.com yourself (Apple password + 2FA -- only you can).
  2. Open the data-download page listing the "iCloud Photos Part N" files.
  3. DevTools (F12) -> Console -> paste get_links.js (included with this tool) -> Enter.
  4. Save the printed lines to ~/icloud_migration/parts.txt, then run: download
NOTE: Apple links expire within minutes; download right away.
The Apple login is never automated: it needs your password + 2FA, and scripting
Apple ID sign-in violates Apple's terms and can lock your account.
EOF
}

download(){ local list="${1:-$WORK/parts.txt}"
  [ -f "$list" ] || die "create $list with lines: <part-number> <url>  (see: links)"
  cd "$WORK/incoming"; local n=0
  while read -r num url; do [ -z "${num:-}" ] && continue; case "$num" in \#*) continue;; esac
    log "download part $num"; nohup curl -sL -o "iCloud Photos Part ${num} of 21.zip" "$url" >/dev/null 2>&1 & n=$((n+1)); done < "$list"
  disown -a; ok "$n downloads started + detached (survive disconnect). Watch: ls -lah $WORK/incoming"; }

verify_zips(){ local bad=0; shopt -s nullglob
  for z in "$WORK"/incoming/*.zip; do unzip -l "$z" >/dev/null 2>&1 || { warn "bad/incomplete: $(basename "$z")"; bad=$((bad+1)); }; done
  [ $bad -gt 0 ] && warn "$bad zip(s) look bad -- re-download those parts"; return 0; }

_extract(){ verify_zips; shopt -s nullglob
  local need=0; for z in "$WORK"/incoming/*.zip; do need=$((need + $(stat -c%s "$z"))); done
  log "extracting $(count_zip) parts (~$(gb $need) GB); $(free_gb "$NC_FILES") GB free"
  for z in "$WORK"/incoming/*.zip; do
    unzip -l "$z" >/dev/null 2>&1 || { warn "skip bad zip: $(basename "$z")"; continue; }
    local pn; pn=$(basename "$z" | grep -oE 'Part [0-9]+' | grep -oE '[0-9]+'); pn=${pn:-x}
    mkdir -p "$WORK/metadata/part${pn}"
    unzip -Cojo "$z" "*/Photos/Photo Details*.csv" -d "$WORK/metadata/part${pn}" >/dev/null 2>&1
    unzip -Cojo "$z" "*/Photos/*" -x "*/Photos/Photo Details*.csv" -d "$ICLOUD_DIR" >/dev/null 2>&1
    unzip -Cojo "$z" "*/Albums/*" -d "$WORK/metadata/Albums" >/dev/null 2>&1
    log "   part $pn done (library now $(lib_files) files)"
  done; }

import(){ sync_helpers; _extract
  log "restoring photo EXIF dates (single exiftool batch)"
  OUT_CSV="$WORK/metadata/photo_exif.csv" METADATA_DIR="$WORK/metadata" ICLOUD_DIR="$ICLOUD_DIR" python3 "$LIBDIR/build_photo_dates.py" | tee -a "$LOG"
  [ -s "$WORK/metadata/photo_exif.csv" ] && "$EXIFTOOL" -q -m -overwrite_original -csv="$WORK/metadata/photo_exif.csv" "$ICLOUD_DIR" 2>&1 | tail -2 | tee -a "$LOG"
  log "fixing video dates (fast mtime method)"
  METADATA_DIR="$WORK/metadata" ICLOUD_DIR="$ICLOUD_DIR" python3 "$LIBDIR/fix_video_dates.py" | tee -a "$LOG"
  log "files:scan"; occ files:scan --path="${NC_USER}/files/${REL_ICLOUD}" | nostderr | tail -4 | tee -a "$LOG"
  log "memories:index"; occ memories:index | nostderr | tail -3 | tee -a "$LOG"
  ok "library imported: $(lib_files) files, $(du -sh "$ICLOUD_DIR" 2>/dev/null | cut -f1)"; }

albums(){ local A="$WORK/metadata/Albums"; [ -d "$A" ] || die "no Albums metadata at $A"
  mkdir -p "$ALBUMS_DIR"; touch "$ALBUMS_DIR/.nomedia"; local tot=0 na=0
  for csv in "$A"/*.csv; do local name; name=$(basename "$csv" .csv)
    occ photos:albums:create "$NC_USER" "$name" >/dev/null 2>&1; mkdir -p "$ALBUMS_DIR/$name"; na=$((na+1)); local n=0
    while IFS= read -r img; do img=$(printf '%s' "$img" | tr -d '\r' | sed 's/^"//;s/"$//'); [ -z "$img" ] && continue
      [ -f "$ICLOUD_DIR/$img" ] || continue
      occ photos:albums:add "$NC_USER" "$name" "${REL_ICLOUD}/$img" >/dev/null 2>&1
      ln -f "$ICLOUD_DIR/$img" "$ALBUMS_DIR/$name/$img" 2>/dev/null; n=$((n+1)); done < <(tail -n +2 "$csv")
    tot=$((tot+n)); log "   $name: $n"; done
  occ files:scan --path="${NC_USER}/files/Albums" >/dev/null 2>&1
  _star_favorites "$A/Favorites.csv"
  ok "albums done: $na albums (Memories + folders), $tot memberships"; }

_star_favorites(){ local fav="$1"; [ -f "$fav" ] || return 0; local P; P=$(pfx)
  q "INSERT INTO ${P}vcategory (uid,type,category) SELECT '${NC_USER}','files','$FAVCAT' FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM ${P}vcategory WHERE uid='${NC_USER}' AND type='files' AND category='$FAVCAT');"
  local cid; cid=$(q "SELECT id FROM ${P}vcategory WHERE uid='${NC_USER}' AND type='files' AND category='$FAVCAT';")
  local n=0; while IFS= read -r img; do img=$(printf '%s' "$img"|tr -d '\r'|sed 's/^"//;s/"$//'); [ -z "$img" ] && continue
    local nm fid; nm=$(printf %s "$img" | sed "s/'/''/g"); fid=$(q "SELECT fileid FROM ${P}filecache WHERE name='$nm' LIMIT 1;"); [ -z "$fid" ] && continue
    q "INSERT IGNORE INTO ${P}vcategory_to_object (objid,categoryid,type) VALUES ($fid,$cid,'files');"; n=$((n+1)); done < <(tail -n +2 "$fav")
  ok "starred $n favorites (powers /apps/memories/favorites)"; }

archive(){ local hid="$WORK/metadata/Albums/Hidden.csv"; [ -f "$hid" ] || die "no Hidden.csv"
  confirm "Move Hidden items OUT of the main timeline into $ALBUMS_DIR/Hidden ?" || { warn "cancelled"; return 0; }
  mkdir -p "$ALBUMS_DIR/Hidden"; touch "$ALBUMS_DIR/.nomedia"; local n=0
  while IFS= read -r img; do img=$(printf '%s' "$img"|tr -d '\r'|sed 's/^"//;s/"$//'); [ -z "$img" ] && continue
    [ -f "$ICLOUD_DIR/$img" ] && { mv -f "$ICLOUD_DIR/$img" "$ALBUMS_DIR/Hidden/$img"; n=$((n+1)); }; done < <(tail -n +2 "$hid")
  occ files:scan --path="${NC_USER}/files" >/dev/null 2>&1; occ memories:index >/dev/null 2>&1
  ok "archived $n Hidden items out of the timeline"; }

extras(){
  log "geocoding (GPS -> place names + map)"; occ memories:places-setup -n | nostderr | tail -2 | tee -a "$LOG"
  log "Recognize (AI faces + objects)"; occ app:install recognize >/dev/null 2>&1; occ app:enable recognize >/dev/null 2>&1
  occ recognize:download-models | nostderr | tail -2 | tee -a "$LOG"
  log "Preview Generator"; occ app:install previewgenerator >/dev/null 2>&1; occ app:enable previewgenerator >/dev/null 2>&1
  occ config:system:set preview_max_x --value=2048 >/dev/null; occ config:system:set preview_max_y --value=2048 >/dev/null
  nohup $OCC preview:generate-all >/dev/null 2>&1 & disown
  ok "extras configured (AI + preview pre-gen continue in background)"; }

crons(){ sync_helpers; local occdir; occdir=$(dirname "${OCC##* }")
  ( crontab -l 2>/dev/null | grep -v "memories:index" | grep -v "autodate.py"
    echo "*/15 * * * * cd $occdir && ${OCC} memories:index >/dev/null 2>&1"
    echo "*/30 * * * * ICLOUD_DIR=$ICLOUD_DIR EXIFTOOL=$EXIFTOOL /usr/bin/python3 $LIBDIR/autodate.py >> $LOGDIR/autodate.log 2>&1" ) | crontab -
  ICLOUD_DIR="$ICLOUD_DIR" EXIFTOOL="$EXIFTOOL" python3 "$LIBDIR/autodate.py" >/dev/null 2>&1
  ok "automation installed (index /15m, filename-date fixup /30m)"; crontab -l | grep -E "memories:index|autodate"; }

status(){ local P na nf nfav; P=$(pfx)
  na=$(q "SELECT COUNT(*) FROM ${P}photos_albums a WHERE a.user='${NC_USER}';")
  nf=$(ls "$ALBUMS_DIR" 2>/dev/null | grep -v '^\.' | wc -l)
  nfav=$(q "SELECT COUNT(*) FROM ${P}vcategory_to_object o JOIN ${P}vcategory c ON o.categoryid=c.id WHERE c.uid='${NC_USER}' AND c.category='$FAVCAT';")
  echo "  library files : $(lib_files)"
  echo "  library size  : $(du -sh "$ICLOUD_DIR" 2>/dev/null | cut -f1)"
  echo "  memories rows : $(q "SELECT COUNT(*) FROM ${P}memories;")"
  echo "  albums        : $na"
  echo "  album folders : $nf"
  echo "  favorites     : $nfav"
  echo "  data free     : $(free_gb "$NC_FILES") GB"; }

verify(){ local P items today na nf dups nfav; P=$(pfx); banner "Integrity check"
  items=$(q "SELECT COUNT(*) FROM ${P}memories;"); today=$(q "SELECT COUNT(*) FROM ${P}memories WHERE datetaken >= CURDATE();")
  na=$(q "SELECT COUNT(*) FROM ${P}photos_albums a WHERE a.user='${NC_USER}';")
  nf=$(ls "$ALBUMS_DIR" 2>/dev/null | grep -v '^\.' | wc -l)
  dups=$(q "SELECT COUNT(*) FROM (SELECT a.name FROM ${P}photos_albums a WHERE a.user='${NC_USER}' GROUP BY a.name HAVING COUNT(*)>1) x;")
  nfav=$(q "SELECT COUNT(*) FROM ${P}vcategory_to_object o JOIN ${P}vcategory c ON o.categoryid=c.id WHERE c.uid='${NC_USER}' AND c.category='$FAVCAT';")
  echo "  indexed items        : $items"
  echo "  dated 'today' (review): $today"
  echo "  Memories albums      : $na"
  echo "  /Albums folders      : $nf"
  echo "  duplicate albums     : $dups"
  echo "  favorites starred    : $nfav"
  q "SELECT a.name FROM ${P}photos_albums a WHERE a.user='${NC_USER}';" 2>/dev/null | sort > /tmp/_a.txt
  ls "$ALBUMS_DIR" 2>/dev/null | grep -v '^\.' | sort > /tmp/_f.txt
  if diff -q /tmp/_a.txt /tmp/_f.txt >/dev/null 2>&1; then ok "albums and folders match name-for-name"
  else warn "album/folder differences:"; diff /tmp/_a.txt /tmp/_f.txt | head; fi; }

report(){ local f="${WORK}/migration-report.md"; { echo "# iCloud -> Nextcloud migration report"; echo; echo "_$(date)_"; echo
  echo '## Library'; status; echo; echo '## Integrity'; verify; } > "$f" 2>/dev/null; ok "report written: $f"; }

logs(){ tail -n "${1:-40}" "$LOG"; }

resume(){ acquire_lock; sync_helpers
  stage import "Import media" "1-3h" import || true
  stage albums "Reconstruct albums" "30-40m" albums || true
  stage extras "Geocoding + AI + previews" "minutes" extras || true
  stage crons  "Going-forward automation" "seconds" crons || true
  release_lock; status; }

all(){ acquire_lock; sync_helpers
  banner "icloud2nc v$VERSION -- full migration"
  echo "${Y}Rough timings: download (bandwidth) | import ~1-3h | albums ~30-40m | extras minutes${R}"
  doctor
  confirm "Proceed with the full run?" || { warn "aborted"; release_lock; exit 0; }
  done_mark tools || stage tools "Install tools" "1-2m" tools || true
  if [ -f "$WORK/parts.txt" ]; then stage download "Download parts" "bandwidth-bound" download || true
  else warn "no parts.txt -> skipping download (add links, run 'download')"; fi
  stage import "Import media" "1-3h" import || true
  stage albums "Reconstruct albums" "30-40m" albums || true
  stage extras "Geocoding + AI + previews" "minutes" extras || true
  stage crons  "Going-forward automation" "seconds" crons || true
  release_lock; banner "DONE"; status; }

menu(){ while true; do
  printf '\n%sicloud2nc v%s%s   user=%s  lib=%s files\n' "$B" "$VERSION" "$R" "$NC_USER" "$(lib_files)"
  cat <<'M'
  1) doctor    2) tools    3) links    4) download   5) import
  6) albums    7) extras   8) crons    9) status    10) verify
 11) report   12) all      q) quit
M
  read -r -p "choose: " ch; case "$ch" in
    1) doctor;; 2) acquire_lock; tools; release_lock;; 3) links;; 4) acquire_lock; download; release_lock;;
    5) acquire_lock; import; release_lock;; 6) acquire_lock; albums; release_lock;; 7) acquire_lock; extras; release_lock;;
    8) crons;; 9) status;; 10) verify;; 11) report;; 12) all;; q|Q) break;; *) warn "?";; esac
  done; }

usage(){ sed -n '2,8p' "$0"; }

case "${1:-menu}" in
  doctor) doctor;; tools) acquire_lock; tools; release_lock;; links) links;;
  download) shift; acquire_lock; download "$@"; release_lock;;
  import) acquire_lock; import; release_lock;; albums) acquire_lock; albums; release_lock;;
  archive) acquire_lock; archive; release_lock;; extras) acquire_lock; extras; release_lock;;
  crons) crons;; status) status;; verify) verify;; report) report;; logs) shift; logs "${1:-40}";;
  resume) resume;; all) all;; menu) menu;; help|-h|--help) usage;; *) err "unknown: $1"; usage;;
esac
