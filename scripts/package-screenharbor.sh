#!/usr/bin/env bash

# Account-independent website packaging for ScreenHarbor.
# Produces ad-hoc-signed DMG/ZIP artifacts, SHA-256 files, and JSON manifests.
# No Apple account, certificate, provisioning profile, or notarization is used.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/screenharbor-project.yml"
PROJECT="$ROOT/ScreenHarbor.xcodeproj"
DIST="$ROOT/dist"
WORK_ROOT="$ROOT/.screenharbor-packaging"

TARGET="all"
FORMAT="both"
CLEAN=0
RELEASE=0

usage() {
  sed -n '3,5p' "$0" | sed 's/^# *//'
  printf '\nUsage: scripts/package-screenharbor.sh [host|client|all] [options]\n\n'
  printf 'Options:\n'
  printf '  --format <dmg|zip|both>  Artifact format (default: both)\n'
  printf '  --clean                  Rebuild from a clean derived-data directory\n'
  printf '  --release                Require a clean vX.Y.Z-tagged source commit\n'
  printf '  --help                   Show this help\n'
}

fail() { printf '[package-screenharbor] error: %s\n' "$*" >&2; exit 1; }
log() { printf '[package-screenharbor] %s\n' "$*" >&2; }
require_tool() { command -v "$1" >/dev/null 2>&1 || fail "Required tool not found: $1"; }

if [[ $# -gt 0 && "$1" != --* ]]; then
  TARGET="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      [[ $# -ge 2 ]] || fail "--format requires a value"
      FORMAT="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --release)
      RELEASE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

case "$TARGET" in host|client|all) ;; *) fail "Target must be host, client, or all";; esac
case "$FORMAT" in dmg|zip|both) ;; *) fail "Format must be dmg, zip, or both";; esac

require_tool xcodegen
require_tool xcodebuild
require_tool codesign
require_tool ditto
require_tool hdiutil
require_tool shasum
require_tool python3
require_tool git

[[ -f "$SPEC" ]] || fail "Missing $SPEC"
mkdir -p "$DIST" "$WORK_ROOT"

SOURCE_COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
[[ -n "$SOURCE_COMMIT" ]] || fail "Package only from a committed source tree"
SOURCE_COMMIT_DATE="$(git -C "$ROOT" show -s --format=%cI "$SOURCE_COMMIT")"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
  SOURCE_TREE_STATE="dirty"
else
  SOURCE_TREE_STATE="clean"
fi
SOURCE_TAG="$(git -C "$ROOT" describe --tags --exact-match "$SOURCE_COMMIT" 2>/dev/null || true)"

if [[ "$RELEASE" -eq 1 ]]; then
  [[ "$SOURCE_TREE_STATE" == "clean" ]] || fail "Release packaging requires a clean source tree"
  expected_version="$(grep -m1 -oE 'MARKETING_VERSION: [0-9.]+' "$SPEC" | awk '{print $2}')"
  [[ "$SOURCE_TAG" == "v$expected_version" ]] ||
    fail "Release commit must have the exact tag v$expected_version"
fi

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.bareRepository
export GIT_CONFIG_VALUE_0=all

log "Generating ScreenHarbor.xcodeproj"
xcodegen generate --spec "$SPEC" >/dev/null

package_component() {
  local component="$1"
  local scheme product bundle_id entitlements artifact_stem

  case "$component" in
    host)
      scheme="ScreenHarborHost"
      product="ScreenHarbor Host.app"
      bundle_id="uk.mesut.screenharbor.host"
      entitlements="$ROOT/ScreenHarbor/Resources/ScreenHarborHost.entitlements"
      artifact_stem="ScreenHarbor-Host"
      ;;
    client)
      scheme="ScreenHarborClient"
      product="ScreenHarbor.app"
      bundle_id="uk.mesut.screenharbor.client"
      entitlements="$ROOT/ScreenHarbor/Resources/ScreenHarborClient.entitlements"
      artifact_stem="ScreenHarbor"
      ;;
  esac

  local work="$WORK_ROOT/$component"
  local derived="$work/derived-data"
  local export_dir="$work/export"
  local staging="$work/dmg"
  local log_file="$work/build.log"

  if [[ "$CLEAN" -eq 1 ]]; then
    chmod -R u+w "$work" 2>/dev/null || true
    rm -rf "$work"
  fi
  mkdir -p "$work"
  rm -rf "$export_dir" "$staging"

  log "Building $scheme (universal, ad-hoc signed)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -configuration Release \
    -derivedDataPath "$derived" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    build >"$log_file" 2>&1 || {
      tail -n 80 "$log_file" >&2
      fail "$scheme build failed; full log: $log_file"
    }

  local built="$derived/Build/Products/Release/$product"
  [[ -d "$built" ]] || fail "Built app not found: $built"
  mkdir -p "$export_dir"
  ditto "$built" "$export_dir/$product"
  local app="$export_dir/$product"

  mkdir -p "$app/Contents/Resources"
  cp "$ROOT/LICENSE" "$app/Contents/Resources/LICENSE"
  cp "$ROOT/NOTICE" "$app/Contents/Resources/NOTICE"
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
  mkdir -p "$app/Contents/Resources/ThirdPartyLicenses"

  local sparkle_license="$derived/SourcePackages/artifacts/sparkle/Sparkle/LICENSE"
  local swiftterm_license="$derived/SourcePackages/checkouts/SwiftTerm/LICENSE"
  [[ -f "$sparkle_license" ]] || fail "Sparkle license not found: $sparkle_license"
  cp "$sparkle_license" "$app/Contents/Resources/ThirdPartyLicenses/Sparkle-LICENSE"
  if [[ "$component" == "client" ]]; then
    [[ -f "$swiftterm_license" ]] || fail "SwiftTerm license not found: $swiftterm_license"
    cp "$swiftterm_license" "$app/Contents/Resources/ThirdPartyLicenses/SwiftTerm-LICENSE"
  fi
  cp "$ROOT/Sources/Copus/COPYING" "$app/Contents/Resources/ThirdPartyLicenses/Opus-COPYING"

  if [[ "$component" == "host" ]]; then
    cp "$ROOT/scripts/screenharbor" "$app/Contents/Resources/screenharbor"
    chmod +x "$app/Contents/Resources/screenharbor"
  fi

  # Re-seal the outer bundle after adding CLI and license resources. Xcode has
  # already ad-hoc signed nested Sparkle helpers and frameworks.
  codesign --force --sign - --options runtime --entitlements "$entitlements" "$app"
  codesign --verify --deep --strict "$app"

  local actual_bundle_id
  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  [[ "$actual_bundle_id" == "$bundle_id" ]] || fail "Unexpected bundle ID: $actual_bundle_id"

  local version build
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  local base="${artifact_stem}-${version}-build-${build}"
  local artifacts=()

  if [[ "$FORMAT" == "zip" || "$FORMAT" == "both" ]]; then
    local zip="$DIST/$base.zip"
    rm -f "$zip" "$zip.sha256" "$zip.manifest.json"
    log "Creating $(basename "$zip")"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
    artifacts+=("$zip")
  fi

  if [[ "$FORMAT" == "dmg" || "$FORMAT" == "both" ]]; then
    local dmg="$DIST/$base.dmg"
    rm -f "$dmg" "$dmg.sha256" "$dmg.manifest.json"
    mkdir -p "$staging"
    ditto "$app" "$staging/$product"
    ln -s /Applications "$staging/Applications"
    cp "$ROOT/README.md" "$staging/README.md"
    cp "$ROOT/LICENSE" "$staging/LICENSE"
    if [[ "$component" == "host" ]]; then
      cp "$ROOT/scripts/install-screenharbor-cli.command" "$staging/Install ScreenHarbor CLI.command"
      chmod +x "$staging/Install ScreenHarbor CLI.command"
    fi
    log "Creating $(basename "$dmg")"
    hdiutil create -volname "${product%.app}" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
    codesign --force --sign - "$dmg"
    artifacts+=("$dmg")
  fi

  local artifact sha size manifest sbom
  for artifact in "${artifacts[@]}"; do
    sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"
    size="$(stat -f '%z' "$artifact")"
    printf '%s  %s\n' "$sha" "$(basename "$artifact")" >"$artifact.sha256"
    manifest="$artifact.manifest.json"
    python3 - "$manifest" "$artifact" "$sha" "$size" "$version" "$build" "$bundle_id" \
      "$SOURCE_COMMIT" "$SOURCE_COMMIT_DATE" "$SOURCE_TREE_STATE" "$SOURCE_TAG" <<'PY'
import json
import os
import sys

(
    path,
    artifact,
    sha,
    size,
    version,
    build,
    bundle_id,
    source_commit,
    source_commit_date,
    source_tree_state,
    source_tag,
) = sys.argv[1:]
payload = {
    "schemaVersion": 2,
    "name": os.path.basename(artifact),
    "bundleId": bundle_id,
    "version": version,
    "build": int(build),
    "minimumSystemVersion": "13.0",
    "bytes": int(size),
    "sha256": sha,
    "appleNotarized": False,
    "codeSignature": "ad-hoc",
    "sourceRepository": "https://github.com/Mesutcydev/screenharbor",
    "sourceCommit": source_commit,
    "sourceCommitDate": source_commit_date,
    "sourceTreeState": source_tree_state,
    "sourceTag": source_tag or None,
    "buildSystem": "xcodebuild via scripts/package-screenharbor.sh",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
    sbom="$artifact.sbom.cdx.json"
    "$ROOT/scripts/generate-screenharbor-sbom.sh" \
      "$artifact" "$component" "$version" "$build" "$SOURCE_COMMIT" "$sbom"
    log "Created $artifact"
    log "SHA-256 $sha"
    log "SBOM $sbom"
  done
}

if [[ "$TARGET" == "host" || "$TARGET" == "all" ]]; then
  package_component host
fi
if [[ "$TARGET" == "client" || "$TARGET" == "all" ]]; then
  package_component client
fi

log "Done. Website artifacts are in $DIST"
