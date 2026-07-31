#!/usr/bin/env bash

# Publishes already-packaged ScreenHarbor artifacts to the website working tree.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
WEBSITE="${SCREENHARBOR_WEBSITE_DIR:-/Users/m/Desktop/Projects/Developer/website}"
SPEC="$ROOT/screenharbor-project.yml"
RELEASE=0

fail() { printf '[publish-screenharbor] error: %s\n' "$*" >&2; exit 1; }
log() { printf '[publish-screenharbor] %s\n' "$*" >&2; }

if [[ $# -gt 1 ]]; then
  fail "Usage: scripts/publish-screenharbor.sh [--release]"
fi
if [[ $# -eq 1 ]]; then
  [[ "$1" == "--release" ]] || fail "Unknown option: $1"
  RELEASE=1
fi

[[ -d "$WEBSITE" ]] || fail "Website directory not found: $WEBSITE"
[[ -f "$WEBSITE/js/data/apps.js" ]] || fail "Website apps.js not found"

version="$(grep -m1 -oE 'MARKETING_VERSION: [0-9.]+' "$SPEC" | awk '{print $2}')"
build="$(grep -m1 -oE 'CURRENT_PROJECT_VERSION: [0-9]+' "$SPEC" | awk '{print $2}')"
[[ -n "$version" && -n "$build" ]] || fail "Could not read version/build"

source_commit="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
[[ -n "$source_commit" ]] || fail "Publish only from a committed source tree"
if [[ "$RELEASE" -eq 1 ]]; then
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] ||
    fail "Release publishing requires a clean source tree"
  source_tag="$(git -C "$ROOT" describe --tags --exact-match "$source_commit" 2>/dev/null || true)"
  [[ "$source_tag" == "v$version" ]] || fail "Release commit must have the exact tag v$version"
fi

host_base="ScreenHarbor-Host-${version}-build-${build}"
client_base="ScreenHarbor-${version}-build-${build}"

for base in "$host_base" "$client_base"; do
  for extension in dmg zip; do
    for suffix in "" .sha256 .manifest.json .sbom.cdx.json; do
      source="$DIST/$base.$extension$suffix"
      [[ -f "$source" ]] || fail "Missing release file: $source"
      if [[ "$suffix" == ".manifest.json" ]]; then
        manifest_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceCommit"])' "$source")"
        manifest_state="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceTreeState"])' "$source")"
        [[ "$manifest_commit" == "$source_commit" ]] ||
          fail "Manifest source commit does not match HEAD: $source"
        if [[ "$RELEASE" -eq 1 ]]; then
          [[ "$manifest_state" == "clean" ]] ||
            fail "Release manifest was not produced from a clean tree: $source"
        fi
      fi
      cp "$source" "$WEBSITE/"
    done
  done
done

cp "$ROOT/docs/agent-manifest.json" "$WEBSITE/screenharbor-agent.json"
cp "$ROOT/llms.txt" "$WEBSITE/screenharbor-llms.txt"

APPS_JS="$WEBSITE/js/data/apps.js" HOST_URL="/$host_base.dmg" CLIENT_URL="/$client_base.dmg" \
  VERSION="$version" BUILD="$build" RELEASE="$RELEASE" WEBSITE="$WEBSITE" python3 - <<'PY'
import os
import re

path = os.environ["APPS_JS"]
text = open(path, encoding="utf-8").read()
is_release = os.environ["RELEASE"] == "1"

def update(slug, url):
    global text
    pattern = rf"(slug: '{re.escape(slug)}',[\s\S]*?dmgUrl: ')[^']+(')"
    text, count = re.subn(pattern, rf"\g<1>{url}\2", text, count=1)
    if count != 1:
        raise SystemExit(f"Could not update dmgUrl for {slug}")
    downloads = {
        "SHA-256": f"{url}.sha256",
        "Release manifest": f"{url}.manifest.json",
        "SBOM": f"{url}.sbom.cdx.json",
    }
    for label, download_url in downloads.items():
        pattern = (
            rf"(slug: '{re.escape(slug)}',[\s\S]*?"
            rf"{{ label: '{re.escape(label)}', url: ')[^']+(')"
        )
        text, count = re.subn(
            pattern,
            rf"\g<1>{download_url}\2",
            text,
            count=1,
        )
        if count != 1:
            raise SystemExit(f"Could not update {label} URL for {slug}")
    version_pattern = (
        rf"(slug: '{re.escape(slug)}',[\s\S]*?softwareVersion: ')[^']+(')"
    )
    text, count = re.subn(
        version_pattern,
        rf"\g<1>{os.environ['VERSION']}\2",
        text,
        count=1,
    )
    if count != 1:
        raise SystemExit(f"Could not update softwareVersion for {slug}")
    if is_release:
        status_pattern = rf"(slug: '{re.escape(slug)}',[\s\S]*?status: ')[^']+(')"
        text, count = re.subn(status_pattern, r"\g<1>live\2", text, count=1)
        if count != 1:
            raise SystemExit(f"Could not update status for {slug}")

update("screenharbor-host", os.environ["HOST_URL"])
update("screenharbor", os.environ["CLIENT_URL"])
open(path, "w", encoding="utf-8").write(text)

if is_release:
    website = os.environ["WEBSITE"]
    full_path = os.path.join(website, "llms-full.txt")
    if os.path.isfile(full_path):
        full_text = open(full_path, encoding="utf-8").read()
        for title in ("ScreenHarbor", "ScreenHarbor Host"):
            pattern = rf"(?ms)(^### {re.escape(title)}\n)(.*?)(?=^### |\Z)"
            match = re.search(pattern, full_text)
            if not match:
                raise SystemExit(f"Could not find llms-full section for {title}")
            section = match.group(0)
            replacements = (
                ("- Status: in-development", "- Status: live"),
                (
                    "- Distribution: pending provenance-backed direct website DMG and ZIP release",
                    "- Distribution: direct website DMG and ZIP",
                ),
                ("- Planned source:", "- Source:"),
            )
            for old, new in replacements:
                old_count = section.count(old)
                if old_count == 1:
                    section = section.replace(old, new, 1)
                elif old_count == 0:
                    # Already flipped to live, possibly with reworded copy.
                    continue
                else:
                    raise SystemExit(f"Unexpected llms-full marker count for {title}: {old}")
            full_text = full_text[:match.start()] + section + full_text[match.end():]
        open(full_path, "w", encoding="utf-8").write(full_text)

    index_path = os.path.join(website, "llms.txt")
    if os.path.isfile(index_path):
        index_text = open(index_path, encoding="utf-8").read()
        replacements = (
            ("In-development open-source", "Open-source", 2),
            (
                "The planned direct website release will include",
                "Direct website downloads include",
                1,
            ),
            ("Planned source location:", "Source:", 1),
            (
                "Release status: in development; do not treat the planned source or download URLs as available until these pages show **Live**.",
                "Release status: live. Current downloads are ad-hoc signed and not Apple-notarized.",
                1,
            ),
        )
        for old, new, expected in replacements:
            old_count = index_text.count(old)
            if old_count == expected:
                index_text = index_text.replace(old, new)
            elif old_count == 0:
                # Already flipped to live, possibly with reworded copy.
                continue
            else:
                raise SystemExit(f"Unexpected llms.txt marker count: {old}")
        open(index_path, "w", encoding="utf-8").write(index_text)
PY

log "Published ScreenHarbor $version build $build into $WEBSITE"
log "Review the website diff, then commit and deploy it with the website's normal workflow."
