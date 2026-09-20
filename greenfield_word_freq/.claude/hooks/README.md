# stop-verify.sh — contract

Wired to `Stop` and `SubagentStop` in `.claude/settings.json` (same script for both —
a subagent's work gets exactly the same check, and the same retry budget, as the main
agent's). `post-edit-fmt.sh` runs on `PostToolUse` (Edit|Write) and only formats the
edited file; it always exits 0 and never blocks.

**Exit codes:** `0` verification passed or cache hit (agent may stop) · `2` blocking,
fix and retry — stderr is what the agent sees · `1` gave up after `MAX_ATTEMPTS=3`
consecutive failures, shown to the user rather than to the agent.

**Fingerprinted** — a match skips re-running `verify.sh` entirely: `rustc --version`,
every tracked *and* untracked file under `src/` (content-hashed, not just names),
`Cargo.toml`, and `verify.sh` itself.

**Deliberately NOT fingerprinted:** `Cargo.lock` (a dependency bump shouldn't
invalidate the cache — revisit once this crate has real dependencies), and anything
outside `src/` (add it to `compute_fingerprint` if a `tests/` or `build.rs` appears).
No git repository means an *empty* fingerprint, which never matches, so verification
runs in full rather than being silently skipped.

**Retry budget** is per session and resets only on a green run or a cache hit — a
session interrupted mid-failure starts the next one a step into the count.

**State** lives in `.claude/gate/`, which must stay gitignored: `gate.log` (audit
trail of every run — `tail -f` it), `<session>.count` (per-session retry counter),
`green.fingerprint` (per repo, shared across sessions on purpose — that is what makes
the cache useful beyond a single session). `rm -rf .claude/gate` resets everything.

**Debug:** `claude --debug` shows each hook command and its exit code; `/hooks` shows
what Claude Code actually loaded (settings are read at startup — restart after editing
them). `bash verify.sh` runs exactly what the gate runs, with no cache in the way.
