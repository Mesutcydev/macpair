## Summary

Describe the user-visible behavior and why this change is needed.

## Verification

- [ ] `swift test`
- [ ] Linux host tests pass (`python3 -m unittest discover -s Tests -p 'test_*.py'`)
- [ ] Browser VT regression passes (`node Tests/BrowserTerminalVTTests.mjs`)
- [ ] Host builds with code signing disabled
- [ ] Client builds
- [ ] User-facing or release changes are documented in `CHANGELOG.md`
- [ ] No credentials, private data, signing material, or real user logs are included
- [ ] Security and compatibility effects are described below
- [ ] Every commit includes a `Signed-off-by` trailer under the DCO

## Security and compatibility

Describe changes to pairing, authorization, transport, updates, file paths, terminal
access, permissions, persisted identifiers, or protocol compatibility. Write “None”
when none apply.
