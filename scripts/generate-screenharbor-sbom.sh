#!/usr/bin/env bash

# Generates a CycloneDX 1.5 SBOM for one Vamp or legacy release artifact.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -eq 6 ]] || {
  printf 'Usage: %s <artifact> <host|client|ios-client|vamp-terminal|vamp-host|vamp-terminal-host> <version> <build> <commit> <output>\n' "$0" >&2
  exit 64
}

artifact="$1"
component="$2"
version="$3"
build="$4"
commit="$5"
output="$6"

[[ -f "$artifact" ]] || { printf 'Artifact not found: %s\n' "$artifact" >&2; exit 1; }
[[ "$component" == host || "$component" == client || "$component" == ios-client || "$component" == vamp-terminal || "$component" == vamp-host || "$component" == vamp-terminal-host ]] || {
  printf 'Component must be host, client, ios-client, vamp-terminal, vamp-host, or vamp-terminal-host\n' >&2
  exit 64
}

sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"
serial_seed="$(printf '%s:%s' "$commit" "$(basename "$artifact")" | shasum -a 256 | awk '{print $1}')"
serial="${serial_seed:0:8}-${serial_seed:8:4}-${serial_seed:12:4}-${serial_seed:16:4}-${serial_seed:20:12}"

ARTIFACT="$artifact" COMPONENT="$component" VERSION="$version" BUILD="$build" \
  COMMIT="$commit" OUTPUT="$output" SHA="$sha" SERIAL="$serial" \
  python3 - <<'PY'
import datetime
import json
import os

artifact = os.environ["ARTIFACT"]
component = os.environ["COMPONENT"]
version = os.environ["VERSION"]
build = os.environ["BUILD"]
commit = os.environ["COMMIT"]
output = os.environ["OUTPUT"]
sha = os.environ["SHA"]
serial = os.environ["SERIAL"]

app_name = {
    "host": "Vamp Host",
    "client": "Vamp Remote Client",
    "ios-client": "Vamp Remote Client for iOS",
    "vamp-terminal": "Vamp Terminal",
    "vamp-host": "Vamp Host",
    "vamp-terminal-host": "Vamp Terminal Host",
}.get(component, "Vamp")
bundle_id = {
    "host": "uk.mesut.screenharbor.host",
    "client": "uk.mesut.screenharbor.client",
    "ios-client": "uk.mesut.screenharbor.ios",
    "vamp-terminal": "com.mesutcy.remotedesktop.terminal",
    "vamp-host": "com.mesutcy.remotedesktop.host",
    "vamp-terminal-host": "com.mesutcy.remotedesktop.terminalhost",
}[component]

application = {
    "type": "application",
    "name": app_name,
    "version": f"{version}+{build}",
    "bom-ref": f"pkg:generic/{bundle_id}@{version}?build={build}",
    "hashes": [{"alg": "SHA-256", "content": sha}],
    "externalReferences": [
        {
            "type": "distribution",
            "url": f"https://mesut.uk/{os.path.basename(artifact)}",
        },
        {
            "type": "vcs",
            "url": f"https://github.com/Mesutcydev/macpair/tree/{commit}",
        },
    ],
}

dependencies = [
    {
        "type": "library",
        "group": "xiph.org",
        "name": "opus",
        "version": "1.4",
        "bom-ref": "pkg:generic/opus@1.4",
        "licenses": [{"license": {"id": "BSD-3-Clause"}}],
    },
]
if component in {"client", "ios-client", "vamp-terminal"}:
    dependencies.append(
        {
            "type": "library",
            "group": "github.com/migueldeicaza",
            "name": "SwiftTerm",
            "version": "1.15.0",
            "bom-ref": "pkg:github/migueldeicaza/SwiftTerm@1.15.0",
            "licenses": [{"license": {"id": "MIT"}}],
        }
    )

payload = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{serial}",
    "version": 1,
    "metadata": {
        "timestamp": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "tools": {
            "components": [
                {
                    "type": "application",
                    "name": "generate-vamp-sbom.sh" if component.startswith("vamp-") else "generate-screenharbor-sbom.sh",
                }
            ]
        },
        "component": application,
        "properties": [
            {"name": "vamp:sourceCommit" if component.startswith("vamp-") else "screenharbor:sourceCommit", "value": commit},
            {
                "name": "vamp:codeSignature" if component.startswith("vamp-") else "screenharbor:codeSignature",
                "value": "unsigned" if component in {"ios-client", "vamp-terminal"} else "ad-hoc",
            },
            {"name": "vamp:appleNotarized" if component.startswith("vamp-") else "screenharbor:appleNotarized", "value": "false"},
        ],
    },
    "components": dependencies,
    "dependencies": [
        {
            "ref": application["bom-ref"],
            "dependsOn": [item["bom-ref"] for item in dependencies],
        }
    ],
}

with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
