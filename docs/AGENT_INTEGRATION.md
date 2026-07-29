# Agent integration

ScreenHarbor Host is a normal menu-bar macOS app, not a daemon. Launching the app starts its runtime automatically after required permissions are available.

## Discovery and readiness

```bash
screenharbor ensure
screenharbor status --json
```

`ensure` exits `0` when the host is ready, `1` when it is not installed, `2` when installed but not advertising, and `3` when the user must grant permissions.

The JSON status object includes `installed`, `running`, `phase`, `advertising`, `primaryAddress`, `appPath`, and `pendingPairingRequest`.

## Pairing safety

Inspect before approval:

```bash
screenharbor pending --json
```

An agent must:

1. show the user `displayName`, `fingerprint`, and `deadline`;
2. ask the user to verify the fingerprint through a trusted channel;
3. approve only with the exact fingerprint:

   ```bash
   screenharbor approve-pairing --fingerprint <verified-hex> --json
   ```

Never approve merely because a request exists. Reject suspicious requests with `screenharbor reject-pairing --json`.

## Commands

| Command | Purpose |
| --- | --- |
| `screenharbor start` | Launch the app and start hosting |
| `screenharbor stop` | Stop hosting |
| `screenharbor restart` | Restart hosting |
| `screenharbor open` | Open the app without a runtime action |
| `screenharbor status --json` | Read machine status |
| `screenharbor ensure` | Start if necessary and wait for readiness |
| `screenharbor version --json` | Read installed version/build |
| `screenharbor pending --json` | Inspect the current trust request |
| `screenharbor wait-pending --timeout 60 --json` | Wait for a trust request |
| `screenharbor approve-pairing --fingerprint <hex>` | Safely approve a verified peer |
| `screenharbor reject-pairing` | Reject a peer |

## Permissions

Screen Recording and Accessibility require a human decision in System Settings → Privacy & Security. Agents cannot and must not attempt to bypass those prompts.

## Network

The host advertises `_screenharbor._tcp` through Bonjour. It listens on `9471` for plain signaling, `9473` for TLS signaling, and normally uses `9472` for data. Do not expose these ports directly to the public internet; use a trusted LAN or private VPN.
