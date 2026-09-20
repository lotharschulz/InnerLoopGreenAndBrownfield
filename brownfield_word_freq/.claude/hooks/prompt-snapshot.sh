#!/usr/bin/env bash
# prompt-snapshot.sh — wired to UserPromptSubmit.
# Records a fingerprint of the working tree at turn start so turn-gate.sh can detect
# whether THIS turn changed anything, rather than just checking if the tree is dirty.
#
# Prints nothing on purpose: on UserPromptSubmit, stdout is injected into Claude's context.
set -uo pipefail

input=$(cat)

session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
: "${session:=unknown}"

repo="${CLAUDE_PROJECT_DIR:-.}"
STATE_DIR="$repo/.claude/gate"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Must stay identical to the copy in turn-gate.sh.
# Status alone is not enough: re-editing an already-modified file leaves `git status`
# byte-identical, which would make the gate skip every turn after the first one.
# Hashing the diff and the untracked file contents makes the fingerprint content-sensitive.
fingerprint() {
  {
    git -C "$repo" status --porcelain
    git -C "$repo" diff HEAD
    git -C "$repo" ls-files --others --exclude-standard \
      | while IFS= read -r f; do git -C "$repo" hash-object "$f"; done
  } 2>/dev/null | git -C "$repo" hash-object --stdin 2>/dev/null
}

fingerprint > "$STATE_DIR/${session}-snapshot.txt" 2>/dev/null || true
