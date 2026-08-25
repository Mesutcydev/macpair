#!/usr/bin/env bash
# Build a device-only, unsigned Vamp Stream IPA for AltStore-style re-signing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.packaging-vamp-stream-ios"
DERIVED="$WORK/DerivedData"
STAGING="$WORK/staging"
PROJECT="$ROOT/VampStream.xcodeproj"
OUTPUT="$ROOT/dist/VampStream"
CLEAN=0
ALLOW_DIRTY=0

fail() { printf '[vamp-stream-ios] error: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) [[ $# -ge 2 ]] || fail "Missing output path"; OUTPUT="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --help|-h) printf 'Usage: scripts/package-vamp-stream-ios.sh [--output-dir path] [--clean] [--allow-dirty]\n'; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ "$OUTPUT" == /* ]] || OUTPUT="$ROOT/$OUTPUT"
for tool in xcodegen xcodebuild plutil file ditto zip unzip shasum; do command -v "$tool" >/dev/null || fail "Required tool not found: $tool"; done
[[ -f "$ROOT/vampstream-project.yml" ]] || fail "vampstream-project.yml is missing"
[[ -f "$ROOT/Configuration/VampStream.entitlements" ]] || fail "VampStream.entitlements is missing"
if [[ "$ALLOW_DIRTY" -ne 1 && -n "$(git -C "$ROOT" status --porcelain)" ]]; then fail "Use --allow-dirty for an uncommitted tree"; fi
if [[ "$CLEAN" -eq 1 ]]; then [[ "$WORK" == "$ROOT/.packaging-vamp-stream-ios" ]] || fail "Unexpected work path"; rm -rf "$WORK"; fi
mkdir -p "$WORK" "$OUTPUT"
xcodegen generate --spec "$ROOT/vampstream-project.yml"
xcodebuild -quiet -project "$PROJECT" -scheme VampStream -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
APP="$DERIVED/Build/Products/Release-iphoneos/Vamp Stream.app"
[[ -d "$APP" ]] || fail "Built app not found: $APP"
INFO="$APP/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw "$INFO")"
[[ "$(plutil -extract CFBundleIdentifier raw "$INFO")" == "com.mesutcy.remotedesktop.stream" ]] || fail "Unexpected bundle identifier"
file "$APP/Vamp Stream" | grep -q arm64 || fail "Device executable is not arm64"
[[ ! -e "$APP/embedded.mobileprovision" && ! -d "$APP/_CodeSignature" ]] || fail "IPA must remain unsigned"
NAME="VampStream-iOS-${VERSION}-build-${BUILD}-altstore-unsigned.ipa"
IPA="$OUTPUT/$NAME"
[[ "$STAGING" == "$WORK/staging" ]] || fail "Unexpected staging path"
rm -rf "$STAGING"; mkdir -p "$STAGING/Payload"; ditto --norsrc --noextattr "$APP" "$STAGING/Payload/Vamp Stream.app"
(cd "$STAGING" && COPYFILE_DISABLE=1 zip -qryX "$IPA" Payload)
unzip -tq "$IPA" >/dev/null
(cd "$OUTPUT" && shasum -a 256 "$NAME" > "$NAME.sha256" && shasum -a 256 -c "$NAME.sha256" >/dev/null)
printf '[vamp-stream-ios] wrote %s\n' "$IPA"
