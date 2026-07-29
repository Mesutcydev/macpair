# Source and asset provenance

ScreenHarbor is published from this repository under Apache-2.0. Release artifacts
must identify the exact source commit, dependency lock, checksum, code-signing mode,
and notarization state.

## Maintainer release attestation

Before the first public repository or binary release, the releasing maintainer must
confirm in the release pull request that:

- they have the right to publish the submitted source and original assets;
- no confidential employer, client, or third-party material is included;
- third-party code and assets are covered by `THIRD_PARTY_NOTICES.md` or a clearly
  compatible license;
- no private keys, certificates, tokens, production logs, or personal data are
  present; and
- the public history does not misrepresent authorship or origin.

This repository cannot independently prove ownership of material that existed before
its first public commit. The maintainer attestation and repository history provide
the auditable record.

## Initial publication attestation

On 2026-07-29, the releasing maintainer
[@Mesutcydev](https://github.com/Mesutcydev) confirmed:

> I confirm I have the right to publish the staged source and assets under
> Apache-2.0, and that no confidential employer, client, or unauthorized
> third-party material is included.

The initial public commit is DCO-signed-off by the same authenticated GitHub
identity. This attestation covers the source and assets in that commit; later
contributions require their own DCO sign-off.

## Dependencies

- Opus 1.4 source is vendored under `Sources/Copus`; its BSD license and vendoring
  record are included in that directory.
- SwiftTerm, its transitive Swift Argument Parser dependency, and Sparkle are
  locked in the committed `Package.resolved` file.
- Sparkle is additionally pinned to exact version 2.9.4 in the authoritative
  XcodeGen specification, `screenharbor-project.yml`.
- Complete notices are in `THIRD_PARTY_NOTICES.md` and are copied into packaged
  applications.

## Project artwork

The ScreenHarbor icon set was generated for this project with OpenAI image tooling
and selected and adapted by the maintainer on 2026-07-29. It was not intentionally
copied from a third-party logo. To the extent the project holds rights in those
files, they are distributed under Apache-2.0 with the rest of the repository. This
statement is not a guarantee of trademark uniqueness.

## Release evidence

The supported release process is documented in
[RELEASE_PROCESS.md](RELEASE_PROCESS.md). Generated checksums, JSON manifests, and
CycloneDX SBOMs are published beside each binary.
