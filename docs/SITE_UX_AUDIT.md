# Website and GitHub audit — 3 September 2026

## Product navigation

| Before | After | Why |
| --- | --- | --- |
| Four product names before installation guidance | Sync → choose one client → pair | Explains what goes on each device before asking visitors to choose |
| Assistant and Stream led the product cards; Control sat below | Control and Stream have equal, adjacent choices | Makes the two Sync clients easy to compare |
| Assistant appeared to be another required part of the suite | Separate optional AI section and explicit independence on its page | Avoids installing unnecessary apps |
| README linked to a missing `#download` anchor | Central downloads section with four platform-specific choices | Direct, stable destination for downloads and installation guides |
| Stream asked visitors to compare transports and trust stores | Sync setup first; Assistant compatibility and connection details are disclosures | Keeps protocol details out of the initial choice |
| Install guides still promoted the old full host | Sync setup, Control/Stream choice, optional Assistant | Keeps the next step consistent with the website |
| Product pages used different primary navigation | Start here, Compare clients, Downloads | Provides the same way back to the setup decision |

The existing blue toile artwork, glass surfaces, typography, borders, shadows,
light/dark themes, and English/Turkish switch remain. Full phone screenshots
use `object-fit: contain` and link to their original image.

## Download audit

The generator now searches all stable releases, with pagination, separately for
each app/platform. Build numbers take precedence over marketing versions:
Control previously moved from 3.7.5 build 40 to 2.3.0 build 47. A later upload of
an older build must not displace the current binary. Linux packages without
build numbers use their version. Drafts and prereleases are excluded.

Static HTML downloads, checksums, and labels are generated together with
`release.json`. Every entry records its own source release. Generic release
links keep their original repository; the generator no longer rewrites an
Assistant release link to the suite repository. Missing checksums are hidden
instead of leaving an old checksum attached to a new binary.

Latest published artifacts at audit time:

| Product | Published build |
| --- | --- |
| Sync macOS | 2.3.0 build 54 |
| Control macOS | 2.3.0 build 49 |
| Control iOS | 2.3.0 build 47 |
| Stream iOS | 0.1.6 build 20 |
| Assistant macOS | 0.10.25 build 78 |
| Assistant iOS | 0.1.35 build 57 |

Sync build 55 (native app/executable name correction) is built locally but was
not yet published at audit time. The site points to published build 54 until
55 is released. The suite release tag itself is build 55; it is not the Sync
app's build number.

Validation: eight release-selection/static-link regression tests pass. The
site verifier checks all ten HTML pages, local paths and anchors, generated
download links, and latest Stream/Assistant AltStore feed entries. Its online
run verified all 26 unique current download/checksum and feed download URLs;
checksum documents contained valid SHA-256 values. Assistant's Mac checksum
contains a bare hash, so the install guide explains direct hash comparison.
Pages deployment now runs the selection tests and static link verification
before uploading the site. Metadata refreshes on Pages deployments.

## GitHub cleanup

- Removed 29 unreferenced published site images: 15,019,225 bytes. This includes
  retired host/terminal previews, unused icon copies, old Assistant captures,
  and abandoned statue imagery. References were checked across tracked text
  files before removal; Git history retains the files.
- Deleted nine obsolete CodeQL base-database caches: 116,719,451 bytes. Retained
  the latest base cache and current status cache; the API confirmed two remain.
- Reviewed 21 suite releases, 39 Assistant releases, open PRs, and remote
  branches. Older release assets remain because historical feed versions and
  external installation links can still use them. Boo Player is an independent
  active app and its release/feed entries remain.
- Preserved unmerged permission-refresh, ping authentication, naming, cloud
  setup, timeout, and dependency PRs. They contain work not fully incorporated
  into main. The orphan cloud-agent branch also contains unique design sketches;
  it was not treated as merged or disposable.
- Main requires a code-owner review and required checks. The updates are pushed
  through PR #27. No branch-protection rules were changed. The configured generic
  CodeQL context names differ from the current matrix job names; repository
  maintainers should resolve that mismatch while preserving all required scans.
