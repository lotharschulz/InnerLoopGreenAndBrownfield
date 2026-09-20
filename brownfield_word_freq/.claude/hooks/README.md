# Hook chain — contract

Four hooks wired in `.claude/settings.json`, one per event, each with a narrower job
than greenfield's two-hook setup — because this crate assumes real history and a
verify pass expensive enough to need a change-scoped fast path (`verify.sh
--changed-only`), not just a fingerprint cache.

| Event                       | Script               | Job                                                   |
|-----------------------------|----------------------|-------------------------------------------------------|
| `UserPromptSubmit`          | `prompt-snapshot.sh` | hash the working tree at turn start; prints nothing   |
| `PostToolUse` (Edit\|Write) | `post-edit.sh`       | per-file `verify.sh --file=`, silent, never blocks    |
| `SubagentStop`              | `subagent-gate.sh`   | one cheap change-scoped check, one send-back max      |
| `Stop`                      | `turn-gate.sh`       | the real gate: full budget, cache, escalation         |

`fingerprint-check.sh` is **not wired to anything** — a hand-run regression check for
`turn-gate.sh`'s verdict cache (`bash .claude/hooks/fingerprint-check.sh`). Keep it
green whenever `verdict_fingerprint` or `repo`/cwd handling in `turn-gate.sh` changes.

## Exit codes

`post-edit.sh` and `prompt-snapshot.sh` always exit `0` — they auto-fix or record
state and never gate. `subagent-gate.sh` and `turn-gate.sh` share the Stop/SubagentStop
hook contract: `0` verification passed, cache hit, or nothing changed (agent may stop)
· `2` blocking — stderr is what the agent sees, fix and retry · `1` (turn-gate.sh only)
gave up after `MAX_ATTEMPTS=2` consecutive failures, shown to the user rather than fed
back to the agent. `subagent-gate.sh` never gives up on its own; it sends a subagent
back at most once (via `stop_hook_active`) and leaves anything still broken for
`turn-gate.sh` to catch on the main agent's Stop.

`MAX_ATTEMPTS=2` is deliberately **below** the platform's own consecutive-stop-block
cap (default ~8) — this budget must bind first, or the platform's cap becomes the real
limit and this script's give-up message never fires.

## Two short-circuits, not one

`turn-gate.sh` skips `verify.sh` entirely in two independent cases:

1. **Turn snapshot** (`prompt-snapshot.sh` + the `<session>-snapshot.txt` compare) —
   this turn changed nothing (a question, a read-only exploration). Content-hashes
   `git status` + `diff HEAD` + untracked-file contents, not just `git status`: two
   edits to an already-dirty file leave plain `git status` byte-identical, which would
   silently skip every turn after the first.
2. **Verdict cache** (`green-fingerprint.txt`) — this turn changed something, but the
   result matches content already proven green (a revert, or edits that cancel out).

Both are keyed on `rustc --version` plus a content hash of every tracked *and*
untracked file under `src/` and `tests/`, `Cargo.toml`, and `verify.sh` itself.
`Cargo.lock` is deliberately excluded — a dependency bump shouldn't invalidate the
cache; revisit once this crate has real dependencies. Add a directory to
`verdict_fingerprint` (and the matching function in `prompt-snapshot.sh`) if a
`build.rs` or similar appears — an untracked source directory doesn't fail safe, it
makes the cache silently claim green for content it never hashed.

**The hashed paths are repo-relative, so the hook's cwd must equal `$CLAUDE_PROJECT_DIR`
— hence the `cd "$repo" || exit 1` near the top of `turn-gate.sh`, mirroring
`stop-verify.sh` in the greenfield setup.** Skipping that `cd` is exactly the bug
`fingerprint-check.sh` exists to catch: with cwd pointed at a same-shaped sibling
crate (this repo has one), `git ls-files`'s repo-relative output resolves against the
wrong directory and the cache can report "already proven green" for a crate it never
looked at.

## State

Lives in `.claude/gate/`, which must stay gitignored: `gate.log` (audit trail of every
run, including silent skips — `tail -f` it), `<session>-snapshot.txt` (turn-start
fingerprint, per session), `<session>.count` (turn-gate.sh's per-session retry
counter), `green-fingerprint.txt` (per repo, shared across sessions on purpose — that
sharing is what makes the cache useful beyond a single session). `rm -rf .claude/gate`
resets everything.

## Debug

`claude --debug` shows each hook command and its exit code; `/hooks` shows what Claude
Code actually loaded (settings are read at startup — restart after editing them).
`bash verify.sh` (or `--changed-only`, `--file=<path>`) runs exactly what a given gate
runs, with no cache in the way. `bash .claude/hooks/fingerprint-check.sh` exercises
`turn-gate.sh` directly against a real and a broken tree.
