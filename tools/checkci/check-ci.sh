#!/usr/bin/env bash
# check-ci: static gate on .github/workflows/ci.yml (DESIGN.md (i) and the
# serialize-lua-ci card). Reads files only; never goes to the network.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

CI_FILE="${1:-.github/workflows/ci.yml}"

# THE PIN, from the one place the Makefile names it (DESIGN.md (i)).
LUA_VERSION=$(sed -n 's/^LUA_VERSION[[:space:]]*:= //p' Makefile)
LUA_SHA256=$(sed -n 's/^LUA_SHA256[[:space:]]*:= //p' Makefile)
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"
# The corpus pin (DESIGN.md, "The sources"): mas-bandwidth/serialize's tag.
CORPUS_TAG=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' DESIGN.md | head -n1)

# check_ci runs the checks on one ci.yml file. It names the offending line of
# the file when it can, and returns nonzero if anything is wrong.
check_ci() {
  local ci="$1"
  local f=0
  local ln

  if grep -nF "$LUA_SHA256" "$ci" >/dev/null 2>&1; then
    ln=$(grep -nF "$LUA_SHA256" "$ci" | head -n1 | cut -d: -f1)
    echo "check-ci FAIL: ci.yml spells the interpreter sha256 (line $ln)"
    f=1
  fi
  if grep -nF "$LUA_URL" "$ci" >/dev/null 2>&1; then
    ln=$(grep -nF "$LUA_URL" "$ci" | head -n1 | cut -d: -f1)
    echo "check-ci FAIL: ci.yml spells the interpreter URL (line $ln)"
    f=1
  fi
  if ! grep -qF "make dist-lua" "$ci"; then
    echo "check-ci FAIL: ci.yml does not run \"make dist-lua\""
    f=1
  fi
  if ! grep -qF "make test" "$ci"; then
    echo "check-ci FAIL: ci.yml does not run \"make test\""
    f=1
  fi
  if ! grep -qF "$CORPUS_TAG" "$ci"; then
    echo "check-ci FAIL: ci.yml does not pin the corpus tag $CORPUS_TAG from DESIGN.md"
    f=1
  fi
  return "$f"
}

echo "RUN TestCheckCI"
if check_ci "$CI_FILE"; then
  echo "--- PASS TestCheckCI"
else
  echo "--- FAIL TestCheckCI"
  exit 1
fi

# Self-control: the same checks against a scratch copy of ci.yml with the
# interpreter sha256 pasted in must FAIL, by name.
scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT
cp "$CI_FILE" "$scratch"
printf '\n# control: pasted %s\n' "$LUA_SHA256" >> "$scratch"
if check_ci "$scratch"; then
  echo "check-ci CONTROL FAIL: expected the pasted sha256 to be refused"
  exit 1
fi
echo "check-ci control: the pasted sha256 was refused, as required"
