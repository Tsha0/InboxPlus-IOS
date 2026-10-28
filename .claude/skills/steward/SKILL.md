---
name: steward
description: Drive a Tsha0/InboxPlus-IOS pull request to green and mergeable — failing CI, review comments, merge conflicts. Repo-specific conventions for whoever is watching a PR here.
---

# Steward — InboxPlus-IOS

## Required checks

- **iOS gate** (`ios-ci.yml`) passes only when all of these do: *Shared and mobile unit tests*,
  *iOS tests (iPhone)*, *iOS tests (iPad)*, and *Unsigned iOS Release build*. When it fails, read
  the failing job underneath it, not the gate.
- **Companion gate** (`companion-ci.yml`): the full Mac companion test and build, with
  `INBOXPLUS_BUILD_COMPANION=1`.

## Reading a failure

- Test and build output goes to files under `build/`, not to the step log. Each job has a
  **Show failure summary** step that prints the failing lines and the end of those files. Read
  it first.
- The full reports are run artifacts (`shared-test-reports`, `ios-<family>-reports`,
  `companion-test-report`, `ios-release-build-log`). Simulator reports include screenshots: look at
  them before changing UI code.
- *Validate workflows and pipeline gates* failed: run `bash Scripts/ci/check-workflows.sh` (it
  works on Linux) and fix what actionlint reports.
- Simulator selection failed: the runner image changed its installed runtimes. That is
  infrastructure. Check whether `main` fails the same way, then file `ci-infra` instead of
  editing tests.
- Hosted simulators are slow, especially at first boot. Wait on real element state with
  `waitForExistence` and the predicate helpers in `iOS/InboxPlusIOSUITests/Support/UITestCase.swift`,
  never with `sleep`.
- `cancelled` means a newer push superseded the run. Look at the newest run.

## Conventions

- Workflow edits: actions stay pinned to full commit SHAs with the version in a comment, every job
  keeps a `timeout-minutes`, and `check-workflows.sh` must pass.
- Squash merge. Resolve conflicts by merging `main` into the branch. Never force-push.
- Real credentials never go in the fixture or the tests. The fixture's fault operations (such as
  the `fixture-fail-once:` prefix) never go in the real companion.
- If the change touches a shared module, the PR says whether `Tsha0/InboxPlus` needs it too.

## When to stop

After three failed attempts to fix the same check, comment your diagnosis and what you tried,
label the PR `needs-human`, and stop.
