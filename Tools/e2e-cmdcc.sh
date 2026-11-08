#!/bin/zsh
# Real-keyboard end-to-end test of ⌘C+C → overlay. Run while the screen is UNLOCKED.
#
# A small harness app shows its own window with selected text, becomes frontmost and presses
# ⌘C twice through the window server (it refuses to press anything if it is not frontmost).
# Mimiuchi (headless) must detect the double press, read the copied text and show the overlay
# with the translation. A single ⌘C must NOT open the overlay.
#
# Mimiuchi is started through LaunchServices, like a normal launch, so it runs under its own
# Input Monitoring / Accessibility permissions; the test switches are passed as one-shot
# defaults that the app removes when it reads them. MIMIUCHI_E2E_LAUNCH=child starts it as a
# child of this shell instead, which inherits the terminal's permissions (useful before Mimiuchi
# is allowed). A Mimiuchi that was already running is restarted normally afterwards.
#
#   Tools/e2e-cmdcc.sh [output-dir]     # default /tmp/mimiuchi-e2e
set -u
OUT="${1:-/tmp/mimiuchi-e2e}"
OUT="${OUT:a}"  # absolute: an app launched by LaunchServices runs with "/" as its directory
cd "$(dirname "$0")/.."
APP="${MIMIUCHI_APP:-$HOME/Applications/Mimiuchi.app}"
APP_BIN="$APP/Contents/MacOS/Mimiuchi"
BUNDLE_ID="local.mimiuchi.Mimiuchi"
LAUNCH="${MIMIUCHI_E2E_LAUNCH:-open}"
HARNESS=/tmp/mimiuchi-keyharness
FLAGS=()
[[ "${MIMIUCHI_NESTED_SANDBOX:-0}" == "1" ]] && FLAGS=(-disable-sandbox)
swiftc "${FLAGS[@]}" -O Tools/keyharness.swift -o "$HARNESS" >/dev/null 2>&1 || { echo "FAIL: could not build harness"; exit 1; }

# Remove only what this test and the app write, never the directory itself.
mkdir -p "$OUT" || { echo "FAIL: cannot create $OUT"; exit 1; }
rm -f "$OUT"/{app.log,harness-double.log,harness-single.log,monitor-status.txt,overlay-log.jsonl,trace.log} "$OUT"/overlay-*.png(N)
JA="来週の会議はオンラインで開催します。資料は前日までに共有してください。"
EN="This single copy must not open the overlay."
CLIP_BEFORE="$(pbpaste 2>/dev/null)"

WAS_RUNNING=0
pgrep -f "$APP_BIN" >/dev/null && WAS_RUNNING=1
APP_PID=""
LAUNCHED=0
CLEANED=0
cleanup() {
  (( CLEANED )) && return 0
  CLEANED=1
  trap '' INT TERM HUP  # a second Ctrl-C must not cut the restore short
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null
  elif (( LAUNCHED )); then
    pkill -f "$APP_BIN" 2>/dev/null  # interrupted before the pid was known: only the test instance runs
  fi
  # Normally already consumed by the app at launch.
  defaults delete "$BUNDLE_ID" MIMIUCHI_HEADLESS >/dev/null 2>&1
  defaults delete "$BUNDLE_ID" MIMIUCHI_DEBUG_DIR >/dev/null 2>&1
  local cur="$(pbpaste 2>/dev/null)"
  if [[ "$cur" == "$JA" || "$cur" == "$EN" ]]; then printf "%s" "$CLIP_BEFORE" | pbcopy; fi
  if (( WAS_RUNNING )); then sleep 1; open -g "$APP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP  # zsh only runs the EXIT trap on these signals if they are trapped

pkill -f "$APP_BIN" 2>/dev/null; sleep 1
LAUNCHED=1
if [[ "$LAUNCH" == "child" ]]; then
  MIMIUCHI_HEADLESS=1 MIMIUCHI_DEBUG_DIR="$OUT" "$APP_BIN" > "$OUT/app.log" 2>&1 &
  APP_PID=$!
else
  defaults write "$BUNDLE_ID" MIMIUCHI_HEADLESS -string 1
  defaults write "$BUNDLE_ID" MIMIUCHI_DEBUG_DIR -string "$OUT"
  open -n -g "$APP"
  for i in {1..40}; do APP_PID="$(pgrep -f "$APP_BIN" | head -1)"; [[ -n "$APP_PID" ]] && break; sleep 0.25; done
fi

sleep 6  # model preload
STATUS="$(head -1 "$OUT/monitor-status.txt" 2>/dev/null)"
echo "Mimiuchi ($LAUNCH launch, pid ${APP_PID:-?}): ${STATUS:-no status} $(tail -n +2 "$OUT/monitor-status.txt" 2>/dev/null | tr '\n' ' ')"
if [[ "$STATUS" != "monitoring" ]]; then
  cleanup
  case "$STATUS" in
    needsInputMonitoring) echo "FAIL: Mimiuchi is not allowed in System Settings > Privacy & Security > Input Monitoring" ;;
    needsRelaunch) echo "FAIL: Input Monitoring is on but only takes effect after Mimiuchi restarts" ;;
    disabled) echo "FAIL: ⌘C+C is turned off in Mimiuchi's settings" ;;
    termsNotAccepted) echo "FAIL: open Mimiuchi once and agree to the Terms of Use first" ;;
    *) echo "FAIL: the ⌘C+C monitor is not running" ;;
  esac
  exit 1
fi

"$HARNESS" "$JA" double > "$OUT/harness-double.log" 2>&1
DOUBLE_RC=$?
for i in {1..30}; do [[ -s "$OUT/overlay-log.jsonl" ]] && break; sleep 1; done
AFTER_DOUBLE=$(cat "$OUT/overlay-log.jsonl" 2>/dev/null | wc -l | tr -d ' ')

"$HARNESS" "$EN" single > "$OUT/harness-single.log" 2>&1
SINGLE_RC=$?
sleep 6
AFTER_SINGLE=$(cat "$OUT/overlay-log.jsonl" 2>/dev/null | wc -l | tr -d ' ')
cleanup

echo "harness(double): $(tail -2 "$OUT/harness-double.log" | tr '\n' ' ')"
echo "harness(single): $(tail -2 "$OUT/harness-single.log" | tr '\n' ' ')"
if [[ $DOUBLE_RC -ne 0 || $SINGLE_RC -ne 0 ]]; then echo "INCONCLUSIVE: harness could not run (rc=$DOUBLE_RC/$SINGLE_RC)"; exit 2; fi
python3 -I - "$OUT/overlay-log.jsonl" "$JA" "$AFTER_DOUBLE" "$AFTER_SINGLE" <<'PY'
import json, sys
path, ja, after_double, after_single = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
entries = [json.loads(l) for l in open(path, encoding="utf-8")] if after_double else []
ok_double = after_double == 1 and entries[0]["source"] == ja and entries[0]["translation"].strip() != ""
ok_single = after_single == after_double
if entries:
    e = entries[0]
    print(f"overlay: app={e['app']} anchor={e['anchor']} frame={e['panelFrame']}")
    print(f"source: {e['source']}")
    print(f"translation: {e['translation']}  ({e['tokensPerSecond']:.0f} tok/s)")
print(f"double press -> overlay with copied text + translation: {'PASS' if ok_double else 'FAIL'}")
print(f"single press -> no overlay: {'PASS' if ok_single else 'FAIL'}")
sys.exit(0 if ok_double and ok_single else 1)
PY
RC=$?
if [[ $RC -ne 0 && -f "$OUT/trace.log" ]]; then echo "--- trace (Mimiuchi)"; cat "$OUT/trace.log"; fi
exit $RC
