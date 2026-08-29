# Release process

Vamp releases are built from a clean, committed source tree. The iOS IPAs are
unsigned and must be re-signed by the installer's sideloading tool. The macOS
hosts are local utilities: Vamp Host is the complete host, Vamp Terminal Host
is the terminal-only variant, and Vamp Sync is the pairing-first menu-bar
variant. Vamp Assistant remains a separate compatible control surface on port
9575.

## Prepare

1. Update `CHANGELOG.md`, versions, documentation, and dependency locks.
2. Run `swift test`.
3. Build `MacHost`, `VampTerminalHost`, and `VampMiniHost` from `RemoteDesktopToolApps.xcodeproj` with signing disabled.
4. Build the `VampTerminalApp` and standalone `VampStream` schemes for a generic iOS device with signing disabled.
5. Run `swift test --parallel` and the Linux host tests.
6. Review `git diff`, secret scanning results, dependency notices, and the provenance
   attestation in `PROVENANCE.md`.
7. Commit and tag the exact release source as `vX.Y.Z`.

## Package

From the clean tagged commit:

```bash
scripts/package-vamp-terminal-ios.sh --clean
scripts/package-vamp-stream-ios.sh --clean
scripts/package-vamp-mini-host.sh --clean
```

The packaging scripts:

- build arm64 device IPAs for Vamp Terminal and Vamp Stream;
- build and ad-hoc sign the Vamp Sync DMG;
- creates SHA-256 checksum files;
- records the source commit and tree state in JSON manifests; and
- generates a CycloneDX SBOM.

The Vamp Terminal and Vamp Stream scripts create unsigned, arm64 IPAs for a
sideload tool to re-sign. Their app bundles contain no provisioning profile,
code signature, or project-owned entitlements; Local Network access is declared
through `Info.plist` because the Bonjour discovery contract does not require a
team-managed entitlement. The Vamp Sync packaging script creates an ad-hoc signed DMG for
local macOS distribution. All scripts create checksums, source manifests, and
CycloneDX SBOMs, and refuse a dirty tree unless `--allow-dirty` is explicitly
used for development.

Packaging with `--release` refuses a dirty tree, a missing commit, or a version that
does not match the `vX.Y.Z` tag.

## Verify

Verify both macOS app bundles with `codesign --verify --deep --strict` when signed,
then test launch, pairing, Tailscale access, terminal tabs, clipboard, Safari
control, agent handoff, and uninstall on supported macOS versions.

Compare every artifact with its `.sha256` file. Inspect its `.manifest.json` and
`.sbom.cdx.json`; the source commit must match the release tag.

## Publish

Commit the website diff and publish `docs/` through the GitHub Pages workflow. Create
a GitHub release from the same tag and attach the IPA, checksum, manifest, and SBOM.
Never upload private code-signing keys.

## Future Developer ID channel

If an eligible Apple Developer account becomes available, add a separate documented
Developer ID and notarization pipeline. Do not mark artifacts as notarized unless
`spctl` and Apple notarization evidence verify that exact artifact.
