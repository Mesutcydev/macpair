# Vamp Stream adaptive app-window implementation — 2026-09-05

## Behavior

- Adaptive sizing preserves the pre-stream width of Codex, Cursor, Terminal, Claude, and unknown applications, bounded by the host display. Safari may narrow to 600 points or its original width, whichever is smaller.
- Layout uses the measured video viewport and retains proportional rendering. When matching the phone aspect would violate usable width, the app keeps that width and offers zoom/pan instead of compressing its layout.
- App-window orientation follows device rotation. The app picker and separate whole-display viewer retain their prior orientation policies.
- Sync debounces layout changes for 300 ms, serializes target operations, and waits out the host's existing two-second command limiter. Keyboard presentation does not request a new host aspect.
- Sync retains original window dimensions in a bounded, in-memory host cache. Original Size requests restore them subject to macOS/app/display constraints. AX resizing requires exactly one matching window; it never falls back to the focused window.
- New sizing metadata and acknowledgement are optional. Until support is acknowledged, the client omits the legacy aspect request so older Sync hosts do not perform the old narrow-window resize.
- Assistant uses its existing aspect-only resize API, drains earlier HTTP resizes, and invalidates superseded selections. Stream feedback has a fixed layout height to avoid a resize/notice feedback loop. Window rows use window identity even when multiple rows share a bundle identifier.
- Input is gated during resizing, host geometry transitions, backgrounding, lock, and decoded-video stalls. Drag locks are released on suspension. Decoder callbacks from superseded receive generations are discarded.
- Reconnect revalidates the exact application/window against the inventory and the same host fingerprint. Returning to Apps clears selection intent and refreshes the inventory; it does not quit the Mac app.

## Automated verification

- Full `swift test`: **604 tests passed**, including the final decoder callback ordering adjustment.
- Linux host tests: **24 passed** (`python3 -m unittest discover -s Tests -p 'test_linux_host.py'`); the Linux browser-chat test also passed.
- Vamp Stream simulator suite: **30 passed on iOS 26.5** after the final decoder adjustment. The same 30 tests also passed on iOS 27.0 before that adjustment.
- Release builds of **VampMiniHost, VampTerminalApp, and VampStream all passed** after the final changes.
- The sizing matrix exercises six profiles (the five requested apps plus unknown), seven viewport shapes, four host display sizes, and both orientations: 336 combinations. These are geometry tests, not visual/readability tests of the real applications.
- Regression tests cover stale/unsolicited window events, canceled selection, superseded resize requests, optional wire metadata, missing/ambiguous AX matches, host rate limiting, exact-window reconnect, drag suspension, and rotation policy.

Xcode initially failed to locate SwiftTermBuildInfoGenerator in its build cache. Rebuilding the generator from the checked-out dependency source into DerivedData resolved this without changing dependency source or tracked project files.

## Verification gaps and API limits

**The live usability acceptance criteria are not complete.** Do not interpret passing tests/builds as confirmation that each requested app is readable and comfortable on real iPhones.

- The iOS 27 simulator launched the app, but its accessibility tree was empty and automated taps did not advance the saved-host screen.
- A clean iOS 26.5 simulator exposed the onboarding controls to accessibility, but automated taps also did not advance selection. No authenticated app-window session was exercised through either simulator.
- Codex, Cursor, Terminal, Safari, and Claude still need live checks for keyboard visibility, dialogs, multi-window selection, accurate clicks, zoom/pan, movement between displays, rotation, lock/unlock, and network interruption. No app-window before/after screenshot comparison is claimed.
- No physical iPhone or iPad was used. iPad split-view coverage is numerical only.
- Vamp Assistant was not serving its control endpoint during inspection. Its API accepts an aspect ratio, not exact window dimensions or a target-window display identifier. Its recovery control is therefore labeled **Original proportions**, with explicit feedback that exact Original Size restoration requires host API support. Multi-display fitting uses conservative reported screen bounds and cannot guarantee an exact minimum width on an unknown Assistant implementation.
- The running installed host was not replaced with an unsigned build. Pairing, signing identities, Screen Recording/Accessibility grants, and terminal-session persistence were not changed.

## Remaining live acceptance run

On a trusted, updated Sync host and an available Assistant host, exercise each requested app on compact, standard, and large iPhones in portrait and landscape, and on an iPad split view. Record original/accepted bounds, capture dimensions, tap alignment, text usability, and constrained-fit feedback. Confirm that Original Size (Sync) restores the same window, that transitions release held input, that rapid rotations settle, and that reconnect never chooses a different window or the desktop. Keep any real user screenshots/logs outside the repository.

The temporary iOS 26.5 QA simulator was removed after testing. The pre-existing iOS 27 simulator was retained.
