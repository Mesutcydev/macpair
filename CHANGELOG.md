# Changelog

All notable changes to ScreenHarbor are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Make website release staging idempotent when ScreenHarbor is already marked live.
- Keep website checksum, manifest, SBOM, and software-version links synchronized
  with each staged release.
- Make future-device Ultra-quality policy tests independent of the CI runner's
  hardware HEVC decoder.

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

[Unreleased]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Mesutcydev/screenharbor/releases/tag/v1.0.0
