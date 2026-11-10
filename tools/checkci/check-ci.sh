#!/usr/bin/env bash
# check-ci: static gate on .github/workflows/*.yml (DESIGN.md (i) and the
# serialize-lua-ci card). Reads files only; never goes to the network.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

CI_FILE="${1:-.github/workflows/ci.yml}"
WORKFLOWS_DIR=".github/workflows"

# THE PIN, from the one place the Makefile names it (DESIGN.md (i)).
LUA_VERSION=$(sed -n 's/^LUA_VERSION[[:space:]]*:= //p' Makefile)
LUA_SHA256=$(sed -n 's/^LUA_SHA256[[:space:]]*:= //p' Makefile)
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"
# The corpus pin (DESIGN.md, "The sources"): mas-bandwidth/serialize's tag.
CORPUS_TAG=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' DESIGN.md | head -n1)

FORK_GUARD="    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

# Workflows intentionally exempt from the fleet runner rule (the fork guard and
# self-hosted runs-on). The CAA bot reacts to pull_request_target and
# issue_comment and runs on GitHub's hosted image by design. Exemption is by
# basename so the same rule holds for a scratch copy. Exempt workflows still
# obey the commit-SHA action-pin rule.
EXEMPT_WORKFLOWS=" cla.yml "

is_exempt() {
  local name
  name=$(basename "$1")
  case " $EXEMPT_WORKFLOWS " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

# check_ci runs the ci.yml-specific checks on one file. It names the offending
# line of the file when it can, and returns nonzero if anything is wrong.
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

# check_runner_rule: the repository is public and its runners are the fleet's
# own, so every job carries the fork guard on the line before its runs-on, and
# no job runs on a hosted image.
check_runner_rule() {
  local wf="$1"
  local f=0
  local ln unguarded
  unguarded=$(awk -v guard="$FORK_GUARD" '
    /^[[:space:]]+runs-on:/ { if (prev != guard) print NR }
    NF { prev = $0 }
  ' "$wf")
  if [ -n "$unguarded" ]; then
    echo "check-ci FAIL: $wf: a job runs without the fork guard (runs-on at line $(echo $unguarded | tr ' ' ','))"
    f=1
  fi
  if grep -nE '^[[:space:]]+runs-on:.*(ubuntu|macos|windows)-' "$wf" >/dev/null 2>&1; then
    ln=$(grep -nE '^[[:space:]]+runs-on:.*(ubuntu|macos|windows)-' "$wf" | head -n1 | cut -d: -f1)
    echo "check-ci FAIL: $wf: a job runs on a hosted image, not the fleet (line $ln)"
    f=1
  fi
  return "$f"
}

# check_action_pins: every "uses:" of a remote action names a 40-hex commit SHA,
# never a mutable tag or branch. Local action paths carry no "@" and are left
# alone.
check_action_pins() {
  local wf="$1"
  local f=0
  local line
  local unpinned
  unpinned=$(grep -nE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]]+@' "$wf" \
    | grep -vE '@[0-9a-f]{40}([[:space:]]*(#.*)?)?$' \
    | cut -d: -f1 || true)
  if [ -n "$unpinned" ]; then
    for line in $unpinned; do
      echo "check-ci FAIL: $wf: an action uses a mutable ref, not a commit SHA (line $line)"
    done
    f=1
  fi
  return "$f"
}

# check_workflows applies the fleet runner rule and the action-pin rule to every
# workflow in the directory, not just to ci.yml.
check_workflows() {
  local dir="$1"
  local f=0
  local wf
  for wf in "$dir"/*.yml; do
    [ -e "$wf" ] || continue
    if ! is_exempt "$wf"; then
      check_runner_rule "$wf" || f=1
    fi
    check_action_pins "$wf" || f=1
  done
  return "$f"
}

echo "RUN TestCheckCI"
if ! check_ci "$CI_FILE"; then
  echo "--- FAIL TestCheckCI"
  exit 1
fi
if ! check_workflows "$WORKFLOWS_DIR"; then
  echo "--- FAIL TestCheckCI"
  exit 1
fi
echo "--- PASS TestCheckCI"

# Self-control: the same checks against a scratch copy of ci.yml with the
# interpreter sha256 pasted in must FAIL, by name.
scratch=$(mktemp)
scratch_dir=$(mktemp -d)
trap 'rm -f "$scratch"; rm -rf "$scratch_dir"' EXIT
cp "$CI_FILE" "$scratch"
printf '\n# control: pasted %s\n' "$LUA_SHA256" >> "$scratch"
if check_ci "$scratch"; then
  echo "check-ci CONTROL FAIL: expected the pasted sha256 to be refused"
  exit 1
fi
echo "check-ci control: the pasted sha256 was refused, as required"

# Self-control: a copy with the fork guard dropped from every job must FAIL.
grep -vF "$FORK_GUARD" "$CI_FILE" > "$scratch"
if check_runner_rule "$scratch"; then
  echo "check-ci CONTROL FAIL: expected a job without the fork guard to be refused"
  exit 1
fi
echo "check-ci control: the unguarded jobs were refused, as required"

# Self-control: a hosted runner planted in a workflow OTHER than ci.yml must
# FAIL, proving the fleet rule reaches every workflow file.
cp "$WORKFLOWS_DIR"/*.yml "$scratch_dir"/
sed -i 's|^\([[:space:]]*runs-on:\).*|\1 ubuntu-latest|' "$scratch_dir/nightly-conformance.yml"
if check_workflows "$scratch_dir"; then
  echo "check-ci CONTROL FAIL: expected a hosted runner in another workflow to be refused"
  exit 1
fi
echo "check-ci control: a hosted runner in another workflow was refused, as required"

# Self-control: a mutable action tag planted in a workflow OTHER than ci.yml
# must FAIL, proving the commit-SHA pin rule reaches every workflow file.
rm -rf "$scratch_dir" && mkdir -p "$scratch_dir"
cp "$WORKFLOWS_DIR"/*.yml "$scratch_dir"/
printf '      - uses: actions/checkout@v4\n' >> "$scratch_dir/nightly-fuzz.yml"
if check_workflows "$scratch_dir"; then
  echo "check-ci CONTROL FAIL: expected a mutable action ref in another workflow to be refused"
  exit 1
fi
echo "check-ci control: a mutable action ref in another workflow was refused, as required"
