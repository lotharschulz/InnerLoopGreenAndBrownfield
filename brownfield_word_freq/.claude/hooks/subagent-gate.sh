#!/usr/bin/env bash
# subagent-gate.sh — wired to SubagentStop.
#
# Deliberately much leaner than turn-gate.sh. A subagent's output is re-checked by
# the main agent's Stop gate, so this only exists to give a subagent ONE early
# chance to clean up its own mess, close to where it was made. No turn snapshot, no
# lock, no persistent retry counters, no escalation to the full pass.
#
# Loop safety comes from `stop_hook_active`, which Claude Code sets to true whenever an
# agent is only still running because a stop hook sent it back. Never blocking twice is
# enough here — the expensive, stateful budget logic belongs in turn-gate.sh alone.
set -uo pipefail

input=$(cat)

repo="${CLAUDE_PROJECT_DIR:-.}"
verify="$repo/verify.sh"
[ -x "$verify" ] || exit 0        # repo hasn't adopted the contract — fail open

# Already sent back once. Let it stop; whatever is left is the Stop gate's problem.
if printf '%s' "$input" | jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
  exit 0
fi

# --no-escalate: never let a subagent trigger the slow build/coverage pass.
out=$("$verify" --changed-only --no-escalate 2>&1) && exit 0

# exit 2 → stderr is fed back to the subagent as the reason it may not stop yet.
{
  echo "Validation failed. Fix these before finishing:"
  printf '%s\n' "$out" | tail -n 20
} >&2
exit 2
