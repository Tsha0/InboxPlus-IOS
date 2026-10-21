# Inbox+ IOS

## Code Review Rules

Treat a violation of any rule below as P1.

- The iOS app is a client of the user's Mac. It never embeds Synapse, downloaded bridge executables,
  AppleScript or the Messages database, and no change introduces an operated Inbox+ cloud service.
- The default package has no third-party dependencies. The Matrix SDK and desktop targets build only with
  `INBOXPLUS_BUILD_COMPANION=1`, and the SDK is imported only in `InboxPlusMatrix`.
- The phone reaches the companion over HTTPS. Plain HTTP is accepted only for loopback hosts, for
  simulator testing, and certificate validation is never bypassed.
- Pairing credentials are stored in the Keychain as device-only
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), and local data is cleared on unpair. The pairing key
  is never printed or logged.
- The companion listener binds only to loopback, requires the bearer key on every request, and bounds
  request sizes. Media transfers stay within the 25 MB mobile limit.
- Workflow changes pass `Scripts/ci/check-workflows.sh`.
