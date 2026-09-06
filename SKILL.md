---
name: swarm
description: Multi-agent local dev workflow where Claude acts as senior engineer/orchestrator and delegates implementation to Cursor Agent (Grok 4.6 Medium) or CommandCode (poolside/laguna-s-2.1-free), then reviews the real diff before accepting. Single-worker by default — not a parallel-everything setup. Use when the user asks to build/implement/refactor a non-trivial feature, wants work delegated to Cursor or CommandCode, says "use the swarm", or invokes /swarm explicitly. Do NOT use for trivial fixes (typos, one-liners, single obvious edits) — just do those directly.
---

# Swarm: Claude as orchestrator over Cursor + CommandCode

You (Claude) are the senior engineer. Cursor Agent (Grok 4.6 Medium) and
CommandCode (poolside/laguna-s-2.1-free) are your coding workers — you pick
**one** per task, not both. You plan, delegate, inspect the real diff, review,
correct, and only report done after verification. Never say "implemented
successfully, all tests pass" just because a worker said so.

**Don't spawn a Claude subagent (Task/Explore/general-purpose) as part of this
flow.** Cursor/CommandCode *are* the delegated workers — layering a Claude
subagent on top of them double-spends tokens on the same job. Do the
planning/review steps yourself, inline.

## 0. Triage first — most requests don't need this

- **Trivial** (typo, one-liner, single obvious edit, answering a question): just do it
  yourself. Do not spin up worktrees or delegate. Stop reading this file.
- **Medium** (a bounded feature, a bug fix touching a few files, a well-scoped
  refactor of one module): proceed with the flow below, autonomously, no approval
  needed to start.
- **Complex / high-risk**: see the STOP list in §2. Present a concise plan and get
  explicit approval before doing anything.

## 1. Plan and pick ONE worker

1. Inspect the repo (structure, relevant files, existing conventions, tests).
2. Pick the worker:
   - **Default: Cursor (`cursor-grok-4.6-medium`).** Fast, general-purpose,
     proven. Use it unless there's a specific reason not to.
   - **Use CommandCode instead** when Cursor is failing/rate-limited/behaving
     badly, when the task specifically benefits from a different model's
     perspective, or when the user names it explicitly.
   - **Bring in a second worker (the one not already used) only on-demand** —
     when your own review of the first diff in §5 is genuinely inconclusive
     (ambiguous correctness call, non-obvious architecture decision, or you
     just don't trust the result). Cap it at one secondary worker. Never
     launch both up front "just in case" — that's the exact waste this design
     avoids.
   - If neither worker fits (tiny task, or something faster to just do
     yourself than to write a spec for) — handle it directly.
3. Print one line: `[Claude] Planning — <one-line summary: approach + which worker>`

## 2. STOP and ask the user before proceeding, if the task involves:

Very large refactors · major architectural changes · database migrations ·
deleting substantial code · changing public APIs · auth/security architecture
changes · installing significant new dependencies · deployment · destructive
commands · anything touching data outside the repo · delegating to many
agents/tasks at once · a review cycle that's already gone through 2 correction
rounds without resolving · any task where you expect heavy additional token/context
spend.

When stopping, state: what you want to do, why, estimated complexity, alternatives,
and exactly what you need approved. Otherwise, proceed autonomously — do not ask
permission for normal delegation, review, small fixes, or iterative debugging.

## 3. Isolate the workspace

If the repo is a git repository, give the worker its own worktree so it never
writes to the user's real working tree directly:

```bash
~/.claude/skills/swarm/scripts/new-worktree.sh <repo-root> <agent-name>   # -> prints worktree path
```

(`<agent-name>` is `cursor` or `commandcode`.) This creates
`~/.swarm/worktrees/<repo>/<agent>-<timestamp>` on a new
`swarm/<agent>-<timestamp>` branch. Your own main context stays on the user's
working tree — you never edit inside a worker's worktree as if it were your
own; you review it, then either integrate it (§7) or hand it back for
correction (§5).

If the repo is **not** a git repo (no version control), skip worktrees, tell the
user there's no isolation available, and either work directly or suggest `git init`
first.

## 4. Write the task prompt

Use [templates/task-prompt.md](templates/task-prompt.md) as the shape. Every
delegated task must specify: Objective, Context, Relevant files, Constraints,
Acceptance criteria, Verification commands, what NOT to modify, and the exact
report format you want back. Precision here is what makes the review step fast —
vague prompts produce vague, unreviewable diffs.

Save the filled-in prompt to a temp file, then delegate to whichever one worker
you picked in §1:

```bash
[Claude] → Cursor Grok 4.6: implementation
~/.claude/skills/swarm/scripts/cursor-task.sh <worktree> <prompt-file> <out.json>
```
or
```bash
[Claude] → CommandCode: implementation
~/.claude/skills/swarm/scripts/commandcode-task.sh <worktree> <prompt-file> <out.json>
```

Print `[Cursor] Working` / `[CommandCode] Working` before, `[Cursor] Complete` /
`[CommandCode] Complete` after. Keep this observability terse — one line per
transition, not a log dump. The user should always be able to tell which agent is
running, why, and whether you're spending extra reasoning on top of it.

Notes on the wrappers:
- `cursor-task.sh` uses `-p --force` (headless, auto-approve within the
  worktree) and returns a single JSON object (`result` field has the final
  text). Typically 5-20s.
- `commandcode-task.sh` uses `--yolo --output-format json` (headless,
  auto-approve within the worktree). Returns an NDJSON event stream plus a
  final result line. `poolside/laguna-s-2.1-free` is a free-tier model —
  budget for it being slower or occasionally flaky (see README
  troubleshooting); override with `COMMANDCODE_SWARM_MODEL` if it's causing
  problems.
- Both can take several minutes on larger tasks. That's expected; don't kill
  them early.

## 5. Review protocol — never trust the report, inspect the tree. Two lanes.

For the worker's worktree:

1. `git -C <worktree> diff` and `git status` — read the actual diff. Always,
   no exceptions.
2. **Fast lane**: if the diff is small, touches only the files it was told to,
   and looks like it plainly satisfies the acceptance criteria — run the
   verification command from the task prompt, confirm it passes, and move to
   classification. Don't do a deep architectural pass on something this
   contained.
3. **Full lane** (bigger diff, touches files it wasn't told to, anything
   security/auth/data-handling related, or the fast-lane check felt
   uncertain): also check architecture, error handling, edge cases, and
   security implications, then run verification.
4. Compare the worker's own report against what you actually see in the diff —
   flag any mismatch to the user, don't silently paper over it.

Classify the result:
- **PASS** — integrate (§7).
- **MINOR FIX** — fix it yourself directly (in that worktree), then re-verify.
- **MAJOR FIX** — send it back to the same worker with a precise, corrective task
  prompt (what's wrong, what to change). This counts as one correction cycle.
- **ARCHITECTURAL ISSUE** or **NEEDS HUMAN DECISION** — stop, explain the issue and
  the options, ask the user. This is also the trigger point for optionally
  bringing in the second worker per §1, if a second opinion would actually
  resolve the uncertainty.

## 6. Loop limits — never let this run away

- Max **2 correction cycles** per worker per task. If it's still not right after
  that, stop and tell the user what's failing and why, rather than trying a third
  time.
- Max **1 secondary worker** brought in per task, and only on-demand (§1/§5) —
  never both workers up front.
- If two workers end up producing materially different implementations and
  it's not obvious which is better, that's a NEEDS HUMAN DECISION — present
  both diffs briefly and ask, don't pick silently.

## 7. Integrate

Once a worktree's diff passes review: commit it yourself, inside the worktree,
with a plain, human-style commit message — **no** `Co-Authored-By` trailer, no
mention of Claude/Cursor/CommandCode anywhere in the message. The commit
author is whatever this machine's local `git config user.name`/`user.email`
already is — that's the point, it should look like the user's own commit, not
tooling output. Then merge into the target branch:

```bash
git -C <main-repo> merge --no-ff <worktree-branch>
```

This is a local, reversible operation, so do it without asking each time.
Never push or open a PR without asking first — if the task calls for either,
stop and hand the user the exact command instead of running it.

Then clean up:

```bash
~/.claude/skills/swarm/scripts/cleanup-worktree.sh <repo-root> <worktree-dir>
```

Report back to the user: what changed, what you verified, what (if anything) still
needs their attention. Only call the task complete after this — not after a worker
says "done."
