#!/bin/bash
# ============================================================================
# Download iCloud export parts directly onto the server, in parallel.
#
# Why: re-uploading ~500 GB from a laptop is slow. Apple's privacy.apple.com
# download links work with curl from anywhere, so pull them straight to the
# server at datacenter speed. Links expire in MINUTES, so paste fast.
#
# Usage:
#   1) On privacy.apple.com, right-click each "iCloud Photos Part N" download
#      button -> Copy link.
#   2) Paste links (one per line) into parts.txt next to this script:
#         <part-number><TAB or space><url>
#      e.g.   6   https://cvws.icloud-content.com/.....
#   3) bash download_parts.sh
#
# Detach-safe: each curl is nohup'd + disowned, so they survive SSH drops.
# Re-run for any part that came back tiny/failed (grab a fresh link first).
# ============================================================================
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; source "$DIR/config.sh"
LIST="${1:-$DIR/parts.txt}"
cd "$WORK/incoming" || exit 1

[ -f "$LIST" ] || { echo "Create $LIST with lines: <part-number> <url>"; exit 1; }

while read -r num url; do
  [ -z "$num" ] && continue
  case "$num" in \#*) continue;; esac
  out="iCloud Photos Part ${num} of 21.zip"
  echo "starting part $num -> $out"
  nohup curl -sL -o "$out" "$url" >/dev/null 2>&1 &
done < "$LIST"
disown -a
echo "All downloads started + detached. Safe to disconnect."
echo "Watch progress:  watch -n5 'ls -lah \"$WORK/incoming\"'"
echo "Verify when done: for z in \"$WORK\"/incoming/*.zip; do unzip -l \"\$z\" >/dev/null 2>&1 && echo \"OK \$z\" || echo \"BAD \$z\"; done"
