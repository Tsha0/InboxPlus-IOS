#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! xcodebuild -checkFirstLaunchStatus; then
  echo 'Open Xcode and finish installing its required components, then retry.' >&2
  exit 1
fi
DEVICE_ID="${INBOXPLUS_SIMULATOR_ID:-$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if "iPhone" in x["name"]))')}"
xcodebuild -project iOS/InboxPlusIOS.xcodeproj -scheme InboxPlusIOS \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b
open -a Simulator
xcrun simctl install "$DEVICE_ID" build/DerivedData/Build/Products/Debug-iphonesimulator/InboxPlusIOS.app
xcrun simctl launch "$DEVICE_ID" com.inboxplus.ios "$@"
