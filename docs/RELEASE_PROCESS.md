# Release process

ScreenHarbor releases are built from a clean, committed source tree. The direct
Mac website channel is ad-hoc signed and is not Apple-notarized. The iOS IPA is
unsigned and must be re-signed by the installer's sideloading tool.

## Prepare

1. Update `CHANGELOG.md`, versions, documentation, and dependency locks.
2. Run `swift test`.
3. Regenerate the Xcode project and build both macOS app schemes with signing disabled.
4. Build the `ScreenHarborIOS` scheme for a generic iOS device with signing disabled.
5. Run the client scheme tests.
6. Review `git diff`, secret scanning results, dependency notices, and the provenance
   attestation in `PROVENANCE.md`.
7. Commit and tag the exact release source as `vX.Y.Z`.

## Package

From the clean tagged commit:

```bash
scripts/package-screenharbor.sh all --format both --clean --release
scripts/package-screenharbor-ios.sh --clean
```

The packaging script:

- makes universal host and client applications;
- embeds license notices;
- ad-hoc signs the bundles and DMGs;
- creates SHA-256 checksum files;
- records the source commit and tree state in JSON manifests; and
- generates a CycloneDX SBOM for every artifact.

The iOS script creates an unsigned, arm64 IPA for a sideload tool to re-sign. It
also creates a checksum, source manifest, and CycloneDX SBOM, and refuses a dirty
tree unless `--allow-dirty` is explicitly used for development.

Packaging with `--release` refuses a dirty tree, a missing commit, or a version that
does not match the `vX.Y.Z` tag.

## Verify

Mount each DMG, verify its app bundle with `codesign --verify --deep --strict`, and
test launch, pairing, permissions, screen control, input, clipboard, file transfer,
terminal opt-in, and uninstall on supported macOS versions.

Compare every artifact with its `.sha256` file. Inspect its `.manifest.json` and
`.sbom.cdx.json`; the source commit must match the release tag.

## Publish

```bash
scripts/publish-screenharbor.sh --release
```

Review and commit the website diff through its normal deployment workflow. Create a
GitHub release from the same tag and attach the binaries, checksums, manifests, and
SBOMs. Never upload private code-signing keys.

## Future Developer ID channel

If an eligible Apple Developer account becomes available, add a separate documented
Developer ID and notarization pipeline. Do not mark artifacts as notarized unless
`spctl` and Apple notarization evidence verify that exact artifact.
