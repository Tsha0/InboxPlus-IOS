# Inbox+ IOS

The iPhone and iPad app (`iOS/`) for Inbox+. It talks to the user's Mac through an authenticated
companion (`Sources/InboxPlusCompanion*`). `README.md` covers the architecture.

This repo carries a copy of the Mac app's shared modules, imported from `Tsha0/InboxPlus` at
`2b819ad`. Both copies have changed since: iOS portability changes here; favourites, notifications
and Sparkle there. A fix to a shared module usually needs porting to the other repo.

## Rules

- `AGENTS.md` holds the code review rules. Breaking one is a P1.
- The improvement loop's playbook lives in `Tsha0/InboxPlus` and covers this repo too:
  `docs/agents/loop.md`, `docs/agents/autonomy.md`, `docs/agents/learnings.md`, `.claude/skills/`.
  This repo's own PR conventions are in `.claude/skills/steward/SKILL.md`.
- Never use real network accounts. Tests use the loopback fixture companion.
- Never print or commit pairing keys, signing material or App Store Connect credentials.

## Build and test (macOS, Xcode 26.5)

```bash
swift test --enable-code-coverage                                         # shared, mobile, transport
INBOXPLUS_BUILD_COMPANION=1 swift test --scratch-path .build-companion    # full Mac companion
export INBOXPLUS_SIMULATOR_ID="$(python3 Scripts/ci/select-simulator.py --runtime 26.4.1 --family iPhone)"
bash Scripts/ci/test-ios.sh                                               # native unit and UI tests
```

`docs/ios-testing-and-release.md` has the details. Shared tests use Swift Testing; the native iOS
targets use XCTest.

## In a cloud container (Linux, no Swift or Xcode)

These checks run on Linux:

```bash
bash Scripts/ci/check-workflows.sh     # actionlint, script syntax, pipeline tests; required for workflow edits
python3 Scripts/ci/test-pipeline.py
git diff --check
```

CI checks everything else on the pull request: **iOS gate** (shared tests, iPhone and iPad
simulator suites, unsigned Release build) and **Companion gate**. Push, wait for the checks, and
report what CI showed. Never claim a test passed unless you saw it pass. Simulator runs upload
screenshots in their report artifacts.

## Releases

`ios-release.yml` runs on an `ios-vX.Y.Z` tag or a manual dispatch. It only ships a commit that
already passed iOS CI and Companion CI on `main`. Uploading to TestFlight needs the Apple settings
listed in `docs/ios-testing-and-release.md`.
