#!/usr/bin/env bash
# fingerprint-check.sh — regression check for turn-gate.sh's verdict cache.
#
# Not wired to any hook. Run by hand from anywhere:
#   bash .claude/hooks/fingerprint-check.sh
#
# What it pins: the verdict cache must key on WHICH REPO is being gated
# ($CLAUDE_PROJECT_DIR) and not on the process working directory.
#
# It used to key on both. `git -C "$repo" ls-files` prints repo-relative paths, but the
# `xargs shasum` consuming them ran in the hook's own cwd. Run with cwd pointed at a
# sibling crate of the same shape — which is exactly what this repository contains — the
# hash covered the sibling's sources while claiming to describe the gated crate. The
# gate then answered "content already proven green" for a crate it had never hashed, and
# let the agent stop on broken code. Case 3 below is that scenario.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOK_DIR/../.." && pwd)"
SIBLING="$(cd "$REPO/../greenfield_word_freq" 2>/dev/null && pwd)"
GATE="$REPO/.claude/gate"
SESSION="fingerprint-check"
GREEN="$GATE/green-fingerprint.txt"

if [ -z "$SIBLING" ]; then
  echo "SKIP: no sibling crate next to $REPO — this check needs one to be meaningful."
  exit 0
fi

backup="$(mktemp -d)"
cp "$REPO/src/main.rs" "$backup/main.rs"
[ -d "$GATE" ] && cp -R "$GATE" "$backup/gate"

restore() {
  cp "$backup/main.rs" "$REPO/src/main.rs"
  rm -rf "$GATE"
  [ -d "$backup/gate" ] && cp -R "$backup/gate" "$GATE"
  rm -rf "$backup"
}
trap restore EXIT INT TERM

# Drive the real hook: $2 is the cwd to run it from, so cwd and $CLAUDE_PROJECT_DIR can
# be made to disagree — the whole point of the check.
run_gate() {
  local label="$1" cwd="$2"
  printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SESSION" \
    | (cd "$cwd" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK_DIR/turn-gate.sh" 2>&1)
  local status=$?
  echo "    [$label] exit=$status"
  return $status
}

failures=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  $what"
  else
    echo "  FAIL  $what (expected '$expected', got '$actual')"
    failures=$((failures + 1))
  fi
}

# Short-circuit #1 skips the gate when this turn changed nothing. A stale snapshot value
# never matches the live one, which forces every case below past it and into the cache
# logic actually under test.
rm -rf "$GATE"; mkdir -p "$GATE"
echo "forced-mismatch" > "$GATE/${SESSION}-snapshot.txt"

echo "Case 1: cwd = the gated repo — populates the cache"
run_gate case1 "$REPO" > /dev/null 2>&1
first_hash="$(cat "$GREEN" 2>/dev/null)"
check "green fingerprint was written" "yes" "$([ -n "$first_hash" ] && echo yes || echo no)"

echo "Case 2: cwd = sibling crate, same gated repo — same key, so a cache hit"
out="$(run_gate case2 "$SIBLING" 2>&1)"
check "reported a cache hit" "yes" \
  "$(grep -q 'already proven green' <<< "$out" && echo yes || echo no)"
check "cache key unchanged by cwd" "$first_hash" "$(cat "$GREEN" 2>/dev/null)"

echo "Case 3: gated repo broken, cwd = sibling — the regression"
printf '\nfn regression_check_broken( {\n' >> "$REPO/src/main.rs"
out="$(run_gate case3 "$SIBLING" 2>&1)"
check "did NOT claim green for a broken repo" "no" \
  "$(grep -q 'already proven green' <<< "$out" && echo yes || echo no)"
check "blocked the agent (exit 2)" "2" "$(grep -o 'exit=[0-9]*' <<< "$out" | tail -1 | cut -d= -f2)"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "All fingerprint checks passed."
  exit 0
fi
echo "$failures fingerprint check(s) FAILED."
exit 1
