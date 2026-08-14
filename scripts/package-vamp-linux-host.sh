#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(sed -n 's/^VERSION = "\([^"]*\)"/\1/p' "$ROOT/linux-host/vamp_terminal_host.py")
OUT_DIR="$ROOT/dist/VampTerminalLinuxHost"
CLEAN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir)
      [ "$#" -ge 2 ] || { echo "Missing --output-dir value" >&2; exit 64; }
      OUT_DIR=$2
      shift 2
      ;;
    --clean) CLEAN=1; shift ;;
    --allow-dirty) shift ;;
    --help|-h)
      echo "Usage: $0 [--output-dir path] [--clean] [--allow-dirty]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$ROOT/$OUT_DIR" ;; esac
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

PACKAGE="VampTerminalHost-Linux-$VERSION"
mkdir -p "$STAGE/$PACKAGE" "$OUT_DIR"
[ "$CLEAN" -eq 0 ] || find "$OUT_DIR" -maxdepth 1 -type f -name 'VampTerminalHost-Linux-*' -delete
cp "$ROOT/linux-host/vamp_terminal_host.py" \
   "$ROOT/linux-host/index.html" \
   "$ROOT/linux-host/install.sh" \
   "$ROOT/linux-host/vamp-terminal-host" \
   "$ROOT/linux-host/vamp-terminal-host.service" \
   "$ROOT/linux-host/README.md" \
   "$STAGE/$PACKAGE/"
chmod 755 "$STAGE/$PACKAGE/install.sh" "$STAGE/$PACKAGE/vamp-terminal-host" "$STAGE/$PACKAGE/vamp_terminal_host.py"

ARCHIVE="$OUT_DIR/$PACKAGE.zip"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
(cd "$STAGE" && zip -qr "$ARCHIVE" "$PACKAGE")
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
printf '%s\n' "$ARCHIVE"
