#!/bin/sh
# Historical sources remain available; Linux Host is no longer distributed.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "Vamp Linux Host is discontinued. Current hosts: Vamp Sync and Vamp Assistant on macOS."
  exit 0
fi
echo "Vamp Linux Host is discontinued; no package was created." >&2
exit 1
