# Contributing

Thanks for helping improve MacPair.

## Development setup

1. Use macOS 13 or later with Xcode 26 or later.
2. Install XcodeGen: `brew install xcodegen`.
3. Run `xcodegen generate --spec screenharbor-project.yml`.
4. Build both schemes with ad-hoc signing:

   ```bash
   xcodebuild -project MacPair.xcodeproj -scheme ScreenHarborHost \
     -configuration Debug CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

   xcodebuild -project MacPair.xcodeproj -scheme ScreenHarborClient \
     -configuration Debug CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
   ```

5. Run `swift test` and the `ScreenHarborClient` scheme's tests before opening a pull request.

## Pull requests

- Keep changes focused and explain their security impact.
- Add tests for protocol, trust, path-sanitization, or reconnect changes.
- Never commit private keys, signing certificates, provisioning profiles, API credentials, pairing secrets, or real user logs.
- Do not weaken visible host approval or fingerprint verification for convenience.
- User-facing behavior should remain usable with VoiceOver, keyboard navigation, Reduce Motion, and Reduce Transparency.
- Update `CHANGELOG.md` for a user-visible change.
- Add a `Signed-off-by` trailer to every commit to certify the
  [Developer Certificate of Origin](DCO.md).

Contributions are accepted under Apache-2.0, as described by the repository license.
By signing off a commit, you certify that you have the right to submit it under that
license. The project does not require a copyright assignment.

## AI-assisted contributions

AI tools and coding agents are welcome when they improve a contributor's work, but a
human contributor remains responsible for every submitted line. Review generated
changes, run the relevant tests, verify licenses and provenance, and describe
material AI assistance in the pull request. Agents must follow [AGENTS.md](AGENTS.md)
and must not weaken pairing approval, expose secrets, or submit speculative security
reports without a reproducible technical finding.

## Review and decision process

At least one maintainer approval and passing required checks are required before
merge. Security-sensitive changes should receive review from a maintainer familiar
with the affected trust boundary. Governance and maintainer succession are described
in [GOVERNANCE.md](GOVERNANCE.md).
