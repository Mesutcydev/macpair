# Vamp Control and Sync work in progress

Updated 2026-09-03. This checkpoint continues the uncommitted handoff based on
`8d0eefa` on `claude/vamp-macos-app-updates-03cace`.

## Current changes

- Preserves the handoff's Mac host-list design, nicknames, quality migration,
  reconnect capability preservation, and app-streaming picker/input mapping.
- Gives Vamp Sync a custom template vector V mark, shared with its panel badge.
  Refines panel typography, spacing, pairing hierarchy, permissions, and footer.
  The ready state no longer repeats a separate status card. Fingerprints are
  grouped visually without shortening them; copying retains the original value.
- Allows Sync status-item activation without an `NSApp.currentEvent`, including
  accessibility actions. Secondary mouse clicks still open the context menu.
- Gives each Assistant connection a stable instance ID. Reconnecting to the same
  address refreshes the renderer and input adapter, while a status refresh retains
  the existing ID. Stops queued input and clears the adapter on teardown.
- Counts both H.264 and JPEG decoded frames in Assistant FPS statistics and clears
  the measurement on a transport error.
- Routes the focused Assistant session to the Disconnect menu command. Separates
  access-mode and stats toolbar actions so both work in AppKit's overflow menu.

## Verified

| Check | Result |
| --- | --- |
| Swift package | 573 tests passed |
| MacClient Debug test | 19 tests passed |
| Linux host | 24 tests passed |
| MacHost Debug | Build passed |
| VampTerminalHost Debug | Build passed |
| VampMiniHost Debug | Build passed |
| VampStream Debug, iOS Simulator | Build passed |
| Diff whitespace | Passed |
| Assistant pairing | Paired through the normal one-time-code UI |
| Assistant native video | Live 2560×1440 frames, approximately 24 FPS observed |
| Assistant reconnect | Connected again using its saved pairing |
| Assistant disconnect shortcut | Shift-Command-D returned to the host list |
| Assistant toolbar overflow | View Only disabled remote app switching; the menu changed to Enable Full Control. Hide Connection Stats removed the live metrics |
| Sync discovery and approval gate | Locally built host advertised and displayed the real device approval prompt |
| Sync panel | Inspected the custom brand mark, pairing layout, full grouped fingerprints, permission rows, and scrollable device section in the live dark panel |

## Still blocked or unverified

- The local Sync build reports missing Screen Recording and Accessibility.
  These require the user's normal macOS consent. No permission was bypassed.
- The test client is not approved in Sync. The test request was canceled after
  inspecting the gate. AGENTS.md requires an independently verified complete
  device fingerprint before approval.
- Sync application inventory, window capture, pointer mapping, and the Mac
  WebRTC session toolbar remain unverified end to end.
- Sync's ready state with granted permissions, light appearance, and direct
  VoiceOver status-item activation have not been exercised live in this run.
  Their code compiles; that is not a substitute for a live check.
- Assistant's JPEG FPS fallback and simultaneous re-pair during a live view have
  been reviewed and built, but not exercised against a live server in this run.

No release was published, no download links were changed, and build numbers have
not been bumped. Both connection paths must pass before preparing publication.

## Reproduce

Run from `.claude/worktrees/vamp-stream-promo-material-1518ea`.

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodegen generate --spec macclient-project.yml
xcodebuild -project MacClient.xcodeproj -scheme MacClient \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
swift test
python3 -m unittest discover -s Tests -p test_linux_host.py
```

Build each host scheme from `RemoteDesktopToolApps.xcodeproj`. For Stream,
regenerate `VampStream.xcodeproj` with `xcodegen generate --spec vampstream-project.yml`
and build `VampStream` with `-sdk iphonesimulator` and
`-destination 'generic/platform=iOS Simulator'`.

Local validation products and logs for this run are in
`/tmp/vamp-control-handoff/`. They are not committed. The client app is under
`Client/Build/Products/Debug/Vamp Control macOS.app`; Sync is under
`Hosts/Build/Products/Debug/Vamp Mini Host.app`.

## Sync glass and site update — September 3

- Added original blue/ivory loggia artwork and native Liquid Glass surfaces to
  Sync, with material fallbacks and Reduce Transparency support.
- Retained the custom vector menu-bar V, added Control + Stream pairing copy,
  and advanced Sync to build 54, Control macOS to 49, and Stream to 20.
- Made Sync the public Mac host at `/sync/`, retired the full-host promotion,
  redirected `/mini-host/`, and updated English/Turkish copy and machine metadata.
- Replaced cropped image files with full simulator captures and contain sizing.
- Debug builds: Sync, MacHost, Terminal Host, and Stream passed. Existing release
  metadata tests passed. Desktop/mobile site, language switch, and dark theme
  checked in the browser. Earlier connection/test results above still apply.
- The final native glass visual check requires an unlocked Mac; the computer-use
  tool reported the local Mac locked. No permissions or pairing were bypassed.
