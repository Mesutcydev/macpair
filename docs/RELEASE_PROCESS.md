# Release process

<<<<<<< HEAD
MacPair releases are built from a clean, committed source tree. The direct
Mac website channel is ad-hoc signed and is not Apple-notarized. The iOS IPA is
unsigned and must be re-signed by the installer's sideloading tool.
=======
Vamp releases are built from a clean, committed source tree. The iOS IPA is
unsigned and must be re-signed by the installer's sideloading tool. The two
macOS hosts are local utilities: Vamp Host is the complete host, while Vamp
Terminal Host is the terminal-only variant.
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)

## Prepare

1. Update `CHANGELOG.md`, versions, documentation, and dependency locks.
2. Run `swift test`.
3. Build `MacHost` and `VampTerminalHost` from `RemoteDesktopToolApps.xcodeproj` with signing disabled.
4. Build the `VampTerminalApp` scheme for a generic iOS device with signing disabled.
5. Run `swift test --parallel` and the Linux host tests.
6. Review `git diff`, secret scanning results, dependency notices, and the provenance
   attestation in `PROVENANCE.md`.
7. Commit and tag the exact release source as `vX.Y.Z`.

## Package

From the clean tagged commit:

```bash
scripts/package-vamp-terminal-ios.sh --clean
```

The iOS packaging script:

- builds an arm64 device IPA;
- creates SHA-256 checksum files;
- records the source commit and tree state in JSON manifests; and
- generates a CycloneDX SBOM.

The iOS script creates an unsigned, arm64 IPA for a sideload tool to re-sign. It
also creates a checksum, source manifest, and CycloneDX SBOM, and refuses a dirty
tree unless `--allow-dirty` is explicitly used for development.

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
