#!/bin/bash
# ============================================================================
# Per-instance settings. Edit these, then `source config.sh` (the scripts do).
# ============================================================================

# The Nextcloud user that owns the photos (case-sensitive uid, NOT display name)
NC_USER="Aqua"

# Absolute path to that user's files root in the Nextcloud data directory.
# Find your data dir with:  php occ config:system:get datadirectory
NC_FILES="/storage/${NC_USER}/files"

# Where imported photos/videos go (a folder under NC_FILES). Created if missing.
ICLOUD_DIR="${NC_FILES}/Icloud"

# Where the physical album folders go (kept out of the timeline via .nomedia).
ALBUMS_DIR="${NC_FILES}/Albums"

# How to run occ (adjust for your install):
#   classic:   php /home/USER/public_html/occ
#   AIO/docker: sudo docker exec --user www-data -it nextcloud-aio-nextcloud php occ
OCC="php ${HOME}/public_html/occ"

# Working area for downloads, extraction, metadata, logs (lots of free space).
WORK="${HOME}/icloud_migration"

# Tool paths (installed by setup_extras.sh if missing; all work without root).
EXIFTOOL="${WORK}/tools/bin/exiftool"     # git clone exiftool/exiftool, symlink here
FFMPEG="${WORK}/tools/bin/ffmpeg"          # static build
FFPROBE="${WORK}/tools/bin/ffprobe"        # static build

# Database connection (used only to star Favorites — read from config.php).
# Leave as-is to auto-read them via occ.
DB_NAME="$(${OCC} config:system:get dbname 2>/dev/null)"
DB_USER="$(${OCC} config:system:get dbuser 2>/dev/null)"
DB_PASS="$(${OCC} config:system:get dbpassword 2>/dev/null)"
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_PREFIX="$(${OCC} config:system:get dbtableprefix 2>/dev/null || echo oc_)"

mkdir -p "$WORK/incoming" "$WORK/metadata" "$WORK/work" "$ICLOUD_DIR"

# tiny mysql helper:  q "SQL..."
q(){ mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "$1" 2>/dev/null; }
