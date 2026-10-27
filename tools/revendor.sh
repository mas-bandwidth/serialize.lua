#!/usr/bin/env bash
# revendor: copy STANDARD.md, IMPLEMENTING.md, conformance/ and
# conformance-controls/ verbatim from mas-bandwidth/serialize at a ref, then
# show what changed. Usage: tools/revendor.sh <ref>  where ref is a tag (for
# example v2.0.0) or a full commit sha.
set -euo pipefail
ref="${1:?usage: tools/revendor.sh <tag or full commit sha>}"
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git init --quiet "$scratch/serialize"
git -C "$scratch/serialize" fetch --quiet --depth 1 https://github.com/mas-bandwidth/serialize.git "$ref"
git -c advice.detachedHead=false -C "$scratch/serialize" checkout --quiet FETCH_HEAD
echo "revendor: mas-bandwidth/serialize $ref is $(git -C "$scratch/serialize" rev-parse HEAD)"
cd "$repo_root"
cp "$scratch/serialize/STANDARD.md" "$scratch/serialize/IMPLEMENTING.md" .
rm -rf conformance conformance-controls
cp -R "$scratch/serialize/conformance" "$scratch/serialize/conformance-controls" .
git status --short -- STANDARD.md IMPLEMENTING.md conformance conformance-controls
