#!/usr/bin/env bash

# Build a device-only, unsigned ScreenHarbor IPA for sideload tools to re-sign.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.packaging-ios"
DERIVED_DATA="$WORK/DerivedData"
STAGING="$WORK/staging"
OUTPUT_DIR="$ROOT/dist"
ALLOW_DIRTY=0
CLEAN=0

usage() {
  cat <<'EOF'
Usage: scripts/package-screenharbor-ios.sh [options]

Options:
  --output-dir <path>  Artifact destination (default: dist)
  --clean              Remove the prior iOS packaging workspace first
  --allow-dirty        Permit a development build from an uncommitted tree
  --help               Show this help

The resulting IPA is intentionally unsigned. A sideload tool must re-sign it
with an Apple ID/team controlled by the person installing it.
EOF
}

log() { printf '[screenharbor-ios] %s\n' "$*" >&2; }
fail() { printf '[screenharbor-ios] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || fail "Missing value for --output-dir"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

for tool in xcodebuild xcodegen ditto plutil file otool shasum python3 unzip; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done

[[ -d "$ROOT/.git" ]] || fail "Run this script from a ScreenHarbor Git checkout"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if [[ "$ALLOW_DIRTY" -ne 1 ]] && [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  fail "Release packaging requires a clean source tree; commit changes or use --allow-dirty"
fi

if [[ "$CLEAN" -eq 1 ]]; then
  [[ "$WORK" == "$ROOT/.packaging-ios" ]] || fail "Refusing to clean an unexpected path"
  log "Cleaning prior iOS packaging output"
  rm -rf "$WORK"
fi

mkdir -p "$WORK" "$OUTPUT_DIR"

log "Generating ScreenHarbor.xcodeproj"
(cd "$ROOT" && xcodegen generate --spec screenharbor-project.yml)

log "Building unsigned Release app for generic iOS device"
xcodebuild \
  -project "$ROOT/ScreenHarbor.xcodeproj" \
  -scheme ScreenHarborIOS \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  build

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/ScreenHarbor.app"
INFO="$APP/Info.plist"
EXECUTABLE="$APP/ScreenHarbor"
[[ -d "$APP" ]] || fail "Built app not found: $APP"
[[ -f "$INFO" ]] || fail "Built Info.plist not found"
[[ -x "$EXECUTABLE" ]] || fail "Built executable not found"

# Xcode does not reliably infer a file type for extensionless bundle resources,
# so embed the legal texts after compilation and before packaging.
ditto "$ROOT/LICENSE" "$APP/LICENSE"
ditto "$ROOT/NOTICE" "$APP/NOTICE"
ditto "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/THIRD_PARTY_NOTICES.md"
mkdir -p "$APP/ThirdPartyLicenses"
ditto "$ROOT/Sources/Copus/COPYING" "$APP/ThirdPartyLicenses/Opus-COPYING"
ditto \
  "$DERIVED_DATA/SourcePackages/checkouts/SwiftTerm/LICENSE" \
  "$APP/ThirdPartyLicenses/SwiftTerm-LICENSE"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw "$INFO")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO")"
DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$INFO")"

[[ "$BUNDLE_ID" == "uk.mesut.screenharbor.ios" ]] || fail "Unexpected bundle ID: $BUNDLE_ID"
[[ "$DISPLAY_NAME" == "ScreenHarbor" ]] || fail "Unexpected display name: $DISPLAY_NAME"
plutil -extract NSBonjourServices xml1 -o - "$INFO" | grep -q "_screenharbor._tcp" \
  || fail "ScreenHarbor Bonjour service is missing"
file "$EXECUTABLE" | grep -q "arm64" || fail "The device executable is not arm64"
if otool -L "$EXECUTABLE" | grep -qi "Sparkle"; then
  fail "Sparkle must not be linked into the iOS client"
fi
if find "$APP" -iname '*Sparkle*' -print -quit | grep -q .; then
  fail "Sparkle files must not be embedded in the iOS client"
fi
[[ ! -e "$APP/embedded.mobileprovision" ]] || fail "Unsigned IPA unexpectedly contains a provisioning profile"
[[ ! -d "$APP/_CodeSignature" ]] || fail "Unsigned IPA unexpectedly contains a code signature"
[[ -f "$APP/LICENSE" ]] || fail "Apache-2.0 license was not embedded"
[[ -f "$APP/THIRD_PARTY_NOTICES.md" ]] || fail "Third-party notices were not embedded"
[[ -f "$APP/ThirdPartyLicenses/Opus-COPYING" ]] || fail "Opus license was not embedded"
[[ -f "$APP/ThirdPartyLicenses/SwiftTerm-LICENSE" ]] || fail "SwiftTerm license was not embedded"

ARTIFACT_NAME="ScreenHarbor-iOS-${VERSION}-build-${BUILD}-unsigned.ipa"
IPA="$OUTPUT_DIR/$ARTIFACT_NAME"
SHA_FILE="$IPA.sha256"
MANIFEST="$IPA.manifest.json"
SBOM="$IPA.sbom.cdx.json"

[[ "$STAGING" == "$WORK/staging" ]] || fail "Refusing to replace an unexpected staging path"
rm -rf "$STAGING"
mkdir -p "$STAGING/Payload"
ditto "$APP" "$STAGING/Payload/ScreenHarbor.app"
(cd "$STAGING" && ditto -c -k --keepParent Payload "$IPA")

unzip -tq "$IPA" >/dev/null || fail "IPA ZIP integrity check failed"
(cd "$OUTPUT_DIR" && shasum -a 256 "$ARTIFACT_NAME" > "$(basename "$SHA_FILE")")
SHA256="$(awk '{print $1}' "$SHA_FILE")"
SIZE_BYTES="$(stat -f '%z' "$IPA")"
TREE_STATE="clean"
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  TREE_STATE="dirty"
fi

ARTIFACT_NAME="$ARTIFACT_NAME" VERSION="$VERSION" BUILD="$BUILD" COMMIT="$COMMIT" \
  SHA256="$SHA256" SIZE_BYTES="$SIZE_BYTES" TREE_STATE="$TREE_STATE" MANIFEST="$MANIFEST" \
  python3 - <<'PY'
import datetime
import json
import os

payload = {
    "schemaVersion": 1,
    "artifact": os.environ["ARTIFACT_NAME"],
    "application": "ScreenHarbor",
    "platform": "iOS",
    "minimumOSVersion": "18.0",
    "version": os.environ["VERSION"],
    "build": os.environ["BUILD"],
    "bundleIdentifier": "uk.mesut.screenharbor.ios",
    "architecture": ["arm64"],
    "signature": "unsigned",
    "requiresResigning": True,
    "sourceCommit": os.environ["COMMIT"],
    "sourceTreeState": os.environ["TREE_STATE"],
    "sha256": os.environ["SHA256"],
    "sizeBytes": int(os.environ["SIZE_BYTES"]),
    "createdAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
}
with open(os.environ["MANIFEST"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

"$ROOT/scripts/generate-screenharbor-sbom.sh" \
  "$IPA" ios-client "$VERSION" "$BUILD" "$COMMIT" "$SBOM"

log "Verified bundle: $BUNDLE_ID, iOS 18+, arm64, unsigned, no Sparkle"
log "IPA: $IPA"
log "SHA-256: $SHA256"
