# Changelog

All notable changes to MacPair and Vamp Terminal are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Enforce browser terminal capacity before opening a tab and roll back pending
  tabs when the host rejects an open request.

### Changed

- Group browser terminal keys and session controls, and size the terminal
  viewport to keep the workspace usable across screen sizes.
- Make the Vamp Terminal home screen connection-first, with a more subdued
  light-mode backdrop.

## [2.1.1] - 2026-08-14

### Fixed

- Drop the orphaned Sparkle (and swift-argument-parser) pins from `Package.resolved`
  so the dependency lock matches the real graph (SwiftTerm only). The Vamp Control
  macOS client no longer resolves or embeds Sparkle, removing the launch-time
  library-validation crash caused by the framework's mismatched Team ID.
- Pi and CommandCode now answer Chat prompts through machine-readable adapters
  instead of silently ignoring them in chat mode.
- Collapse the workspace row and tab strip while the mobile keyboard is open so
  the composer no longer floats over the conversation.

### Security

- Enforce the freshness timestamp for every authenticated data-channel command
  in one gate instead of relying on each handler to remember the check.
- Keep signaling envelope IDs for the full replay window plus clock-skew
  allowance, closing a replay gap for future-dated envelope IDs.
- Throttle browser pairing guesses per remote IP instead of globally, and rotate
  the pairing code once an address exhausts its guess budget.
- Draw browser pairing codes and tokens from `SecRandomCopyBytes` explicitly.
- Move the browser WebSocket bearer token out of the URL query into the
  `Sec-WebSocket-Protocol` handshake header (macOS host and Linux host), so it
  no longer leaks into browser history, referrers, or logs.
- Add a client→PTY input byte budget mirroring the existing output budget.

### Changed

- Refresh the Vamp Terminal, Vamp Host, and website icon with the supplied glass terminal mark.
- Bump the Vamp Terminal sideload build to build 3 after the release rebase and host hardening audit.
- CI: run the core suite on an arm64 runner and build the unsigned iOS device
  slice on every run; run all test suites before packaging a release; verify
  release checksums round-trip and fail loudly when the SBOM generator is missing.

## [2.1.0] - 2026-08-14

### Added

- Vamp Suite 2.1: unified clients and terminal hosts, terminal workspace and
  semantic chat overhaul, unified Vamp interface design.
- Agent CLI resolution outside Homebrew paths.

### Security

- Require a verified `--fingerprint` for every `vamp approve-*` action and make
  `vamphost://` approval links inert (fingerprint-bound approval only).
- Wire the Linux host and browser VT test suites into CI.

### Fixed

- Broken download links on thevamp.app.
- Safari terminal ready routing; terminal chat stability.
- iOS terminal error banner no longer overlaps content; clearer missing-tool text.

## [1.0.10] - 2026-08-04

### Fixed

- Normalize SDR screen capture to sRGB, BT.709, and full-range pixels before
  encoding, and carry matching color metadata through VideoToolbox so dark UI
  content is not rendered with a faded low-contrast veil.
- Keep the iOS and Mac client decoders on the same sRGB transfer-function
  contract for SDR frames.

## [1.0.9] - 2026-08-03

### Changed

- Rename the public product to MacPair with shorter installed app names and
  clearer open-source Mac remote desktop positioning.
- Keep the `screenharbor` CLI, bundle IDs, URL scheme, Bonjour service, and
  persisted storage identifiers compatible with existing installations.

## [1.0.8] - 2026-08-03

### Fixed

- Keep Mac and iOS client EDR presentation synchronized with the decoded frame's
  actual dynamic range, so an SDR fallback is not displayed with HDR tone mapping.
- Tag decoded SDR frames as BT.709 for consistent color interpretation in the
  sample-buffer display layer.

## [1.0.7] - 2026-08-02

### Fixed

- Stop the Host Screen Recording prompt storm: status polls no longer call
  `SCShareableContent` while unauthorized (that API itself presents the system
  sheet), automatic refresh never opens CG/AX dialogs, and each permission
  kind may show at most one OS prompt per process from an explicit Fix/Open
  Settings action.

## [1.0.6] - 2026-08-02

### Changed

- Remove the Mac client reconnect dimming scrim so the last remote frame
  stays full brightness while reconnecting; the reconnect card still appears.

## [1.0.5] - 2026-07-31

### Fixed

- Stop treating a transient ScreenCaptureKit probe error as Screen Recording
  denial, so the Host reads an approval that CoreGraphics already sees
  (common right after granting permission from the 1.0.4 DMG).
- Re-check Host permissions when returning to the app and while setup
  blockers remain, and re-prompt Accessibility as well as Screen Recording
  after an ad-hoc binary identity change.

## [1.0.4] - 2026-07-31

### Fixed

- Detect when an ad-hoc Host rebuild invalidates Screen Recording /
  Accessibility grants, re-prompt for the new binary, and tell the operator
  how to remove the stale System Settings entry.

### Changed

- Give ScreenHarbor Host and ScreenHarbor distinct macOS app icons (bloodbag
  host, fang client), with matching splash artwork.

## [1.0.3] - 2026-07-29

### Added

- Add the open-source Vamp Terminal iPhone/iPad client for iOS 18 and later.
- Add reproducible unsigned IPA packaging with SHA-256, source manifest, and
  CycloneDX SBOM output for user-controlled sideload re-signing.
- Add iOS sideloading and agent-discovery documentation.

### Changed

- Use the Vamp bundle identity and the existing `_screenharbor._tcp` discovery contract
  contract throughout the iOS client.
- Remove the obsolete App Store paywall and daily streaming cap from the
  direct/open-source iOS build.

### Fixed

- Make website release staging idempotent when the Vamp site is already marked live.
- Keep website checksum, manifest, SBOM, and software-version links synchronized
  with each staged release.
- Make future-device Ultra-quality policy tests independent of the CI runner's
  hardware HEVC decoder.
- Align CodeQL action pins and use its no-build C/C++ mode to remove workflow
  compatibility warnings.
- Install the Metal build component in CodeQL and include the iOS client in the
  audited Swift target set.
- Keep direct-distribution settings local so iOS launch does not require an
  unavailable iCloud KVS entitlement.

## [1.0.2] - 2026-07-29

### Fixed

- Pin OpenSSF Scorecard to the dereferenced v2.4.3 commit so its provenance
  verifier accepts the workflow action.
- Remove the Sparkle runtime, update controls, feed metadata, packaging hooks, and
  release metadata. This prevents launch-time failures when macOS rejects the
  bundled Sparkle framework signature in an ad-hoc distributed app.

## [1.0.1] - 2026-07-29

### Fixed

- Commit the complete application dependency lock, including Sparkle 2.9.4, so
  release packaging does not dirty the source tree.
- Recheck source-tree cleanliness after packaging before allowing publication.
- Update SwiftTerm to 1.15.0 and refresh pinned GitHub security actions.

## [1.0.0] - 2026-07-29

### Added

- Public macOS host and client applications for direct website distribution.
- Local-first discovery, approved peer pairing, screen and input control, clipboard
  sync, file transfer, audio, and opt-in terminal access.
- Agent-safe CLI, machine-readable manifest, and LLM discovery documentation.
- Reproducible dependency locks, release manifests, checksums, and CycloneDX SBOMs.
- Community governance, security, contribution, support, and trademark policies.

[Unreleased]: https://github.com/Mesutcydev/macpair/compare/v2.1.1...HEAD
[2.1.1]: https://github.com/Mesutcydev/macpair/releases/tag/vamp-suite-2.1.1-build-34
[2.1.0]: https://github.com/Mesutcydev/macpair/releases/tag/vamp-suite-2.1.0-build-33
[1.0.10]: https://github.com/Mesutcydev/macpair/compare/v1.0.9...v1.0.10
[1.0.9]: https://github.com/Mesutcydev/macpair/releases/tag/v1.0.9
[1.0.8]: https://github.com/Mesutcydev/macpair/releases/tag/v1.0.8
[1.0.7]: https://github.com/Mesutcydev/macpair/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/Mesutcydev/macpair/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Mesutcydev/screenharbor/releases/tag/v1.0.0
