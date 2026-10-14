#!/usr/bin/env bash
# Launch an app and report its memory footprint, including the WebKit helper
# processes it starts (WebContent / GPU / Networking for a Tauri WebView).
#
#   ./measure.sh <App.app> [--wait N | --enter] [-- app args...]
#
#   --wait N   measure N seconds after launch (default 15)
#   --enter    measure when you press Enter (do your clicks in the app first)
#
# The app is quit afterwards. Footprint is what Activity Monitor shows as "Memory".
set -euo pipefail

APP="${1:?usage: measure.sh <App.app> [--wait N | --enter] [-- args...]}"
shift
WAIT=15
ENTER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT="$2"; shift 2 ;;
    --enter) ENTER=1; shift ;;
    --) shift; break ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")
if pgrep -x "$EXE" >/dev/null; then
  echo "$EXE is already running; quit it first" >&2
  exit 1
fi

webkit() { pgrep -f 'com\.apple\.WebKit\.' | sort || true; }
BEFORE=$(webkit)
open -n "$APP" --args "$@"
if [[ $ENTER == 1 ]]; then
  read -r -p "Press Enter to measure... "
else
  sleep "$WAIT"
fi

MAIN=$(pgrep -nx "$EXE")
HELPERS=$(comm -13 <(echo "$BEFORE") <(webkit))
TOTAL=0
for pid in $MAIN $HELPERS; do
  line=$(footprint -f bytes --noCategories "$pid" 2>/dev/null | grep -m1 'Footprint:') || continue
  bytes=$(sed -E 's/.*Footprint: ([0-9]+) B.*/\1/' <<<"$line")
  name=$(sed -E 's/^(.*) \[[0-9]+\].*/\1/' <<<"$line")
  printf '  %-32s %6.1f MB\n' "$name" "$(bc -l <<<"$bytes/1048576")"
  TOTAL=$((TOTAL + bytes))
done
printf '  %-32s %6.1f MB\n' "TOTAL" "$(bc -l <<<"$TOTAL/1048576")"
kill "$MAIN"
