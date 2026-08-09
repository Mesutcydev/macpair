# Changelog

All notable changes to Vamp Terminal are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Refresh the Vamp Terminal, Vamp Host, and website icon with the supplied glass terminal mark.
- Bump the Vamp Terminal sideload build to build 2.

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

[Unreleased]: https://github.com/Mesutcydev/macpair/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/Mesutcydev/macpair/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/Mesutcydev/macpair/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Mesutcydev/macpair/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Mesutcydev/macpair/releases/tag/v1.0.0
