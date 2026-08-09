# Legacy identifier compatibility

<<<<<<< HEAD
MacPair is the public name of the macOS host and client. Some internal source
types, persisted keys, and protocol fields still contain historical names such as
`MacHost`, `MacClient`, or `com.remotedesktop`.
=======
Vamp Terminal is the public product name. Some internal source types, persisted
keys, and protocol fields still contain historical names such as `MacHost`,
`MacClient`, or `com.remotedesktop`.
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)

Those identifiers are intentionally retained where changing them could:

- break decoding between existing host and client builds;
- orphan trusted-peer, Keychain, or settings data;
- change stable notification or snapshot keys; or
- create an unsafe migration in a security-sensitive path.

<<<<<<< HEAD
They are implementation details, not public branding. New user-facing text uses MacPair,
while the existing bundle identifiers, URL schemes, Bonjour service, CLI, and persisted
storage names remain stable for compatibility. A legacy identifier should only be renamed with a
=======
They are implementation details, not public branding. New user-facing text, bundle
identifiers, URL schemes, documentation, and release artifacts use Vamp identifiers.
The existing `_screenharbor._tcp` service name remains because it is part of the
paired-client wire contract. A legacy identifier should only be renamed with a
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
documented compatibility migration and regression tests.
