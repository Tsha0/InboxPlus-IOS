#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${INBOXPLUS_SIMULATOR_ID:?Select an exact simulator with select-simulator.py}"
REPORT_NAME="${INBOXPLUS_REPORT_NAME:-iOS}"
mkdir -p build
FIXTURE_TOKEN="$(openssl rand -hex 32)"
swift build --product InboxPlusCompanionFixture
INBOXPLUS_PAIRING_KEY="$FIXTURE_TOKEN" .build/debug/InboxPlusCompanionFixture > build/fixture.log 2>&1 &
FIXTURE_PID=$!
cleanup() {
  STATUS=$?
  kill "$FIXTURE_PID" 2>/dev/null || true
  if [[ "$STATUS" != 0 && -f "build/$REPORT_NAME.log" ]]; then tail -n 100 "build/$REPORT_NAME.log"; fi
  return "$STATUS"
}
trap cleanup EXIT
# Confirm both readiness and authentication without printing the generated key.
FIXTURE_TEST_KEY="$FIXTURE_TOKEN" python3 - <<'PY'
import json, os, time, urllib.request
request=urllib.request.Request('http://127.0.0.1:8765/v1/rpc',data=b'{"operation":"snapshot"}',headers={'Authorization':'Bearer '+os.environ['FIXTURE_TEST_KEY'],'Content-Type':'application/json'})
for attempt in range(100):
    try:
        with urllib.request.urlopen(request,timeout=2) as response:
            assert json.load(response)['snapshot']['accounts']
        break
    except Exception:
        if attempt == 99: raise
        time.sleep(0.1)
PY
xcrun simctl boot "$INBOXPLUS_SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$INBOXPLUS_SIMULATOR_ID" -b
xcrun simctl ui "$INBOXPLUS_SIMULATOR_ID" appearance "${INBOXPLUS_TEST_APPEARANCE:-light}"
xcrun simctl status_bar "$INBOXPLUS_SIMULATOR_ID" override --time 9:41 --batteryState charged --batteryLevel 100
xcodebuild -project iOS/InboxPlusIOS.xcodeproj -scheme InboxPlusIOS \
  -testPlan InboxPlusIOS -destination "platform=iOS Simulator,id=$INBOXPLUS_SIMULATOR_ID" \
  -derivedDataPath build/DerivedData -resultBundlePath "build/$REPORT_NAME.xcresult" \
  -parallel-testing-enabled NO -enableCodeCoverage YES \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- "INBOXPLUS_TEST_TOKEN=$FIXTURE_TOKEN" \
  "INBOXPLUS_TEST_LARGE_TEXT=${INBOXPLUS_TEST_LARGE_TEXT:-0}" test > "build/$REPORT_NAME.log" 2>&1
