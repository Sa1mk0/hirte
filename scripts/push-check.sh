#!/usr/bin/env bash
# Checks what a tapped notification does, on a simulator with real pushes: builds the app for testing,
# then runs each of hirteUITests/PushRouteUITests on its own while delivering the demo machine's
# notifications with `xcrun simctl push` (through scripts/push-test.sh --simulator) at the right
# moments: before the app runs (cold), while it is in the background (warm), and while its terminal
# is on screen (no banner for it, one for another terminal). Screenshots land in $HIRTE_SHOTS
# (default .build/push-check).
#
#   scripts/push-check.sh [simulator name or udid]     (default: $HIRTE_SIMULATOR, "iPhone 17 Pro")
set -euo pipefail
cd "$(dirname "$0")/.."

sim="${1:-${HIRTE_SIMULATOR:-iPhone 17 Pro}}"
bundle="${HIRTE_BUNDLE_ID_PREFIX:-io.github.sa1mk0}.hirte.dev"
shots="${HIRTE_SHOTS:-$PWD/.build/push-check}"
mkdir -p "$shots"
udid="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
want = sys.argv[1]
for ds in json.load(sys.stdin)["devices"].values():
    for d in ds:
        if d["isAvailable"] and want in (d["name"], d["udid"]): print(d["udid"]); sys.exit()
sys.exit("no simulator " + want)' "$sim")"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null

# The demo's terminals get fixed identities, so created_ms in the payload can match (t3 started 41
# minutes before the epoch; see DemoScript).
epoch=$(($(date +%s) * 1000))
t3_created=$((epoch - 41 * 60000))
build=(xcodebuild -project hirte.xcodeproj -scheme hirte -derivedDataPath .build/xcode -configuration Debug
       -destination "id=$udid" HIRTE_BUNDLE_ID_PREFIX="${HIRTE_BUNDLE_ID_PREFIX:-io.github.sa1mk0}")
"${build[@]}" build-for-testing | xcbeautify --quiet
app=".build/xcode/Build/Products/Debug-iphonesimulator/hirte.app"

# A fresh install (that also clears its old notifications), then testPrepare runs it once with the demo
# and allows notifications; the demo machine's id comes from its saved machines.
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl uninstall "$udid" "$bundle" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
run() {  # test method; the test waits for the pushes, so it runs in the background while they go out
    TEST_RUNNER_HIRTE_PUSH_CHECK=1 TEST_RUNNER_HIRTE_DEMO_EPOCH_MS="$epoch" TEST_RUNNER_HIRTE_SHOTS="$shots" \
        "${build[@]}" -only-testing:"hirteUITests/PushRouteUITests/$1" test-without-building 2>&1 | xcbeautify --quiet | grep -E "✔|✖|✘|error:|Executed [0-9]+ test" | head -2 || true
}
echo "== prepare: fresh install, demo on, notifications allowed"
run testPrepare
prefs="$(xcrun simctl get_app_container "$udid" "$bundle" data)/Library/Preferences/$bundle.plist"
host_id=""
for _ in $(seq 20); do  # the preferences take a moment to reach the file
    host_id="$(python3 -I - "$prefs" <<'PY'
import json, plistlib, sys
try:
    hosts = json.loads(bytes(plistlib.load(open(sys.argv[1], "rb")).get("hirte.hosts", b"[]")))
    print(next((h["id"] for h in hosts if h.get("demo")), ""))
except Exception:  # not there yet
    print("")
PY
)" || true
    [ -n "$host_id" ] && break
    sleep 1
done
[ -n "$host_id" ] || { echo "the demo machine didn't appear in the app's saved machines" >&2; exit 1; }
echo "demo machine $host_id on $sim ($udid)"

push() {  # address created_ms title body
    scripts/push-test.sh --simulator "$udid" --bundle-id "$bundle" --host-id "$host_id" \
        --address "$1" --created-ms "$2" --title "$3" --body "$4" >/dev/null
    echo "  sent $1 ($3, created_ms $2)"
}
t3() { push t3 "${1:-$t3_created}" shop-api "Run the database migration?"; }
t1() { push t1 0 website "Adding a dark mode toggle"; }
# (Not `grep -q`: it stops reading at the match, launchctl gets SIGPIPE, and pipefail calls that a miss.)
app_running() { xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep "UIKitApplication:$bundle" >/dev/null; }
wait_for_app() {  # the test launched the app (the previous test's instance was ended before `run`)
    for _ in $(seq 60); do app_running && return; sleep 2; done
    echo "the app didn't start" >&2; exit 1
}

echo "== cold: the notification arrives while the app isn't running"
# Started by the tap, the app has no fixed demo epoch: without created_ms the address decides.
t3 0
run testColdTap

runner=""
# No test runner left behind on a failure.
trap 'if [ -n "$runner" ]; then pkill -P "$runner" 2>/dev/null || true; kill "$runner" 2>/dev/null || true; fi' EXIT
echo "== warm: the app is in the background"
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
run testWarmTap & runner=$!
wait_for_app; sleep 8; t3
wait $runner

echo "== foreground: the terminal on screen gets no banner, another terminal does"
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
run testForegroundSuppression & runner=$!
wait_for_app; sleep 12; t3; sleep 8; t1
wait $runner
echo "screenshots: $shots"
