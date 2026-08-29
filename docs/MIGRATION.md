# Legacy identifier compatibility

Vamp is the public umbrella name. User-facing products that are actually
different apps stay distinct: Vamp Stream, Vamp Host, Vamp Sync, plus the
specialist apps that remain in this tree (Vamp Control, Vamp Terminal, Vamp
Terminal Host, Vamp Linux Host). Vamp Assistant lives in a separate repository.

Some internal source types, persisted keys, packaging targets, and protocol
fields still contain historical names such as `MacHost`, `MacClient`,
`MacPair`, `ScreenHarbor`, `RemoteDesktopTool`, `BeetCode`, `VampMiniHost`,
or `com.remotedesktop`.

Those identifiers are intentionally retained where changing them could:

- break decoding between existing host and client builds;
- orphan trusted-peer, Keychain, or settings data;
- change stable notification, snapshot, or Application Support paths;
- break CI, GitHub Pages, packaging scripts, or clone/download URLs; or
- create an unsafe migration in a security-sensitive path.

They are implementation details, not public branding. New user-facing text,
documentation, and display names use Vamp identifiers.

Compatibility identities that must not be renamed without a documented
migration and regression tests:

- bundle IDs (`com.mesutcy.remotedesktop.*`, `uk.mesut.screenharbor.*`)
- Bonjour service `_screenharbor._tcp`
- signaling/data/browser ports `9471` / `9472` / `9473` / `9475` / `9575`
- URL schemes `vamphost`, `vampterminalhost`, `vampminihost`, `screenharbor`
- Keychain tags and Assistant token service names
- Application Support directories `RemoteDesktopTool` and `Vamp Mini Host`
- session registry product folder `Vamp Mini Host`
- Xcode schemes, project filenames, and packaging artifact stems
- GitHub clone and release URLs on `Mesutcydev/macpair` until that repository
  is renamed with GitHub's built-in redirects in place

The GitHub repository is still `Mesutcydev/macpair`. `Mesutcydev/vamp` is
unused, but renaming it is a separate follow-up so Pages, CI, and existing
clone/download URLs keep working.
