#!/bin/bash
# ============================================================================
#  icloud2nc  v2.5  -- all-in-one iCloud Photos + Drive -> Nextcloud/Memories
#  No args = interactive menu. Subcommands: doctor tools links download pull
#  import albums archive extras crons status verify report logs resume all drive
#  accounts = manage multiple Nextcloud accounts and pick the migration target
#  autopull = schedule icloudpd to auto-fetch NEW photos into the right account
#  Two ways to GET photos: (1) privacy.apple.com export -> download, or
#  (2) pull = direct download via icloudpd (interactive Apple login).
#  Photos land in /Photos (Memories); iCloud Drive docs land in /Files/iCloud.
#  Every stage is resumable + logged. Safe to re-run. Edit the CONFIG block.
# ============================================================================
set -uo pipefail
VERSION="2.5"
[ -f "${ICLOUD2NC_CONF:-$HOME/.config/icloud2nc.conf}" ] && . "${ICLOUD2NC_CONF:-$HOME/.config/icloud2nc.conf}"

# ---- multi-account: load the selected account profile (sets NC_USER etc.) ---
CONF_DIR="${CONF_DIR:-$HOME/.config/icloud2nc}"; ACCT_DIR="$CONF_DIR/accounts"; CURRENT_FILE="$CONF_DIR/current"
mkdir -p "$ACCT_DIR" 2>/dev/null
ACTIVE_ACCT=""
if [ -n "${ICLOUD2NC_ACCOUNT:-}" ] && [ -f "$ACCT_DIR/${ICLOUD2NC_ACCOUNT}.conf" ]; then
  ACTIVE_ACCT="$ICLOUD2NC_ACCOUNT"; . "$ACCT_DIR/${ICLOUD2NC_ACCOUNT}.conf"
elif [ -f "$CURRENT_FILE" ]; then ACTIVE_ACCT="$(cat "$CURRENT_FILE" 2>/dev/null)"
  [ -n "$ACTIVE_ACCT" ] && [ -f "$ACCT_DIR/$ACTIVE_ACCT.conf" ] && . "$ACCT_DIR/$ACTIVE_ACCT.conf"
fi

# ============================== CONFIG ======================================
NC_USER="${NC_USER:-Aqua}"
NC_FILES="${NC_FILES:-/storage/${NC_USER}/files}"
ICLOUD_DIR="${ICLOUD_DIR:-${NC_FILES}/Photos/Icloud}"
ALBUMS_DIR="${ALBUMS_DIR:-${NC_FILES}/Photos/Albums}"
FILES_DIR="${FILES_DIR:-${NC_FILES}/Files}"
DRIVE_DIR="${DRIVE_DIR:-${FILES_DIR}/iCloud}"
OCC="${OCC:-php ${HOME}/public_html/occ}"
WORK="${WORK:-${HOME}/icloud_migration}"
ALBUMS_PART="${ALBUMS_PART:-1}"
DB_HOST="${DB_HOST:-127.0.0.1}"; DB_PORT="${DB_PORT:-3306}"
ASSUME_YES="${ASSUME_YES:-0}"
APPLE_ID="${APPLE_ID:-}"
ICLOUDPD_OPTS="${ICLOUDPD_OPTS:-}"
AUTOPULL_CRON="${AUTOPULL_CRON:-0 */6 * * *}"   # how often autopull checks iCloud
ICLOUDPD_UNTIL="${ICLOUDPD_UNTIL:-100}"        # incremental: stop after N already-downloaded
# ============================================================================

EXIFTOOL="${WORK}/tools/bin/exiftool"
FFMPEG="${WORK}/tools/bin/ffmpeg"; FFPROBE="${WORK}/tools/bin/ffprobe"
EXIFTOOL_URL="${EXIFTOOL_URL:-https://exiftool.org/Image-ExifTool-13.30.tar.gz}"
FFMPEG_URL="${FFMPEG_URL:-https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz}"
STATE="${WORK}/state"; LOGDIR="${WORK}/logs"; LIBDIR="${WORK}/lib"
LOG="${LOGDIR}/icloud2nc-$(date +%Y%m%d).log"
LOCK="${WORK}/.lock"
REL_ICLOUD="${ICLOUD_DIR#${NC_FILES}/}"
REL_FILES="${FILES_DIR#${NC_FILES}/}"
DRIVE_INCOMING="${DRIVE_INCOMING:-${WORK}/drive_incoming}"
ICLOUDPD_BIN="${ICLOUDPD_BIN:-icloudpd}"
ICLOUDPD_VENV="${ICLOUDPD_VENV:-${WORK}/tools/icloudpd-venv}"
GETPIP_URL="${GETPIP_URL:-https://bootstrap.pypa.io/get-pip.py}"
ICLOUDPD_COOKIES="${ICLOUDPD_COOKIES:-${WORK}/tools/icloudpd-cookies}"
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
maybe(){ if [ "${DRY:-0}" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

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
  echo "  icloudpd     : $(_icloudpd_resolve && "$ICLOUDPD_BIN" --version 2>/dev/null | head -1 || echo 'not installed (auto-installs on first: pull)')"
  echo "  data free    : $(free_gb "$NC_FILES") GB"
  echo "  GPU /dev/dri : $([ -d /dev/dri ] && echo yes || echo 'none (software transcode; fine on many cores)')"
  echo "  php mem_limit: $(php -r 'echo ini_get("memory_limit");' 2>/dev/null)"
  echo "  memcache     : $(_dbget memcache.local || echo 'unset (set \OC\Memcache\APCu for speed)')"
  occ maintenance:mode 2>/dev/null | grep -qi 'enabled: *true' && warn "maintenance mode is ON (occ maintenance:mode --off)"
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
TIP: prefer a live login? use 'pull' (icloudpd) instead of the export+download path.
EOF
}

download(){ local list="${1:-$WORK/parts.txt}"
  [ -f "$list" ] || die "create $list with lines: <part-number> <url>  (see: links)"
  cd "$WORK/incoming"; local n=0
  while read -r num url; do [ -z "${num:-}" ] && continue; case "$num" in \#*) continue;; esac
    log "download part $num"; nohup curl -sL -o "iCloud Photos Part ${num} of 21.zip" "$url" >/dev/null 2>&1 & n=$((n+1)); done < "$list"
  disown -a; ok "$n downloads started + detached (survive disconnect). Watch: ls -lah $WORK/incoming"; }

# Direct download from iCloud using icloud_photos_downloader (icloudpd):
#   https://github.com/icloud-photos-downloader/icloud_photos_downloader
# An ALTERNATIVE to the privacy.apple.com export path. You authenticate
# interactively: icloudpd prompts for your Apple password + 2FA. This tool
# never stores or reads your credentials -- auth is between you and Apple.
# Re-run any time to resume / fetch new photos (a session cookie is cached).
_icloudpd_resolve(){ local c
  for c in "$WORK/tools/bin/icloudpd" "$ICLOUDPD_VENV/bin/icloudpd" "$HOME/.local/bin/icloudpd" "$(command -v icloudpd 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { ICLOUDPD_BIN="$c"; return 0; }
  done; return 1; }

# Make icloudpd "just be there" on any box -- including minimized / PEP 668
# images with no pip, no ensurepip, no sudo. Strategy: reuse an existing binary;
# else a quick "pip --user"; else build an isolated venv and bootstrap pip into
# it from get-pip.py (no system changes, no --break-system-packages).
_icloudpd_install(){
  if _icloudpd_resolve && "$ICLOUDPD_BIN" --version >/dev/null 2>&1; then return 0; fi
  log "installing icloudpd (isolated venv; no root, no system changes)"
  if python3 -m pip --version >/dev/null 2>&1; then
    python3 -m pip install --user --upgrade icloudpd >/dev/null 2>&1 && _icloudpd_resolve \
      && { ok "icloudpd ready: $($ICLOUDPD_BIN --version 2>/dev/null | head -1)"; return 0; }
  fi
  mkdir -p "$WORK/tools/bin"; rm -rf "$ICLOUDPD_VENV"
  python3 -m venv --without-pip "$ICLOUDPD_VENV" 2>/dev/null || python3 -m venv "$ICLOUDPD_VENV" 2>/dev/null || true
  [ -x "$ICLOUDPD_VENV/bin/python" ] || die "could not create a python venv (need the python3-venv module)"
  if ! "$ICLOUDPD_VENV/bin/python" -m pip --version >/dev/null 2>&1; then
    curl -fsSL -o "$WORK/tools/get-pip.py" "$GETPIP_URL" || die "could not download get-pip.py ($GETPIP_URL)"
    "$ICLOUDPD_VENV/bin/python" "$WORK/tools/get-pip.py" >/dev/null 2>&1 || die "pip bootstrap into venv failed"
  fi
  "$ICLOUDPD_VENV/bin/python" -m pip install --upgrade icloudpd >/dev/null 2>&1 || die "icloudpd install failed (pip)"
  ln -sf "$ICLOUDPD_VENV/bin/icloudpd" "$WORK/tools/bin/icloudpd"
  _icloudpd_resolve || die "icloudpd installed but binary not found"
  ok "icloudpd ready: $($ICLOUDPD_BIN --version 2>/dev/null | head -1)"; }

pull(){
  _icloudpd_install
  local id="" auto=0 a
  for a in "$@"; do case "$a" in --auto) auto=1;; --*) ICLOUDPD_OPTS="${ICLOUDPD_OPTS:-} $a";; *) [ -z "$id" ] && id="$a";; esac; done
  [ -n "$id" ] || id="$APPLE_ID"
  if [ -z "$id" ]; then
    [ "$auto" = 1 ] && { warn "autopull: no Apple ID stored for '$NC_USER' (set one via: accounts add)"; return 0; }
    read -r -p "Apple ID (email): " id
  fi
  [ -n "$id" ] || die "no Apple ID given (set APPLE_ID, or run: pull you@example.com)"
  mkdir -p "$ICLOUD_DIR"
  banner "icloudpd -> $ICLOUD_DIR  (account: $NC_USER)"
  if [ "$auto" = 1 ]; then
    log "autopull (incremental, --until-found $ICLOUDPD_UNTIL) for $NC_USER as $id"
    "$ICLOUDPD_BIN" --directory "$ICLOUD_DIR" --username "$id" --size original --live-photo-size original --set-exif-datetime --folder-structure none --no-progress-bar --until-found "$ICLOUDPD_UNTIL" ${ICLOUDPD_OPTS:-} </dev/null || { warn "icloudpd auto run failed -- the iCloud session likely expired; run 'pull' interactively once to re-auth (2FA)"; return 0; }
  else
    warn "icloudpd will prompt for your Apple password + 2FA in THIS terminal."
    warn "This tool does not store or read your credentials; auth is between you and Apple."
    "$ICLOUDPD_BIN" --directory "$ICLOUD_DIR" --username "$id" --size original --live-photo-size original --set-exif-datetime --folder-structure none --no-progress-bar ${ICLOUDPD_OPTS:-} || warn "icloudpd exited non-zero (auth/network/interrupt) -- safe to re-run; it resumes"
  fi
  log "files:scan"; occ files:scan --path="${NC_USER}/files/${REL_ICLOUD}" | nostderr | tail -4 | tee -a "$LOG"
  log "memories:index"; occ memories:index | nostderr | tail -3 | tee -a "$LOG"
  ok "icloudpd sync complete: $(lib_files) files in $ICLOUD_DIR (already dated). Albums/Favorites need the export path."; }

# Schedule icloudpd to AUTO-fetch new photos into each account that has an Apple
# ID stored. Reuses the session cookie from your interactive 'pull' (no password
# is stored). New photos land in that account's Photos/Icloud, dated + indexed.
autopull(){ local action="${1:-on}"; local tag="# icloud2nc-autopull"
  case "$action" in
    on|install|enable)
      local lines n=0 fcfg name aid
      lines="$(crontab -l 2>/dev/null | grep -v "$tag")"
      shopt -s nullglob
      for fcfg in "$ACCT_DIR"/*.conf; do
        name=$(basename "$fcfg" .conf); aid=$(. "$fcfg"; echo "${APPLE_ID:-}")
        [ -n "$aid" ] || continue
        lines="$(printf '%s\n%s ICLOUD2NC_ACCOUNT=%s %s pull --auto >> %s/autopull-%s.log 2>&1 %s' "$lines" "$AUTOPULL_CRON" "$name" "$SELF" "$LOGDIR" "$name" "$tag")"
        n=$((n+1)); log "   scheduled autopull for '$name' ($aid)"
      done
      if [ "$n" = 0 ] && [ -n "$APPLE_ID" ]; then
        lines="$(printf '%s\n%s %s pull --auto >> %s/autopull.log 2>&1 %s' "$lines" "$AUTOPULL_CRON" "$SELF" "$LOGDIR" "$tag")"; n=1; log "   scheduled autopull for the default account"
      fi
      [ "$n" -gt 0 ] || { warn "no account has an Apple ID set -- run 'accounts add' (it asks for Apple ID), then re-run 'autopull on'."; return 0; }
      printf '%s\n' "$lines" | crontab -
      ok "autopull installed for $n account(s); schedule: $AUTOPULL_CRON"
      echo "  It reuses the icloudpd session from your interactive 'pull'."
      echo "  When Apple expires the session, run 'pull' once (interactively) to re-auth.";;
    off|remove|disable)
      crontab -l 2>/dev/null | grep -v "$tag" | crontab - 2>/dev/null; ok "autopull schedule removed";;
    status|list)
      banner "autopull schedule"; crontab -l 2>/dev/null | grep "$tag" || echo "  (not installed)";;
    run) shift; pull --auto "$@";;
    *) echo "usage: autopull [on | off | status]";;
  esac; }

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
  occ files:scan --path="${NC_USER}/files/Photos/Albums" >/dev/null 2>&1
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
  else warn "no parts.txt -> skipping download (add links, run 'download'; or use 'pull')"; fi
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
 11) report   12) all     13) backup   14) dedupe   15) faces
 16) hwaccel  17) contacts 18) calendars 19) prune  20) clean
 21) drive (iCloud Drive -> Files)  22) pull (icloudpd)  23) accounts (add/switch)
 24) autopull (auto-sync new photos)                     q) quit
M
  read -r -p "choose: " ch; case "$ch" in
    1) doctor;; 2) acquire_lock; tools; release_lock;; 3) links;; 4) acquire_lock; download; release_lock;;
    5) acquire_lock; import; release_lock;; 6) acquire_lock; albums; release_lock;; 7) acquire_lock; extras; release_lock;;
    8) crons;; 9) status;; 10) verify;; 11) report;; 12) all;;
    13) acquire_lock; backup; release_lock;; 14) acquire_lock; dedupe; release_lock;; 15) faces;;
    16) hwaccel;; 17) contacts;; 18) calendars;; 19) acquire_lock; prune; release_lock;; 20) clean;;
    21) acquire_lock; drive; release_lock;; 22) acquire_lock; pull; release_lock;;
    23) _accounts_interactive;;
    24) autopull status; read -r -p "autopull [o]n / o[f]f / [Enter]=back: " x; case "$x" in o|O) autopull on;; f|F) autopull off;; esac;;
    q|Q) break;; *) warn "?";; esac
  done; }

usage(){ sed -n '2,10p' "$0"; }

backup(){ local d="$WORK/backups/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$d"
  log "backing up DB + config -> $d"
  local u pw n; u=$(_dbget dbuser); pw=$(_dbget dbpassword); n=$(_dbget dbname)
  mysqldump --single-transaction --no-tablespaces -h"$DB_HOST" -P"$DB_PORT" -u"$u" -p"$pw" "$n" > "$d/nextcloud-db.sql" 2>/dev/null \
    && ok "DB -> $d/nextcloud-db.sql ($(du -h "$d/nextcloud-db.sql"|cut -f1))" || warn "DB dump failed"
  cp -f "$(dirname "${OCC##* }")/config/config.php" "$d/" 2>/dev/null
  [ -d "$WORK/metadata/Albums" ] && cp -rf "$WORK/metadata/Albums" "$d/albums-metadata"
  ok "backup complete: $d"; }

dedupe(){ banner "Duplicate scan (by content hash)"; local tmp; tmp=$(mktemp)
  log "hashing library (this can take a while on large sets)"
  find "$ICLOUD_DIR" -type f -exec md5sum {} + 2>/dev/null | sort > "$tmp"
  local groups extra; groups=$(awk '{print $1}' "$tmp" | uniq -d | wc -l)
  extra=$(awk '{print $1}' "$tmp" | uniq -dc | awk '{s+=$1-1} END{print s+0}')
  echo "  duplicate groups : $groups"; echo "  redundant copies : $extra"
  if [ "${1:-}" = "--remove" ] && [ "$extra" -gt 0 ]; then
    confirm "Delete $extra redundant copies (keep one of each)?" || { rm -f "$tmp"; return 0; }
    awk '{h=$1; $1=""; sub(/^ /,""); if(h==p) print; else p=h}' "$tmp" | while IFS= read -r ff; do maybe rm -f "$ff"; done
    occ files:scan --path="${NC_USER}/files/${REL_ICLOUD}" >/dev/null 2>&1; ok "removed duplicates and re-scanned"
  else echo "  (run: dedupe --remove  to delete extras, keeping one each)"; fi; rm -f "$tmp"; }

faces(){ log "clustering faces (Recognize -> Memories People)"
  occ recognize:cluster-faces 2>&1 | nostderr | tail -3; ok "face clustering run (see Memories -> People)"; }

hwaccel(){ if [ -d /dev/dri ]; then occ config:system:set memories.vod.vaapi --value=true --type=boolean >/dev/null
    ok "VAAPI hardware transcoding enabled (/dev/dri present)"
  else warn "no /dev/dri -> software transcoding only (fine on many cores)"; fi; }

contacts(){ local out="$WORK/merged-contacts.vcf"; : > "$out"; local n=0
  while IFS= read -r ff; do cat "$ff" >> "$out"; echo >> "$out"; n=$((n+1)); done < <(find "$WORK" -iname '*.vcf' ! -path "$out" 2>/dev/null)
  if [ "${1:-}" = "--strip-photos" ]; then awk 'skip&&/^[^ ]/{skip=0} /^PHOTO/{skip=1} !skip' "$out" > "$out.t" && mv "$out.t" "$out"; fi
  [ "$n" -gt 0 ] && ok "merged $n vCard file(s) -> $out  (Nextcloud Contacts -> Settings -> Import)" || warn "no .vcf files found under $WORK"; }

calendars(){ local d="$WORK/calendars"; mkdir -p "$d"; local n=0
  while IFS= read -r ff; do cp -f "$ff" "$d/"; n=$((n+1)); done < <(find "$WORK" -iname '*.ics' 2>/dev/null)
  [ "$n" -gt 0 ] && ok "collected $n .ics file(s) -> $d  (Nextcloud Calendar -> Settings -> Import)" || warn "no .ics files found under $WORK"; }

drive(){
  local src="${1:-$DRIVE_INCOMING}"
  mkdir -p "$DRIVE_DIR" "$DRIVE_INCOMING"
  banner "iCloud Drive to Nextcloud Files: $DRIVE_DIR"
  shopt -s nullglob
  local tmp z
  local zips=()
  if [ -f "$src" ] && [[ "$src" == *.zip ]]; then
    zips+=("$src")
  elif [ -d "$src" ]; then
    for z in "$src"/*.zip; do zips+=("$z"); done
  fi
  log "$(free_gb "$NC_FILES") GB free on data volume"
  if [ "${#zips[@]}" -gt 0 ]; then
    log "extracting ${#zips[@]} Drive zip archives; structure and dates preserved"
    tmp=$(mktemp -d)
    for z in "${zips[@]}"; do
      if unzip -l "$z" >/dev/null 2>&1; then
        unzip -o "$z" -d "$tmp" >/dev/null 2>&1 && log "   extracted $(basename "$z")"
      else
        warn "bad or incomplete zip: $(basename "$z")"
      fi
    done
    if [ -d "$tmp/iCloud Drive" ]; then
      cp -a "$tmp/iCloud Drive/." "$DRIVE_DIR/"
    else
      cp -a "$tmp/." "$DRIVE_DIR/"
    fi
    rm -rf "$tmp"
  elif [ -d "$src" ]; then
    log "copying files from $src into the Drive folder"
    cp -a "$src/." "$DRIVE_DIR/"
  else
    die "nothing to import; put Drive export zips in $DRIVE_INCOMING or run: drive /path"
  fi
  log "files:scan"
  occ files:scan --path="${NC_USER}/files/${REL_FILES}" | nostderr | tail -4 | tee -a "$LOG"
  local nfiles sz
  nfiles=$(find "$DRIVE_DIR" -type f 2>/dev/null | wc -l)
  sz=$(du -sh "$DRIVE_DIR" 2>/dev/null | cut -f1)
  ok "iCloud Drive imported: $nfiles files, $sz; in Files app only, not in Memories"
  echo "  Tip: for ongoing sync of new files, point the Nextcloud app at ${REL_FILES}/iCloud"
}

accounts(){ local sub="${1:-list}"; [ $# -gt 0 ] && shift
  case "$sub" in
    list|ls) _accounts_list;;
    add|new) _accounts_add "${1:-}" "${2:-}";;
    use|select|switch) _accounts_use "${1:-}";;
    current|who) echo "active account: ${ACTIVE_ACCT:-<default>}  (NC user: $NC_USER)";;
    remove|rm|del) _accounts_remove "${1:-}";;
    prep) _account_prep "$NC_USER";;
    *) echo "usage: accounts [list | add <name> [email] | use <name> | current | remove <name> | prep]";;
  esac; }

_accounts_list(){ banner "Accounts"
  shopt -s nullglob; local f n u found=0
  for f in "$ACCT_DIR"/*.conf; do found=1; n=$(basename "$f" .conf); u=$(. "$f"; echo "$NC_USER")
    if [ "$n" = "${ACTIVE_ACCT:-}" ]; then printf '  * %-16s NC user: %s   (ACTIVE)\n' "$n" "$u"
    else printf '    %-16s NC user: %s\n' "$n" "$u"; fi; done
  [ "$found" = 0 ] && echo "  (no profiles yet -- add one:  accounts add <name>)"
  echo "  in use right now -> NC_USER=$NC_USER"; }

_accounts_add(){ local name="$1" email="${2:-}"; [ -n "$name" ] || read -r -p "Profile label: " name
  [ -n "$name" ] || { warn "no name"; return 1; }
  local uid; read -r -p "Nextcloud username (uid) [$name]: " uid; uid="${uid:-$name}"
  if ! occ user:info "$uid" >/dev/null 2>&1; then
    if confirm "Nextcloud user '$uid' does not exist. Create it now?"; then
      local dn pw pw2; read -r -p "Display name [$uid]: " dn; dn="${dn:-$uid}"
      read -r -s -p "Set password for $uid: " pw; echo; read -r -s -p "Repeat password: " pw2; echo
      if [ -z "$pw" ] || [ "$pw" != "$pw2" ]; then warn "passwords empty/mismatch -- not creating user"
      else OC_PASS="$pw" $OCC user:add --password-from-env --display-name "$dn" "$uid" 2>&1 | nostderr | tail -3; fi
      unset pw pw2
    else warn "not creating; profile will still point at '$uid'"; fi
  fi
  [ -n "$email" ] || read -r -p "Email for $uid (optional): " email
  if [ -n "$email" ]; then
    occ user:setting "$uid" settings email "$email" >/dev/null 2>&1 && ok "email set: $email" || warn "could not set email (does the user exist yet?)"
  fi
  local aid; read -r -p "Apple ID for this account (optional, for 'pull'): " aid
  { echo "# icloud2nc account profile"; echo "NC_USER=\"$uid\""; [ -n "$email" ] && echo "ACCT_EMAIL=\"$email\""; [ -n "$aid" ] && echo "APPLE_ID=\"$aid\""; } > "$ACCT_DIR/$name.conf"
  ok "saved profile '$name' -> NC user '$uid' (email + Apple ID stored if given)"
  _account_prep "$uid"
  echo "$name" > "$CURRENT_FILE"; ok "active account -> $name (all photos/files now target '$uid')"; }

_accounts_use(){ local name="$1"; [ -n "$name" ] || { _accounts_list; read -r -p "use which profile? " name; }
  { [ -n "$name" ] && [ -f "$ACCT_DIR/$name.conf" ]; } || { warn "no such profile: $name"; return 1; }
  echo "$name" > "$CURRENT_FILE"
  local u; u=$(. "$ACCT_DIR/$name.conf"; echo "$NC_USER")
  ok "active account -> $name (NC user '$u'). All commands now target this account."; }

_accounts_remove(){ local name="$1"; [ -n "$name" ] || { warn "which profile?"; return 1; }
  [ -f "$ACCT_DIR/$name.conf" ] || { warn "no such profile: $name"; return 1; }
  confirm "Remove profile '$name'? (does NOT delete the Nextcloud user or any files)" || return 0
  rm -f "$ACCT_DIR/$name.conf"
  [ "$(cat "$CURRENT_FILE" 2>/dev/null)" = "$name" ] && rm -f "$CURRENT_FILE"
  ok "removed profile '$name'"; }

_account_prep(){ local u="${1:-$NC_USER}" dd nf
  dd=$(_dbget datadirectory); dd="${dd:-/storage}"; nf="$dd/$u/files"
  banner "Preparing folders + Memories for '$u'"
  mkdir -p "$nf/Photos/Icloud" "$nf/Photos/Albums" "$nf/Files/iCloud" 2>/dev/null
  touch "$nf/Photos/Albums/.nomedia" 2>/dev/null
  occ files:scan --path="$u/files" >/dev/null 2>&1 || warn "scan skipped (new user may need a first web login to create its home)"
  occ user:setting "$u" memories timelinePath "/Photos/Icloud" >/dev/null 2>&1
  ok "ready: '$u' -> Photos/Icloud (Memories timeline), Files/iCloud (documents)"; }

_accounts_interactive(){ _accounts_list
  read -r -p "action: [a]dd  [u]se  [r]emove  [Enter]=back: " x
  case "$x" in a|A) _accounts_add "";; u|U) read -r -p "profile name: " nm; _accounts_use "$nm";; r|R) read -r -p "profile name: " nm; _accounts_remove "$nm";; esac; }

prune(){ confirm "Delete the downloaded part zips in $WORK/incoming to reclaim space?" || { warn "cancelled"; return 0; }
  local b; b=$(du -sh "$WORK/incoming" 2>/dev/null | cut -f1); maybe rm -f "$WORK"/incoming/*.zip; ok "removed downloaded zips (freed ~${b:-0})"; }

clean(){ confirm "Remove scratch (metadata/state/logs)? Your photo library is NOT touched." || { warn "cancelled"; return 0; }
  maybe rm -rf "$WORK/metadata" "$STATE"; maybe rm -f "$LOGDIR"/*.log; ok "scratch cleared"; }

DRY="${DRY:-0}"
while true; do case "${1:-}" in -y|--yes) ASSUME_YES=1; shift;; --dry-run) DRY=1; shift;; *) break;; esac; done

case "${1:-menu}" in
  doctor) doctor;; tools) acquire_lock; tools; release_lock;; links) links;;
  download) shift; acquire_lock; download "$@"; release_lock;;
  pull|icloudpd) shift; acquire_lock; pull "$@"; release_lock;;
  autopull) shift; autopull "${1:-on}";;
  import) acquire_lock; import; release_lock;; albums) acquire_lock; albums; release_lock;;
  archive) acquire_lock; archive; release_lock;; extras) acquire_lock; extras; release_lock;;
  crons) crons;; status) status;; verify) verify;; report) report;; logs) shift; logs "${1:-40}";;
  backup) acquire_lock; backup; release_lock;; dedupe) shift; acquire_lock; dedupe "${1:-}"; release_lock;;
  faces) faces;; hwaccel) hwaccel;; contacts) shift; contacts "${1:-}";; calendars) calendars;;
  drive) shift; acquire_lock; drive "${1:-}"; release_lock;;
  accounts|account) shift; accounts "$@";;
  prune) acquire_lock; prune; release_lock;; clean) clean;;
  resume) resume;; all) all;; menu) menu;; help|-h|--help) usage;; *) err "unknown: $1"; usage;;
esac
