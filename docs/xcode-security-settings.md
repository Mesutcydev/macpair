# Xcode Security Settings

Security build-setting decisions for MacPair.

## Enabled settings

- `ENABLE_ENHANCED_SECURITY` to `YES`: Enables Xcode's supported compiler and
  runtime hardening for the macOS host and client.
- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`
- `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`
- `CLANG_WARN_IMPLICIT_FALLTHROUGH` to `YES`
- `GCC_WARN_64_TO_32_BIT_CONVERSION` to `YES`
- `GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS` to `YES`
- `CLANG_ANALYZER_SECURITY_FLOATLOOPCOUNTER` to `YES`
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_RAND` to `YES`
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_STRCPY` to `YES`
- `com.apple.security.hardened-process`: Enabled on both apps.
- `com.apple.security.hardened-process.enhanced-security-version-string` to
  `"2"`: Enabled on both apps.
- `com.apple.security.hardened-process.hardened-heap`: Enabled on both apps.
- `com.apple.security.hardened-process.dyld-ro`: Enabled on both apps.
- `com.apple.security.hardened-process.platform-restrictions-string` to `"2"`:
  Enabled on both apps.

## Disabled settings

- `ENABLE_POINTER_AUTHENTICATION` to `NO`: Xcode 26 compiles the app target for
  arm64e when enabled, while the local SwiftPM products are emitted for arm64 and
  x86_64. Keep this disabled until the complete dependency graph builds compatible
  arm64e modules.

## Deferred

- `com.apple.security.hardened-process.checked-allocations`: Hardware memory
  tagging requires a planned compatibility rollout and supported hardware.
- `ENABLE_C_BOUNDS_SAFETY`: The vendored Opus C implementation would require a
  separately tested annotation and migration plan.
- Additional high-noise Clang warnings and experimental analyzer checkers: Revisit
  after the baseline checks have run in public CI.

## Validation

On July 29, 2026, Xcode 26.6 Release builds and static analysis completed
successfully for both app targets with these settings. The analyzer reported no
first-party findings. It did report path-sensitive findings in the unmodified
vendored Opus 1.4 implementation. The reproducible baseline is 37 findings for
each app target:

| Checker | Count |
| --- | ---: |
| `core.UndefinedBinaryOperatorResult` | 11 |
| `core.DivideZero` | 6 |
| `core.NullDereference` | 5 |
| `core.VLASize` | 4 |
| `core.uninitialized.Assign` | 3 |
| `core.CallAndMessage` | 2 |
| `unix.cstring.NullArg` | 2 |
| `unix.Malloc` | 2 |
| `core.uninitialized.ArraySubscript` | 1 |
| `core.BitwiseShift` | 1 |

All 37 paths are under `Sources/Copus/`; none are in first-party Swift or
Objective-C code. Changing codec internals without upstream test vectors would be
higher risk than retaining the reviewed upstream release. New findings outside
that path are release blockers. CodeQL remains enabled over Swift and C/C++
sources so future changes are checked independently.
