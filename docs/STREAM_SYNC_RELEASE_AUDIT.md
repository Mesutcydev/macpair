# Vamp Stream and Vamp Sync release audit

Audit date: 2026-09-04. Scope: current working tree, including existing input-control edits. This is a source and build audit, not certification of an installed release. No host was installed, no pairing approved, and no permissions changed.

## Implementation update

The source fixes below are implemented in the working tree. The original findings are retained below as an audit trail, not an outstanding implementation list. Distribution remains gated on authenticated device testing; no host was installed, paired, or published.

- **Reliable input:** a bounded FIFO preserves command order, reports overflow explicitly and disconnects instead of silently discarding releases. The host releases held keys and buttons on attachment loss and after canceled input work drains.
- **Live revocation:** Sync invalidates the active attachment's authorization before awaiting teardown or persistence. In-flight offers are invalidated by trust revision. Terminal sessions retain their detach semantics.
- **Launch safety:** optional request IDs correlate replies; host launch operations are serialized and canceled when returning to applications. Session, cancellation and lock checks guard asynchronous work. Assistant selection rejects stale resize/launch results. Older hosts without request IDs retain legacy behavior; update both ends for full correlation.
- **Large inventories:** bounded pages stay within the control envelope budget, using a stable host snapshot, validated offsets and client accumulation. Icons are shed when necessary.
- **Onboarding:** QR failures present actionable, source-specific recovery, camera Settings and retry. Sync has a visible entry point and manual address connection.
- **Browser UX:** search, favorites, recents, window selection with titles, saved quality options, gesture help, drag release, stalled-video retry and reconnect actions. Assistant gains search and respects system appearance.
- **Keyboard and accessibility:** both remote views use local keyboard layout guidance, with docked-keyboard inset updates; Stream respects reduced motion. App rows use cached icon decoding and lazy sections.
- **Cleanup:** isolated obsolete picker branch, reduced routine logging, corrected documentation bundle ID without changing app identity, updated connection wording and added the missing Combine import. CI builds standalone Stream in Release.
- **Dependencies:** SwiftTerm is pinned to [1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0). Vendored Opus is updated to [1.6.1](https://opus-codec.org/downloads/) using verified upstream sources; provenance and the SBOM generator are updated. Four upstream integer-conversion warnings remain visible rather than being suppressed.

### Final verification

- Shared Swift suite: **588 passed**, including FIFO overflow/order, request correlation, oversized inventory paging and attachment identity regressions.
- Python suite: **32 passed**, including Linux compatibility tests.
- Stream unsigned Release device build: **passed**.
- Sync macOS Release and Terminal unsigned device Release builds: **passed**.
- Final Stream simulator suite: **14 passed**, zero failures (iPhone 17, iOS 27).
- Independent keyboard source review completed; safe-area handling and Reduce Motion findings are addressed.
- `git diff --check`: **passed**.

### Remaining release gates

Argent's simulator server failed to start, including a retry with the full Xcode developer directory. No live visual verification is claimed. Run authenticated Stream ↔ Sync tests on iPhone and iPad: rapid app switching/cancel, launch while locking or disconnecting, input under backpressure, live revoke followed by rejected input/reconnect, keyboard modes, rotation, accessibility, camera denial/recovery and adverse-network recovery. Test the minimum supported OS. Verify installed Sync signing/permission continuity and final artifact checksums/manifests before distribution. Unit tests do not substitute for these device checks.

## Original release assessment (before implementation)

**Hold broad release until the high-priority items below are resolved and an authenticated device smoke test passes.** The focused app-stream experience is implemented, but input delivery and live revocation need stronger guarantees. Physical-device streaming, permission continuity across a Sync update, camera onboarding, and adverse-network recovery remain release gates.

## Fixes included in this audit

1. **Refresh recovery:** `AppStreamViewModel.sendListRequest` previously abandoned retries whenever cached applications existed. A dropped refresh therefore left `.loadingApps` unresolved. Retries now depend on the pending loading state, while cached apps stay visible.
2. **Cancel navigation:** `AppStreamViewModel.apply` ignores launch responses after the user returns to the browser or stops the model. Previously a late completion reopened the stream. Two regression tests cover late completion and acceptance. This is a local navigation safeguard; request correlation across consecutive launches remains a follow-up below.
3. **Sync connection feedback:** the Stream root now passes the session coordinator's error into the existing picker error banner. Previously only Assistant errors reached that banner.
4. **Device-management feedback:** Sync now presents storage failures from Revoke and Pair Again instead of suppressing them with `try?`.
5. **Accessibility wording:** the app-browser close action now describes returning to the Mac picker rather than the discontinued Vamp Host picker.
6. **Release CI coverage:** CI now builds the standalone Vamp Stream device target in Release. Its dedicated sources are outside the shared ClientiOS SwiftPM target and were not built by the existing CI workflow.

## Original findings (addressed by implementation above)

| Priority | Finding and evidence | Required follow-up |
| --- | --- | --- |
| P1 | **Input events can be silently discarded under backpressure.** `Sources/VampStream/AppStreamInputController.swift`, `startSenderIfNeeded`, uses `.bufferingNewest(128)` for key, button, text and motion messages together. `enqueue` ignores the yield result. A slow sender can evict a mouse-up/key-up, leaving a held button or modifier on the Mac. | Preserve discrete events in order; coalesce only replaceable motion. Define an explicit overload/disconnect policy and test with a suspended sender and more than 128 commands, including final releases. |
| P1 | **Revoke does not explicitly end an active attachment.** Sync's `revoke` updates `PersistentTrustedPeerStore`; `PeerTrustGate` checks that store during connection approval. The UI path does not disconnect the revoked peer or invalidate its active control authorization. | Track the active authenticated peer identity and revoke its live authorization immediately. Detach affected transport without violating persistent-terminal rules. Test revocation during input, continued packet rejection, and reconnect refusal. Until implemented, Stop Host is the explicit way to end current access. |
| P2 | **Launch operations have no request correlation.** `StreamTargetSwitchResultMessage` has session identity but no request identifier echoed from the request. After canceling A and selecting B, a delayed result from A can be consumed while B is launching. The router also awaits the entire app-launch operation before servicing subsequent control messages. | Add backward-compatible request correlation and a bounded cancellation mechanism. Test A → Cancel → B, disconnect during launch, and host lock during launch. The included browser-state guard fixes only responses received outside a live launch/stream. |
| P2 | **QR failure can leave an inert scanner and misleading instructions.** `BeetCodeQRScannerView.startScanningIfPossible` catches startup failures without presenting the unavailable controller. The fallback text assumes an Assistant six-digit code even when opened for Sync. | Surface startup/runtime failures, use source-specific manual-entry instructions, and offer a Settings action for denied camera access. Test first launch, denial, restrictions and unsupported hardware. |
| P2 | **Assistant selection can race.** In `VampAssistantAppStreamView.open`, the already-running-window branch awaits resizing without setting `launchingName`, so rows remain enabled and multiple selections can race. The resize task also publishes results without a post-await cancellation/selection check. | Serialize selection, reject stale responses and suppress cancellation errors. Test two rapid taps and returning to apps while resize is pending. |
| P2 | **Keyboard positioning assumes the whole screen.** `AppStreamBrowserView` derives keyboard padding from `UIScreen.main.bounds` instead of the current view/window coordinate space. | Use scene-local geometry or keyboard layout guidance, then verify iPad multitasking, floating keyboard, rotation and external keyboard. Source finding; visible overlap was not reproduced in this audit. |
| P2 | **Oversized app inventories still have no guaranteed bounded fallback.** `HostSessionCoordinator.applicationListEnvelope` removes icons, but returns the last envelope even if names/identifiers alone exceed its byte budget. | Page or chunk inventories with bounded validated counts; test a synthetic inventory exceeding the control-message limit without icons. |

## Original UI and UX proposals

These are code-derived proposals, not claims from a completed visual usability study.

- **Make Sync a first-class connection option.** The picker foregrounds Assistant and labels Sync discovery “OTHER APP-STREAM HOSTS.” Give both supported sources clear, equal entry points and explain which Mac app each requires.
- **Add app search and recent/favorite apps.** The Sync browser currently renders running and installed applications as complete lists; search is the highest-value navigation addition for a Mac with many apps.
- **Offer window selection.** `RemoteApplication.windowIDs` already carries multiple windows, but the UI selects an application. A window chooser would avoid opening the wrong document or terminal.
- **Expose quality and connection state.** Stream promotes quality at launch and has no general quality screen. Offer Auto, sharper text and lower bandwidth settings, with visible reconnecting/stalled status and a retry action.
- **Teach gestures at first use.** Explain tap, right-click, scroll, zoom and drag lock in a dismissible help sheet. Show drag-lock state and an explicit release action.
- **Audit accessibility on devices.** Verify Dynamic Type, VoiceOver traversal, touch target sizes, reduced motion/transparency, contrast, and iPad landscape. Stream's Assistant browser forces dark appearance; decide whether that is a product choice or should respect system appearance.

## Original cleanup proposals

- Extract app rows into small view types and cache decoded icons; `AppStreamBrowserView.icon(for:)` currently decodes base64 and image data during view construction. Use lazy list sections for large inventories.
- Remove or clearly isolate the gated Remote Control picker branch. It binds selection to `.constant(.remoteControl)`, so simply enabling its flag would not produce a functioning destination selector.
- Replace stale host names in shared connection errors and comments. Keep historical wire identifiers intact.
- Reduce per-envelope informational logging in `AppStreamViewModel.handle`; retain actionable failures and bounded diagnostics.
- Reconcile the Stream bundle-ID entry in `AGENTS.md` (`com.mesutcydev...`) with the project and unsigned packager (`com.mesutcy...`). Do not rename the installed identity as a cleanup task.
- Keep dependency upgrades in isolated changes with compatibility tests; this audit does not assert that pinned third-party versions are current or perform an external vulnerability audit.

## Initial audit validation (before implementation)

Builds use `/Applications/Xcode-beta.app` explicitly because the machine's default developer directory points to Command Line Tools.

- Linux compatibility suite: **24 tests passed**.
- Swift shared suite: **583 tests passed**, including both new late-launch-response regressions.
- Release device build, Vamp Stream: **passed**, unsigned.
- Release macOS build, Vamp Sync (`VampMiniHost`): **passed**, signing disabled for verification.
- Release device build, Vamp Terminal (shared-source consumer): **passed**, unsigned; an incremental confirmation also exited 0 with an empty diagnostic log. The first build produced an inconsistent compiler “failed with exit code 0” diagnostic and existing missing-Combine-import warnings in `VampTerminalWorkspaceView.swift`; that import remains a cleanup item.
- Stream-specific simulator tests: **14 passed**, zero failures/skips/runtime warnings in the Xcode result summary (iPhone 17 simulator, iOS 27).
- Four inspected app/entitlement plists parse successfully; `git diff --check` passed. The workflow addition was reviewed as text (PyYAML is unavailable).
- Live UI automation: **blocked**. Argent listed no devices; Xcode's simulator inventory confirmed a booted iOS 27 iPhone, but Argent's simulator-server failed to start for that device. No visual pass is claimed.
- No release artifact was packaged or sideloaded, so IPA/DMG checksums, manifests, signing behavior and permission continuity were not verified.

Before release, run an authenticated Stream ↔ Sync smoke test on iPhone and iPad: pair by independently comparing fingerprints, launch a cold app, choose an existing app, type and drag, return to apps, rotate, background/foreground, lock/unlock, revoke, and recover after network loss. Test on the minimum supported OS as well as the current SDK. Package from the final reviewed tree and verify each artifact's manifest/checksum before distribution.
