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
# The corpus pin (DESIGN.md, "The sources"): the first full commit sha of
# mas-bandwidth/serialize that DESIGN.md names in backticks.
CORPUS_PIN=$(grep -oE '`[0-9a-f]{40}`' DESIGN.md | head -n1 | tr -d '`')
if [ -z "$CORPUS_PIN" ]; then
  echo "check-ci FAIL: DESIGN.md names no corpus commit (a backticked 40-hex sha)"
  exit 1
fi

FORK_GUARD="    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

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
  if ! grep -qF "$CORPUS_PIN" "$ci"; then
    echo "check-ci FAIL: ci.yml does not pin the corpus commit $CORPUS_PIN from DESIGN.md"
    f=1
  fi
  # THE FORK GUARD: the repository is public and its runners are the fleet's
  # own, so every job carries the guard on the line before its runs-on, and no
  # job runs on a hosted image.
  local unguarded
  unguarded=$(awk -v guard="$FORK_GUARD" '
    /^[[:space:]]+runs-on:/ { if (prev != guard) print NR }
    NF { prev = $0 }
  ' "$ci")
  if [ -n "$unguarded" ]; then
    echo "check-ci FAIL: a job runs without the fork guard (runs-on at line $(echo $unguarded | tr ' ' ','))"
    f=1
  fi
  if grep -nE '^[[:space:]]+runs-on:.*(ubuntu|macos|windows)-' "$ci" >/dev/null 2>&1; then
    ln=$(grep -nE '^[[:space:]]+runs-on:.*(ubuntu|macos|windows)-' "$ci" | head -n1 | cut -d: -f1)
    echo "check-ci FAIL: a job runs on a hosted image, not the fleet (line $ln)"
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

# Self-control: a copy with the fork guard dropped from every job must FAIL.
grep -vF "$FORK_GUARD" "$CI_FILE" > "$scratch"
if check_ci "$scratch"; then
  echo "check-ci CONTROL FAIL: expected a job without the fork guard to be refused"
  exit 1
fi
echo "check-ci control: the unguarded jobs were refused, as required"
