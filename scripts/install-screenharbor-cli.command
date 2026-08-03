#!/usr/bin/env bash

set -euo pipefail

APP="/Applications/MacPair Host.app"
SOURCE="$APP/Contents/Resources/screenharbor"
DESTINATION="/usr/local/bin/screenharbor"

if [[ ! -f "$SOURCE" ]]; then
  printf 'MacPair Host is not installed in /Applications.\n' >&2
  printf 'Drag the host app to Applications, open it once, then run this installer again.\n' >&2
  read -r -p "Press Return to close…" _
  exit 1
fi

sudo mkdir -p /usr/local/bin
sudo ln -sf "$SOURCE" "$DESTINATION"

printf '\nInstalled: %s\n' "$DESTINATION"
"$DESTINATION" version || true
printf '\nAgents can now run: screenharbor status --json\n'
read -r -p "Press Return to close…" _
