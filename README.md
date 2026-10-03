# Inbox+ IOS

Native iPhone and iPad companion for [Inbox+ on Mac](https://github.com/Tsha0/InboxPlus), preserving its monochrome artwork, network glyphs, typography, message bubbles, contact grouping, and account login engine.

## Architecture

The phone connects to **your Mac**. The Mac continues to run the existing Matrix homeserver, network bridges and native iMessage adapter. iOS does not embed Synapse, downloaded bridge executables, AppleScript, or the Mac Messages database. No operated Inbox+ cloud is introduced.

The iOS target supports iOS 17 and later. The companion requires macOS 15 and the same prepared messaging profile as the desktop app. Xcode 26 / Swift 6.2 or later is required to build.

## Features

- Unified inbox, search, All/Unread filters, unread counts and live foreground synchronization.
- Linked people, per-network conversation summaries, and contact links saved on device.
- Text sending with delivery feedback and retry; file imports with capability checks and removable staged attachments.
- Images, audio/video playback, document sharing, and verified “Open in app” links.
- The desktop account catalog and bridge-driven login steps: web cookies, phone/input, QR/pairing code, waiting and completion.
- iMessage through the Mac adapter and its macOS permissions.
- iPhone navigation, iPad split view, light/dark appearance, accessibility labels, and an explicitly labeled demo inbox.
- HTTPS pairing; credentials in device-only Keychain; local data cleared on unpair.

### Platform differences and development limits

The Mac must be reachable and running. Sync runs while the app is open; background push notifications and App Store distribution are not configured. Mobile media transfers are currently limited to 25 MB. Account history removal applies to this device; network logout and Mac profile deletion are managed on the Mac. Contacts are stored locally on the phone and are not synchronized with desktop contact links. The desktop's existing network readiness limits still apply: only Instagram was certified with a real account in the source project. This repository does not claim new live-account certification.

## Build and run iOS

1. Open `iOS/InboxPlusIOS.xcodeproj` in Xcode.
2. Complete Xcode's first-launch component installation if prompted.
3. Select the **InboxPlusIOS** scheme and an iPhone or iPad simulator; Run.
4. Choose **Explore demo inbox**, or connect to the Mac companion.

You can also run `Scripts/run-ios.sh --demo` to build, install, and launch in the first available iPhone simulator. Set `INBOXPLUS_SIMULATOR_ID` to choose a specific simulator.

For a physical device, select your own development team under Signing & Capabilities and choose the device. No signing identity or provisioning profile is stored here.

```bash
swift test
xcodebuild -project iOS/InboxPlusIOS.xcodeproj -scheme InboxPlusIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

Use an installed simulator name from `xcrun simctl list devices available`. The shared scheme includes UI tests for search, conversation navigation, sending, contacts, account picker, and pairing validation. GitHub Actions runs both iPhone and iPad tests and retains `.xcresult` reports.

## Run the real Mac companion

Prepare a profile using the Mac app's runtime tools first. Keep a single runtime owner; the companion can attach to a profile already running on this Mac.

```bash
INBOXPLUS_BUILD_COMPANION=1 swift build --product InboxPlusRuntimeCLI
INBOXPLUS_BUILD_COMPANION=1 swift build --product InboxPlusCompanion
export INBOXPLUS_PROFILE=your-profile
export INBOXPLUS_PAIRING_KEY="$(openssl rand -hex 32)"
.build/debug/InboxPlusCompanion
```

Copy the generated pairing key into the phone's pairing field. It is not printed by the server or included in logs. Store it securely if you want pairing to survive a companion restart. Change it to revoke paired devices.

The listener binds **only to 127.0.0.1:8765** and requires a bearer key. Place it behind an HTTPS reverse proxy reachable from your phone (for example, a private VPN's HTTPS serving feature). Enter that HTTPS base URL in the app. Do not expose the raw HTTP port to the Internet. Normal certificate validation remains enabled; there is no trust-all certificate bypass. HTTP loopback is supported only for testing on this Mac's simulator.

The companion needs the same Full Disk Access and Messages Automation permissions as the desktop for iMessage. A newly installed bridge requires restarting the Mac runtime before its login becomes available; reopening only the phone app does not restart that runtime.

## Fixture companion

For transport tests without real accounts:

```bash
export INBOXPLUS_PAIRING_KEY="$(openssl rand -hex 32)"
swift run InboxPlusCompanionFixture
```

Pair the local simulator with `http://127.0.0.1:8765` and that key. This executable is explicitly a demo fixture and supports snapshots and text sending only. Production uses `InboxPlusCompanion`.

## Source layout

- `iOS/`: app entry point, assets, Xcode project and UI tests.
- `Sources/InboxPlusMobile`: pairing, Keychain, mobile navigation and settings.
- `Sources/InboxPlusRemote`: authenticated transport, foreground polling, media and login adapters.
- `Sources/InboxPlusCompanionServer`: bounded loopback HTTP listener.
- `Sources/InboxPlusCompanion`: real Mac service using the desktop gateways/runtime.
- `InboxPlusCore`, `InboxPlusFeatures`, `InboxPlusGateway`, `InboxPlusBridge`, `InboxPlusUI`: code reused from the Mac app, with iOS portability changes.
- Other desktop modules and `docs/`: inherited implementation and historical desktop notes, not iOS certification.

The default package has no third-party dependencies. `INBOXPLUS_BUILD_COMPANION=1` selects the desktop targets and their pinned Matrix SDK. Shared models and UI stay in one source tree.

## Source provenance

The Mac source was imported from `Tsha0/InboxPlus` commit `2b819adc262490a70bf9ad786ffcc8a71f5b5eae`. The original Mac checkout was left unchanged.

## License

AGPL-3.0-or-later; see [LICENSE](LICENSE). Network marks identify their respective services. This project derives from InboxPlus and retains its license and attribution.
