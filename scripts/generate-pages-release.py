#!/usr/bin/env python3
"""Write the release metadata consumed by the GitHub Pages site."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from urllib.request import Request, urlopen


REPOSITORY = "Mesutcydev/macpair"
API_URL = f"https://api.github.com/repos/{REPOSITORY}/releases/latest"

ASSET_PATTERNS = {
    "vamp-host": re.compile(r"^VampHost-macOS-.+-build-\d+-adhoc\.zip$"),
    "vamp-terminal-host": re.compile(r"^VampTerminalHost-macOS-.+-build-\d+-adhoc\.zip$"),
    "vamp-terminal-ios": re.compile(
        r"^VampTerminal-iOS-.+-build-\d+-altstore-unsigned\.ipa$"
    ),
    "vamp-control-ios": re.compile(
        r"^VampControl-iOS-.+-build-\d+-altstore-unsigned(?:-r\d+)?\.ipa$"
    ),
    "vamp-control-macos": re.compile(
        r"^VampControl-macOS-.+-build-\d+-adhoc\.zip$"
    ),
}


def fetch_release() -> dict:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "macpair-pages-release-generator",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(API_URL, headers=headers)
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def build_number(asset: dict) -> int:
    match = re.search(r"-build-(\d+)", asset["name"])
    return int(match.group(1)) if match else -1


def choose_asset(assets: list[dict], pattern: re.Pattern[str]) -> dict | None:
    matches = [asset for asset in assets if pattern.fullmatch(asset["name"])]
    if not matches:
        return None
    return max(matches, key=lambda asset: (build_number(asset), asset.get("updated_at", "")))


def asset_label(name: str) -> str:
    match = re.search(r"-(\d+\.\d+\.\d+)-build-(\d+)", name)
    if not match:
        return name
    return f"{match.group(1)} · build {match.group(2)}"


def main() -> int:
    release = fetch_release()
    raw_assets = release.get("assets", [])
    selected = {
        key: choose_asset(raw_assets, pattern)
        for key, pattern in ASSET_PATTERNS.items()
    }
    missing = [key for key, asset in selected.items() if asset is None]
    if missing:
        print(f"Missing expected release assets: {', '.join(missing)}", file=sys.stderr)
        return 1

    assets = {
        key: {
            "name": asset["name"],
            "url": asset["browser_download_url"],
            "label": asset_label(asset["name"]),
        }
        for key, asset in selected.items()
    }
    payload = {
        "repository": REPOSITORY,
        "tag": release["tag_name"],
        "name": release.get("name", release["tag_name"]),
        "url": release["html_url"],
        "published_at": release.get("published_at"),
        "assets": assets,
    }

    docs = Path(__file__).resolve().parents[1] / "docs"
    output = docs / "release.json"
    output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {output}")

    rewrite_static_links(docs / "index.html", assets, release["html_url"])
    return 0


def rewrite_static_links(index_path: Path, assets: dict, release_url: str) -> None:
    """Point the static hrefs at the current release.

    The page's JavaScript rewrites the download buttons from release.json at
    runtime, but the hardcoded hrefs embed a versioned filename. Without this
    step, the pre-JS / no-JS fallback would 404 the moment a new build ships
    with a different filename. Rewriting the hrefs here keeps the static markup
    in sync with the resolved latest release on every Pages deploy.
    """
    if not index_path.exists():
        print(f"Skipped static link rewrite: {index_path} not found", file=sys.stderr)
        return
    html = index_path.read_text(encoding="utf-8")

    def rewrite_href(tag: str, url: str) -> str:
        if 'href="' in tag:
            return re.sub(r'href="[^"]*"', f'href="{url}"', tag, count=1)
        return tag[:2] + f' href="{url}"' + tag[2:]

    for key, asset in assets.items():
        url = asset["url"]
        pattern = re.compile(r'<a\b[^>]*\bdata-release-asset="' + re.escape(key) + r'"[^>]*>')
        html = pattern.sub(lambda m, u=url: rewrite_href(m.group(0), u), html)

    # Point any "open the latest release" links at the resolved release page.
    html = re.sub(
        r'href="https://github\.com/[^"]*/releases/latest"',
        f'href="{release_url}"',
        html,
    )

    index_path.write_text(html, encoding="utf-8")
    print(f"Rewrote static download links in {index_path}")


if __name__ == "__main__":
    raise SystemExit(main())
