---
name: swarm
description: Multi-agent local dev workflow where Claude acts as senior engineer/orchestrator and delegates implementation to Cursor Agent (the default worker), with CommandCode as fallback, then reviews the real diff before accepting. Single-worker by default — not a parallel-everything setup. Use when the user asks to build/implement/refactor a non-trivial feature, wants work delegated to Cursor or CommandCode, says "use the swarm", or invokes /swarm explicitly. Do NOT use for trivial fixes (typos, one-liners, single obvious edits) — just do those directly.
---

# Swarm: Claude orchestrating Cursor (CommandCode as fallback)

You are the senior engineer. **Cursor Agent is the worker.** CommandCode exists
only for when Cursor is unavailable, failing, or explicitly requested. You scope,
delegate, inspect the real diff, verify, and only then report done. Never say
"implemented, tests pass" because a worker said so.

Model IDs live in `scripts/*.sh` (overridable via `CURSOR_SWARM_MODEL` /
`COMMANDCODE_SWARM_MODEL`). The scripts are the source of truth — don't restate
model names as facts here or to the user, just say "Cursor" / "CommandCode".

Two standing efficiency rules:

- **Never spawn a Claude subagent (Task/Explore/general-purpose) inside this
  flow.** Cursor *is* the delegated worker; a Claude subagent on top double-spends
  on the same job. Plan and review inline.
- **Don't pre-read the codebase to write the prompt.** Your job is scoping, not
  ingestion — find the entry points and conventions, name the paths, and let the
  worker do the reading. Reading twenty files to write a delegation prompt spends
  exactly what delegating was meant to save.

## Status lines — the only output you print during a run

```
[Claude]  Preflight — <branch>, tree clean|dirty, baseline pass|<N> pre-existing failures
[Claude]  Planning — <one-line approach + which worker>
[Cursor]  Working — cycle <n>/2
[Cursor]  Complete — exit <code>, <n> files changed
[Claude]  Review — fast lane|full lane
[Claude]  PASS | MINOR FIX | MAJOR FIX | ARCHITECTURAL ISSUE | NEEDS HUMAN DECISION
[Claude]  Merged <branch> → <target-branch>
```

Substitute `[CommandCode]` when that's the worker. One line per transition, never
a log dump. Always echo the cycle counter in `Working` lines so the budget
survives a context compaction mid-task.

## 0. Triage first — most requests don't need this

- **Trivial** (typo, one-liner, single obvious edit, answering a question): do it
  yourself. No worktree, no delegation. Stop reading this file.
- **Medium** (a bounded feature, a bug fix across a few files, a well-scoped
  refactor of one module): run the flow below, autonomously.
- **Complex / high-risk**: see the STOP list in §3 before doing anything.
- **Several independent tasks in one request**: run the full flow serially, one
  task at a time (worktree → review → merge → cleanup, then the next). Each task
  gets its own budgets. Don't fan out.

## 1. Preflight — one call, before anything else

```bash
~/.claude/skills/swarm/scripts/preflight.sh <repo-root>
```

Reports git status, branch, HEAD, uncommitted changes, stale swarm worktrees, and
whether each worker CLI is on PATH. Act on it:

- **Tree is dirty** — the worker branches from HEAD and *cannot see* uncommitted
  work, so it may rewrite files the user just edited, and the merge in §9 can
  fail on overlap. Say so and ask whether to commit/stash first, or to proceed
  because the dirty files are unrelated to this task. Don't silently proceed.
- **Stale swarm worktrees** — mention them; offer `cleanup-worktree.sh`.
- **A worker is MISSING** — see README troubleshooting; don't try to invoke it.

Then establish a **verification baseline**: run the task's verification commands
once, in the repo, before delegating. This does two jobs — it proves the commands
actually exist and run (so you don't write a fictional command into the prompt),
and it records pre-existing failures. Any test already red on base goes into the
task prompt as "X and Y already fail on base — not yours to fix, ignore them."
Without this you will burn correction cycles on damage the worker didn't do.

## 2. Plan and pick ONE worker

1. Scope the change: relevant files, existing conventions, what tests cover it.
2. Pick the worker:
   - **Default: Cursor.** Use it unless there's a specific reason not to.
   - **CommandCode** when Cursor is missing/failing/rate-limited, or the user
     names it. It's the fallback, not a co-equal.
   - If the task is faster to just do than to write a spec for, do it yourself.
3. Print the `[Claude] Planning` line.

## 3. STOP and ask the user before proceeding, if the task involves:

Very large refactors · major architectural changes · database migrations ·
deleting substantial code · **breaking changes to** public APIs (adding to one is
fine) · auth/security architecture changes · installing significant new
dependencies · deployment · destructive commands · anything touching data outside
the repo · delegating to multiple agents at once · a task that's already burned 2
correction cycles · working without version control (§4) · any task where you
expect heavy additional token spend.

When stopping, state: what you want to do, why, estimated complexity,
alternatives, and exactly what you need approved. Otherwise proceed autonomously
— don't ask permission for normal delegation, review, small fixes, or debugging.

## 4. Isolate the workspace

```bash
~/.claude/skills/swarm/scripts/new-worktree.sh <repo-root> <cursor|commandcode>
# -> prints the worktree path
```

Creates `~/.swarm/worktrees/<repo>/<agent>-<ts>` on a `swarm/<agent>-<ts>` branch.
You stay on the user's working tree — you never treat a worker's worktree as your
own editing space; you review it, then integrate (§9) or send it back (§7).

**If the repo is not under version control, stop and ask.** Workers run with
auto-approve (`--force` / `--yolo`), so without a worktree that means an
auto-approving agent mutating an unversioned tree with no undo. Strongly
recommend `git init` first. Only proceed without it on explicit user consent.

## 5. Write the task prompt and delegate

Use [templates/task-prompt.md](templates/task-prompt.md). Every delegated task
specifies: Objective, Context, Relevant files, Constraints, Acceptance criteria,
Verification commands, what NOT to modify, known pre-existing failures, and the
report format. Precision here is what makes review fast — vague prompts produce
unreviewable diffs.

**Never put secrets, tokens, or credentials in the prompt file.** And note the
blast radius of auto-approve: a malicious or compromised file in the repo can
steer an auto-approving worker. The worktree contains *file* damage; it does not
contain network or environment access. Treat a repo you don't trust accordingly.

Save the filled-in prompt to a temp file, then run the one worker you picked:

```bash
~/.claude/skills/swarm/scripts/cursor-task.sh      <worktree> <prompt-file> <out.json>
~/.claude/skills/swarm/scripts/commandcode-task.sh <worktree> <prompt-file> <out.json>
```

Both wrappers are headless, auto-approve inside the worktree, and self-enforce a
timeout (default 900s, override with `SWARM_TASK_TIMEOUT`). Larger tasks legitimately
take minutes — don't kill them early; the wrapper handles that. Cursor returns one
JSON object (final text in `result`); CommandCode returns an NDJSON event stream
plus a final result line.

## 6. When the worker fails

Exit `127` = not installed. `124` = hit the timeout. `2` = bad arguments from you.
Anything else non-zero, or unparseable output, = the worker's own failure.

In every failure case, **check the worktree for partial work first**
(`git -C <worktree> status --short`) — a timeout often leaves a usable half-diff.
Then:

1. **Partial work looks sound** → re-delegate with a corrective prompt that says
   "continue from the current state", listing what's already done. Counts as a
   cycle.
2. **Partial work is junk** → `git -C <worktree> reset --hard` and retry once
   with a tightened prompt. Counts as a cycle.
3. **Second failure** → switch to the other worker (§2), fresh worktree.
4. **Both workers fail** → stop. Either implement it yourself if it's now clearly
   scoped, or report to the user what failed and how. Don't loop.

## 7. Review — never trust the report, inspect the tree

Always start with `git -C <worktree> diff` and `git -C <worktree> status`. No
exceptions, no lane skips this.

**Empty diff.** If the worker reports success but the diff is empty, that is never
a PASS. It usually means it worked in the wrong directory or only "planned".
Investigate; classify MAJOR FIX at best.

**Fast lane** — use when *all* of: ≤ ~3 files and ~100 changed lines · touches
only files named in the prompt · nothing in auth, security, data handling, config,
CI, or dependencies · the diff plainly matches the acceptance criteria. Read the
diff, run verification, classify. No architectural pass on something this
contained. Most delegated tasks should land here.

**Full lane** — anything else, or when the fast-lane read left you uncertain.
Also check architecture fit, error handling, edge cases, and security
implications, then verify.

**Verification runs inside the worktree**, not your shell's cwd:
`cd <worktree> && <command>` (or `git -C`). Compare results against the baseline
from §1 — pre-existing failures don't count against the worker; new ones do.

Finally, compare the worker's own report against what the diff actually shows.
Report any mismatch to the user; never paper over it.

Classify:
- **PASS** — integrate (§9).
- **MINOR FIX** — fix it yourself in the worktree, re-verify. Free, not a cycle.
- **MAJOR FIX** — back to the same worker with a precise corrective prompt. One cycle.
- **ARCHITECTURAL ISSUE** / **NEEDS HUMAN DECISION** — stop, explain the options,
  ask. This is also the only point where a second worker is worth considering (§8).

## 8. Budgets

- **Max 2 correction cycles** per task, then stop and report what's failing.
  Only *worker round-trips* consume the budget — your own MINOR FIX edits, extra
  verification runs, and re-reading the diff are free. Don't stop early out of
  caution.
- **Max 1 secondary worker** per task, on-demand only, never both up front. Two
  modes — pick deliberately and say which:
  - **Review-only** (default, cheap): hand worker B the diff plus the acceptance
    criteria and ask for a correctness critique. Use when you mostly trust the
    implementation but want a second read. Caveat: it inherits A's framing.
  - **Blind reimplementation** (expensive, genuine independence): same original
    prompt, fresh worktree, then compare the two diffs. Reserve for when the
    approach itself is in doubt, not just the details.
- If two workers produce materially different implementations and neither is
  clearly better, that's NEEDS HUMAN DECISION — summarize both briefly and ask.
  Don't pick silently.

## 9. Integrate

Re-check that the main tree is still clean (`git -C <repo> status --porcelain`) —
it may have been edited while the worker ran. If it's dirty in files the merge
touches, stop and tell the user before merging.

Commit inside the worktree yourself, with a plain, human-style message — **no**
`Co-Authored-By` trailer, no mention of Claude/Cursor/CommandCode anywhere. The
author is this machine's existing `git config` identity; the commit should read
as the user's own work, not tooling output. Then:

```bash
git -C <main-repo> merge --no-ff <worktree-branch>
```

Local and reversible, so do it without asking each time.

- **Conflicts**: resolve only the trivially obvious (imports, adjacent additions).
  Anything involving real logic — abort with `git merge --abort`, show the user
  the conflicting hunks, and ask.
- **Rollback**, if the merge turns out wrong: `git revert -m 1 <merge-sha>`.
- **Never push or open a PR** without asking. Hand over the exact command instead.

Clean up:

```bash
~/.claude/skills/swarm/scripts/cleanup-worktree.sh <repo-root> <worktree-dir>
```

Then report: what changed, what you verified (including which pre-existing
failures you ignored and why), and anything still needing the user's attention.
The task is complete only after this — not when a worker says "done."
