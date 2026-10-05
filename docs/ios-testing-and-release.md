# iOS tests and delivery

The mobile and companion pipelines run independently. Pull requests must pass **iOS gate** and **Companion gate**. The iOS gate includes shared tests, native unit/UI tests on iPhone and iPad, and an unsigned device Release build. TestFlight is a separate workflow and accepts only a commit already tested by successful main-branch push runs of both pipelines.

## Test organization

| Location | Purpose |
| --- | --- |
| `Tests/InboxPlusMobileTests/` | Pairing, credential errors, restoration, concurrent pairing, background/foreground, local contacts, unpair cleanup. These tests run on macOS and in the native iOS unit target. |
| `iOS/InboxPlusIOSTests/` | Real simulator Keychain save/update/delete and device-only accessibility attributes. Every test uses a unique Keychain service. |
| `Tests/InboxPlusRemoteTests/` | Authenticated socket round trips, HTTP/network failures, malformed responses, routing, exact attachment bytes/size limits, media, login, deterministic polling and recovery. |
| `iOS/InboxPlusIOSUITests/` | Focused navigation, pairing, messaging, contacts and account suites. Real pairing/retry/login tests use the loopback fixture, not the demo gateway. |
| Other `Tests/` suites | Existing shared behavior and Mac runtime/bridge/iMessage/Matrix coverage. Real-account tests remain explicitly opt-in. |
| `Scripts/ci/test-pipeline.py` | Exact-runtime selection, exact-commit release gating, version validation and missing signing settings. |

Native iOS tests are selected by `iOS/InboxPlusIOS.xctestplan`. UI tests run serially on each simulator so they cannot reset another test's local state. A debug-only `--ui-testing` launch flag isolates credentials and files; this flag has no effect in Release builds. The real companion never includes the fixture's fault operations.

## Run locally

```bash
swift test --enable-code-coverage
python3 Scripts/ci/test-pipeline.py
export INBOXPLUS_SIMULATOR_ID="$(python3 Scripts/ci/select-simulator.py --runtime 26.4.1 --family iPhone)"
bash Scripts/ci/test-ios.sh
bash Scripts/ci/export-test-results.sh
```

The helper starts the fixture with a random key, confirms readiness, passes the key to the test plan, and stops the fixture on exit. Simulator builds use ad hoc signing so real Keychain entitlements are present; no Apple signing credentials are needed. Port 8765 must be available. `INBOXPLUS_TEST_APPEARANCE=dark` and `INBOXPLUS_TEST_LARGE_TEXT=1` select regression presentation. The simulator runtime must be installed; selection fails instead of silently choosing another version.

For Xcode's Test button, first start `InboxPlusCompanionFixture` with `INBOXPLUS_PAIRING_KEY` and pass that same value as the `INBOXPLUS_TEST_TOKEN` build setting. The script handles this automatically. Tests never use real network-account credentials.

## Workflows and artifacts

| Workflow | Trigger | Artifacts |
| --- | --- | --- |
| `ios-ci.yml` | PR, main push, manual | Shared coverage/logs; iPhone/iPad `.xcresult`, screenshots, summary and coverage JSON; Release build log. |
| `companion-ci.yml` | PR, main push, nightly, manual | Full companion test/build log. |
| `ios-regression.yml` | Nightly, manual | Dark iPhone, large-text iPad, and iOS 17.5 compatibility reports/screenshots. |
| `ios-release.yml` | `ios-vX.Y.Z` tag or manual | Unsigned validation archive and exact source/CI evidence; signed archive, IPA, symbols and upload logs when publishing. |

Nightly runs are scheduled around 03:20/03:40 Singapore time. The compatibility job initializes CoreSimulator before downloading iOS 17.5 explicitly, avoiding the hosted runner’s first-connection race. Pull-request jobs use installed iOS 26.4.1 simulators and pinned Xcode 26.5. Official GitHub Actions are pinned to immutable commit IDs. Jobs have timeouts; newer PR runs cancel obsolete ones. Reports are retained for 14 days, release evidence for 30 days.

Coverage is recorded as a baseline, not inflated by tests that mirror implementation. No arbitrary percentage gate is claimed. The required gates enforce passing tests and a successful Release build. Real-account certification and background push delivery are outside these fixtures.

## Configure TestFlight

Create the App Store Connect app for **`com.inboxplus.ios`**, then configure the GitHub **testflight** environment at the repository's Settings → Environments. Its allowed deployment branches/tags should be `main` and `ios-v*`.

Set the nonsecret environment variable:

- `APPLE_TEAM_ID`: your Apple Developer Team ID.

Set these environment secrets using GitHub's secure settings, not an issue or chat message:

- `ASC_KEY_ID` and `ASC_ISSUER_ID`: App Store Connect API key identifiers, with permission to upload builds.
- `ASC_PRIVATE_KEY_B64`: base64 contents of the API `.p8` key.
- `IOS_DISTRIBUTION_CERTIFICATE_B64`: base64 contents of an Apple Distribution `.p12` containing its private key.
- `IOS_CERTIFICATE_PASSWORD`: that `.p12` file's password.
- `IOS_PROVISIONING_PROFILE_B64`: base64 contents of the matching App Store distribution profile.

Produce single-line base64 values locally with `base64 -i path/to/file | tr -d '\n'`. Keep them out of source control. The workflow checks for missing names before signing, validates the profile's team, bundle ID, distribution type and expiry, and uses a temporary CI Keychain. Private keys, certificates and passwords are never uploaded as artifacts.

## Validate or publish

After the main commit passes both CI workflows, run **iOS release** manually from **main**, enter a numeric version and choose **validate**. This tests exact-commit gating and creates an unsigned archive without needing Apple secrets or uploading a build.

To publish, choose **testflight**, or push a tag such as `ios-v0.2.0` pointing to a green main commit. The release checks the source commit again, signs and exports with manual provisioning, and uploads using Apple's Transporter. The build number uses the release workflow run number and attempt. An upload means Apple has accepted the binary for processing; it does not assert that TestFlight processing, external beta review or App Store approval has completed.

App Store publication is not triggered by this workflow. An expired or missing signing credential fails the release clearly; it does not disable the normal simulator CI.
