#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "${CI:-}" == true ]] || { echo 'Signing and upload run only on the isolated CI runner.' >&2; exit 1; }
python3 Scripts/ci/release-preflight.py
: "${RUNNER_TEMP:?}" "${RELEASE_VERSION:?}" "${GITHUB_RUN_NUMBER:?}" "${GITHUB_RUN_ATTEMPT:?}"
RELEASE_TEMP="$(mktemp -d "$RUNNER_TEMP/inbox-release.XXXXXX")"
KEYCHAIN="$RELEASE_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
PROFILE_DEST=""
PREVIOUS_KEYCHAINS="$(security list-keychains -d user)"
cleanup() {
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  # The runner is isolated; restore its original search list after signing.
  PREVIOUS_KEYCHAINS="$PREVIOUS_KEYCHAINS" python3 - <<'PY'
import os,shlex,subprocess
subprocess.run(['security','list-keychains','-d','user','-s',*shlex.split(os.environ['PREVIOUS_KEYCHAINS'])],check=False)
PY
  [[ -z "$PROFILE_DEST" ]] || rm -f "$PROFILE_DEST"
  rm -rf "$RELEASE_TEMP"
}
trap cleanup EXIT
RELEASE_TEMP="$RELEASE_TEMP" python3 - <<'PY'
import os,base64,pathlib
root=pathlib.Path(os.environ['RELEASE_TEMP'])
for name,file in [('IOS_DISTRIBUTION_CERTIFICATE_B64','distribution.p12'),('IOS_PROVISIONING_PROFILE_B64','profile.mobileprovision')]:
    (root/file).write_bytes(base64.b64decode(os.environ[name],validate=True))
keys=root/'private_keys';keys.mkdir()
(keys/('AuthKey_'+os.environ['ASC_KEY_ID']+'.p8')).write_bytes(base64.b64decode(os.environ['ASC_PRIVATE_KEY_B64'],validate=True))
PY
security cms -D -i "$RELEASE_TEMP/profile.mobileprovision" > "$RELEASE_TEMP/profile.plist"
PROFILE_UUID="$(RELEASE_TEMP="$RELEASE_TEMP" python3 - <<'PY'
import datetime,os,plistlib,pathlib
profile=plistlib.loads((pathlib.Path(os.environ['RELEASE_TEMP'])/'profile.plist').read_bytes())
team=os.environ['APPLE_TEAM_ID'];entitlements=profile['Entitlements']
assert team in profile['TeamIdentifier'], 'Profile belongs to a different Apple team'
assert entitlements['application-identifier']==team+'.com.inboxplus.ios', 'Profile must match com.inboxplus.ios'
assert not entitlements.get('get-task-allow',False) and 'ProvisionedDevices' not in profile, 'Use an App Store distribution profile'
assert profile['ExpirationDate']>datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Provisioning profile expired'
print(profile['UUID'])
PY
)"
PROFILE_DEST="$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
mkdir -p "$(dirname "$PROFILE_DEST")"
cp "$RELEASE_TEMP/profile.mobileprovision" "$PROFILE_DEST"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$RELEASE_TEMP/distribution.p12" -P "$IOS_CERTIFICATE_PASSWORD" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"
mkdir -p build
xcodebuild -project iOS/InboxPlusIOS.xcodeproj -scheme InboxPlusIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/InboxPlusIOS.xcarchive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' \
  "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" "PROVISIONING_PROFILE_SPECIFIER=$PROFILE_UUID" \
  "MARKETING_VERSION=$RELEASE_VERSION" "CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER.$GITHUB_RUN_ATTEMPT" archive > build/archive.log 2>&1
EXPORT_OPTIONS="$RELEASE_TEMP/ExportOptions.plist" PROFILE_UUID="$PROFILE_UUID" python3 - <<'PY'
import os,plistlib
with open(os.environ['EXPORT_OPTIONS'],'wb') as f:
    plistlib.dump({'method':'app-store-connect','destination':'export','signingStyle':'manual','teamID':os.environ['APPLE_TEAM_ID'],'signingCertificate':'Apple Distribution','provisioningProfiles':{'com.inboxplus.ios':os.environ['PROFILE_UUID']},'manageAppVersionAndBuildNumber':False,'uploadSymbols':True},f)
PY
xcodebuild -exportArchive -archivePath build/InboxPlusIOS.xcarchive -exportOptionsPlist "$RELEASE_TEMP/ExportOptions.plist" -exportPath build/export > build/export.log 2>&1
IPA_PATH="$(pwd)/build/export/InboxPlusIOS.ipa"
[[ -f "$IPA_PATH" ]] || { echo 'Expected exported IPA is missing.' >&2; exit 1; }
# Transporter looks for AuthKey_<id>.p8 in ./private_keys. The key is never archived as an artifact.
(cd "$RELEASE_TEMP" && xcrun iTMSTransporter -m upload -assetFile "$IPA_PATH" -apiKey "$ASC_KEY_ID" -apiIssuer "$ASC_ISSUER_ID") > build/upload.log 2>&1
echo 'Build uploaded to App Store Connect for TestFlight processing.'
