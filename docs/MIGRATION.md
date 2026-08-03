# Legacy identifier compatibility

MacPair is the public name of the macOS host and client. Some internal source
types, persisted keys, and protocol fields still contain historical names such as
`MacHost`, `MacClient`, or `com.remotedesktop`.

Those identifiers are intentionally retained where changing them could:

- break decoding between existing host and client builds;
- orphan trusted-peer, Keychain, or settings data;
- change stable notification or snapshot keys; or
- create an unsafe migration in a security-sensitive path.

They are implementation details, not public branding. New user-facing text uses MacPair,
while the existing bundle identifiers, URL schemes, Bonjour service, CLI, and persisted
storage names remain stable for compatibility. A legacy identifier should only be renamed with a
documented compatibility migration and regression tests.
