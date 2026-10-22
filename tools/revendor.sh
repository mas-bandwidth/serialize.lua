#!/usr/bin/env bash
# revendor: copy STANDARD.md, IMPLEMENTING.md, conformance/ and
# conformance-controls/ verbatim from mas-bandwidth/serialize at a tag, then
# show what changed. Usage: tools/revendor.sh <tag>  (for example v2.0.0)
set -euo pipefail
tag="${1:?usage: tools/revendor.sh <tag>}"
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" https://github.com/mas-bandwidth/serialize.git "$scratch/serialize"
cd "$repo_root"
cp "$scratch/serialize/STANDARD.md" "$scratch/serialize/IMPLEMENTING.md" .
rm -rf conformance conformance-controls
cp -R "$scratch/serialize/conformance" "$scratch/serialize/conformance-controls" .
git status --short -- STANDARD.md IMPLEMENTING.md conformance conformance-controls
