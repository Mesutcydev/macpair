# Legacy identifier compatibility

ScreenHarbor is the public name of the macOS host and client. Some internal source
types, persisted keys, and protocol fields still contain historical names such as
`MacHost`, `MacClient`, or `com.remotedesktop`.

Those identifiers are intentionally retained where changing them could:

- break decoding between existing host and client builds;
- orphan trusted-peer, Keychain, or settings data;
- change stable notification or snapshot keys; or
- create an unsafe migration in a security-sensitive path.

They are implementation details, not public branding. New user-facing text, bundle
identifiers, URL schemes, Bonjour services, documentation, and release artifacts use
ScreenHarbor identifiers. A legacy identifier should only be renamed with a
documented compatibility migration and regression tests.
