---
name: swarm
description: Multi-agent local dev workflow where Cursor (on whatever model tier you've set) acts as senior engineer/orchestrator and delegates implementation to one worker — CommandCode, OpenCode, or a second cursor-agent instance on a cheaper model — then reviews the real diff before accepting. Single-worker by default. Use when the user asks to build/implement/refactor a non-trivial feature, wants work delegated, says "use the swarm", or invokes /swarm explicitly. Do NOT use for trivial fixes (typos, one-liners, single obvious edits) — just do those directly.
---

# Swarm: Cursor orchestrating CommandCode / OpenCode / a cheaper Cursor worker

You are the senior engineer. You plan, delegate to **one** worker, inspect the
real diff, verify, and only then report done. Never say "implemented, tests
pass" because a worker said so.

This is the Cursor-orchestrated counterpart to a Claude Code skill of the same
name at `~/.claude/skills/swarm/`. They're independent entry points on the same
idea — invoke whichever tool you're already in. This file assumes you (the
orchestrator) are `cursor-agent`, running headless with `-p --force`.

Model IDs live in `scripts/*.sh` (overridable via `COMMANDCODE_SWARM_MODEL` /
`OPENCODE_SWARM_MODEL` / `CURSOR_SWARM_WORKER_MODEL`). Don't restate model
names as facts here or to the user — just say the tool name.

**Critical guardrail — you have a native `Task` tool that spawns your own
subagents (`.cursor/agents/*.md`). Do not use it as part of this flow.**
CommandCode / OpenCode / the worker `cursor-agent` process already are the
delegated workers. Invoking your own `Task` subagent on top of one of them
double-spends on the same job — exactly the mistake the Claude-orchestrated
version guards against by banning Claude subagents. Plan and review inline,
using your own direct tool calls (Shell, Read, Grep), not `Task`.

## Status lines — the only output you print during a run

```
[Cursor]      Preflight — <branch>, tree clean|dirty, baseline pass|<N> pre-existing failures
[Cursor]      Planning — <one-line approach + which worker>
[CommandCode] Working — cycle <n>/2
[CommandCode] Complete — exit <code>, <n> files changed
[Cursor]      Review — fast lane|full lane
[Cursor]      PASS | MINOR FIX | MAJOR FIX | ARCHITECTURAL ISSUE | NEEDS HUMAN DECISION
[Cursor]      Merged <branch> → <target-branch>
```

Substitute `[OpenCode]` or `[Cursor-worker]` when that's the worker. One line
per transition, never a log dump. Echo the cycle counter in `Working` lines so
the budget survives a context reset mid-task.

## 0. Triage first — most requests don't need this

- **Trivial** (typo, one-liner, single obvious edit, answering a question): do it
  yourself. No worktree, no delegation, no `Task` subagent. Stop reading this file.
- **Medium** (a bounded feature, a bug fix across a few files, a well-scoped
  refactor of one module): run the flow below, autonomously.
- **Complex / high-risk**: see the STOP list in §3 before doing anything.
- **Several independent tasks in one request**: run the full flow serially, one
  task at a time. Each task gets its own budgets. Don't fan out.

## 1. Preflight — one call, before anything else

```bash
~/.cursor/skills/swarm/scripts/preflight.sh <repo-root>
```

Reports git status, branch, HEAD, uncommitted changes, stale swarm worktrees, and
whether each worker CLI is on PATH (it checks `cursor`/`commandcode`; also
manually check `command -v opencode` if you're considering that worker). Act on it:

- **Tree is dirty** — the worker branches from HEAD and *cannot see* uncommitted
  work. Say so and ask whether to commit/stash first, or proceed because the
  dirty files are unrelated. Don't silently proceed.
- **Stale swarm worktrees** — mention them; offer `cleanup-worktree.sh`.
- **A worker is MISSING** — see README troubleshooting; don't try to invoke it.

Then establish a **verification baseline**: run the task's verification commands
once, in the repo, before delegating. Confirms the commands actually work and
records pre-existing failures so you don't burn correction cycles on damage the
worker didn't cause.

## 2. Plan and pick ONE worker

1. Scope the change: relevant files, existing conventions, what tests cover it.
   Use `codebase-memory-mcp` (`search_graph`, `get_architecture`, `trace_path`) if
   it's configured, rather than reading files by hand — same reasoning as the
   Claude-orchestrated version: your job here is scoping, not ingestion.
2. **Pick the worker — ask, don't assume.** Unless the user's own request already
   named one (e.g. "use OpenCode", "delegate to CommandCode"), you must ask before
   delegating. Present a numbered list and wait for the answer:
   ```
   Which worker should implement this?
   1. CommandCode      — general-purpose, separate model family from Cursor's own
   2. OpenCode         — alternate general-purpose worker; some free models have
                          caused billing-side friction before (see README)
   3. cursor-agent (worker tier) — cheapest/fastest, same tool as you on a
                          cheaper model, when the task doesn't need a different
                          model's perspective
   ```
   Skip the question only when the request already specifies the worker — then
   proceed straight to delegation with that one. This is separate from §0's
   trivial-task bypass: "do it yourself" is a triage decision made before this
   step, not one of the numbered options.
3. Print the `[Cursor] Planning` line.

## 3. STOP and ask the user before proceeding, if the task involves:

Very large refactors · major architectural changes · database migrations ·
deleting substantial code · **breaking changes to** public APIs (adding to one is
fine) · auth/security architecture changes · installing significant new
dependencies · deployment · destructive commands · anything touching data outside
the repo · delegating to multiple agents at once · a task that's already burned 2
correction cycles · working without version control (§4) · any task where you
expect heavy additional token spend.

When stopping, state: what you want to do, why, estimated complexity,
alternatives, and exactly what you need approved. Otherwise proceed autonomously.

## 4. Isolate the workspace

```bash
~/.cursor/skills/swarm/scripts/new-worktree.sh <repo-root> <commandcode|opencode|cursor-worker>
# -> prints the worktree path
```

Creates `~/.swarm/worktrees/<repo>/<agent>-<ts>` on a `swarm/<agent>-<ts>` branch.
You (the orchestrator) never treat a worker's worktree as your own editing
space; you review it, then integrate (§9) or send it back (§7).

**If the repo is not under version control, stop and ask.** Workers run with
auto-approve (`--force` / `--auto`), so without a worktree that means an
auto-approving agent mutating an unversioned tree with no undo. Strongly
recommend `git init` first. Only proceed without it on explicit user consent.

Note: `new-worktree.sh` and `~/.swarm/worktrees/` are shared with the
Claude-orchestrated version — both write under the same namespace, keyed by
repo name and agent name, so `git worktree list` shows everything regardless of
which orchestrator created it.

## 5. Write the task prompt and delegate

Use [templates/task-prompt.md](templates/task-prompt.md) — same shape as the
Claude-orchestrated version. Every delegated task specifies: Objective, Context,
Relevant files, Constraints, Acceptance criteria, Verification commands, what
NOT to modify, known pre-existing failures, and the report format.

**Never put secrets, tokens, or credentials in the prompt file.** A malicious or
compromised file in the repo can steer an auto-approving worker; the worktree
contains *file* damage, not network/environment access.

Save the filled-in prompt to a temp file, then run the one worker you picked:

```bash
~/.cursor/skills/swarm/scripts/commandcode-task.sh    <worktree> <prompt-file> <out.json>
~/.cursor/skills/swarm/scripts/opencode-task.sh       <worktree> <prompt-file> <out.json>
~/.cursor/skills/swarm/scripts/cursor-worker-task.sh  <worktree> <prompt-file> <out.json>
```

All three are headless, auto-approve inside the worktree, and self-enforce a
timeout (default 900s, override with `SWARM_TASK_TIMEOUT`). Larger tasks
legitimately take minutes — don't kill them early. CommandCode and cursor-worker
return JSON with a final result field; OpenCode returns JSON events via
`--format json`.

## 6. When the worker fails

Exit `127` = not installed. `124` = hit the timeout. `2` = bad arguments from you.
Anything else non-zero, or unparseable output, = the worker's own failure.

Check the worktree for partial work first (`git -C <worktree> status --short`).
Then:

1. **Partial work looks sound** → re-delegate with a corrective prompt ("continue
   from current state", listing what's done). Counts as a cycle.
2. **Partial work is junk** → `git -C <worktree> reset --hard`, retry once with a
   tightened prompt. Counts as a cycle.
3. **Second failure** → switch to a different worker (§2), fresh worktree.
4. **All workers you've tried fail** → stop. Implement it yourself if now clearly
   scoped, or report to the user what failed and how. Don't loop.

## 7. Review — never trust the report, inspect the tree

Always start with `git -C <worktree> diff` and `git -C <worktree> status`. No
exceptions.

**Empty diff.** Worker reports success but diff is empty → never a PASS.
Investigate; classify MAJOR FIX at best.

**Fast lane** — ≤ ~3 files and ~100 changed lines · touches only files named in
the prompt · nothing in auth, security, data handling, config, CI, or
dependencies · diff plainly matches the acceptance criteria. Read the diff, run
verification, classify.

**Full lane** — anything else, or when the fast-lane read left you uncertain.
Check architecture fit, error handling, edge cases, security implications, then
verify. If `codebase-memory-mcp` is available, use `trace_path(mode=calls)` on
the changed symbols to get the actual blast radius rather than guessing from
file count.

**Verification runs inside the worktree**: `cd <worktree> && <command>`. Compare
against the §1 baseline — pre-existing failures don't count against the worker.

Compare the worker's own report against the diff. Report mismatches to the user.

Classify:
- **PASS** — integrate (§9).
- **MINOR FIX** — fix it yourself in the worktree, re-verify. Free, not a cycle.
- **MAJOR FIX** — back to the same worker with a precise corrective prompt. One cycle.
- **ARCHITECTURAL ISSUE** / **NEEDS HUMAN DECISION** — stop, explain, ask.

## 8. Budgets

- **Max 2 correction cycles** per task. Only worker round-trips count; your own
  MINOR FIX edits are free.
- **Max 1 secondary worker** per task, on-demand only. Two modes:
  - **Review-only** (default, cheap): hand worker B the diff + acceptance
    criteria for a correctness critique.
  - **Blind reimplementation** (expensive): same prompt, fresh worktree with a
    different worker, compare diffs.
- Two workers producing materially different implementations, neither clearly
  better → NEEDS HUMAN DECISION.
- **Never use your own `Task`/subagent tool as a substitute for or in addition
  to a worker CLI within this flow.** That's a separate budget-free capability
  you have for other purposes; mixing it into swarm delegation defeats the
  single-worker discipline this whole protocol exists to enforce.

## 9. Integrate

Re-check the main tree is still clean (`git -C <repo> status --porcelain`)
before merging.

Commit inside the worktree yourself, plain human-style message — **no**
`Co-Authored-By` trailer, no mention of Cursor/CommandCode/OpenCode anywhere.
Author is this machine's existing `git config` identity. Then:

```bash
git -C <main-repo> merge --no-ff <worktree-branch>
```

Local and reversible, so do it without asking each time.

- **Conflicts**: resolve only the trivially obvious. Otherwise `git merge --abort`,
  show the user the hunks, ask.
- **Rollback**: `git revert -m 1 <merge-sha>`.
- **Never push or open a PR** without asking. Hand over the exact command instead.

Clean up:

```bash
~/.cursor/skills/swarm/scripts/cleanup-worktree.sh <repo-root> <worktree-dir>
```

Report: what changed, what you verified, anything still needing attention. Task
is complete only after this.
