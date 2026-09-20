#!/usr/bin/env bash
# post-edit.sh — Wired to PostToolUse (Edit|Write).
#
# Purpose: keep files clean as the agent works, cheaply and silently.
# It auto-fixes the edited file and never blocks (always exits 0), so it cannot
# contribute to any loop. All actual validation/gating happens once, at the turn
# gate (turn-gate.sh). This split keeps every "should the agent keep working?"
# decision in one guarded place.
set -uo pipefail

input=$(cat)

# Extract the edited file's path. Fail open if jq is missing.
if command -v jq >/dev/null 2>&1; then
  file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
else
  file=""
fi
[ -z "$file" ] && exit 0          # not a single-file edit — nothing to do
[ -f "$file" ] || exit 0          # file no longer exists — nothing to do

verify="${CLAUDE_PROJECT_DIR:-.}/verify.sh"
[ -x "$verify" ] || exit 0        # repo hasn't adopted the contract — fail open

# Auto-fix silently. If unfixable issues remain, don't block here — the turn gate
# will catch them. Log to a file for debugging only; nothing goes back to the agent.
if out=$("$verify" --file="$file" 2>&1); then
  exit 0
else
  state_dir="${CLAUDE_PROJECT_DIR:-.}/.claude/gate"
  mkdir -p "$state_dir" 2>/dev/null || true
  printf '%s\n' "$out" | tail -n 5 >> "$state_dir/postedit.log" 2>/dev/null || true
  exit 0
fi