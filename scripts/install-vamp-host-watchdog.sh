#!/usr/bin/env bash

# Installs the optional Vamp Host watchdog as a per-user launch agent.
# No administrator access or public network exposure is required.

set -euo pipefail

watchdog_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
watchdog_source="$watchdog_root/scripts/vamp-host-watchdog"
watchdog_install_dir="$HOME/Library/Application Support/Vamp Watchdog"
watchdog_executable="$watchdog_install_dir/vamp-host-watchdog"
watchdog_agent_dir="$HOME/Library/LaunchAgents"
watchdog_plist="$watchdog_agent_dir/com.mesutcy.remotedesktop.host.watchdog.plist"
watchdog_domain="gui/$(id -u)"
watchdog_label="com.mesutcy.remotedesktop.host.watchdog"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$watchdog_domain" "$watchdog_plist" 2>/dev/null || true
  rm -f "$watchdog_plist" "$watchdog_executable"
  printf '[vamp-watchdog] Uninstalled. Existing host data and logs were preserved.\n'
  exit 0
fi

[[ $# -eq 0 ]] || { printf 'Usage: %s [--uninstall]\n' "$0" >&2; exit 2; }
[[ -x "$watchdog_source" ]] || chmod +x "$watchdog_source"
mkdir -p "$watchdog_install_dir" "$watchdog_agent_dir"
install -m 755 "$watchdog_source" "$watchdog_executable"

plutil -create xml1 "$watchdog_plist"
plutil -insert Label -string "$watchdog_label" "$watchdog_plist"
plutil -insert ProgramArguments -json "[\"$watchdog_executable\"]" "$watchdog_plist"
plutil -insert RunAtLoad -bool YES "$watchdog_plist"
plutil -insert KeepAlive -bool YES "$watchdog_plist"
plutil -insert ProcessType -string Background "$watchdog_plist"
plutil -insert ThrottleInterval -integer 10 "$watchdog_plist"
plutil -lint "$watchdog_plist" >/dev/null

launchctl bootout "$watchdog_domain" "$watchdog_plist" 2>/dev/null || true
launchctl bootstrap "$watchdog_domain" "$watchdog_plist"
printf '[vamp-watchdog] Installed. Vamp Host will recover from crashes or a stale main-run-loop heartbeat.\n'
printf '[vamp-watchdog] Intentional Quit remains respected; reopening Vamp Host resumes monitoring.\n'
