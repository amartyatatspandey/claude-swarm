# Swarm — Claude orchestrating Cursor (+ CommandCode fallback)

A Claude Code skill that turns Claude into a senior-engineer orchestrator over a
local coding worker. **Cursor Agent is the default worker**; **CommandCode** is
the fallback for when Cursor is missing, failing, or you explicitly ask for it.
One worker per task — this is deliberately not a parallel-everything setup.
Works in any repo; it's installed globally.

## 1. Architecture

```
YOU
 ↓
CLAUDE CODE — preflights, scopes, picks ONE worker, reviews the real diff, decides
 ↓
 ├── Cursor Agent    — default worker
 └── CommandCode     — fallback / on-demand second opinion
 ↓
Claude inspects git diff + runs verification (never trusts the worker's report)
 ↓
PASS → commit + merge (your git identity, no tool attribution)
MINOR FIX → Claude fixes it · MAJOR FIX → back to the worker
ARCHITECTURAL ISSUE / big decision → stops and asks you
```

Each worker gets its own **git worktree**, so it never writes to your real
working tree; Claude merges a worktree in only after review passes.

```
SKILL.md                    orchestration protocol Claude follows
scripts/
  preflight.sh                one-call repo/worker state check before delegating
  cursor-task.sh              headless call to cursor-agent (default worker)
  commandcode-task.sh         headless call to commandcode (fallback)
  new-worktree.sh             creates an isolated worktree for a worker
  cleanup-worktree.sh         removes a worktree + branch after integration
templates/task-prompt.md    structured delegation template
```

## 2. Lifecycle

1. **Preflight** — `preflight.sh <repo>` reports branch, HEAD, uncommitted
   changes, stale swarm worktrees, and whether each worker CLI is installed. A
   dirty working tree is flagged and raised with you before anything runs: the
   worker branches from HEAD and can't see uncommitted work, and the later merge
   can fail on overlap.
2. **Baseline** — verification commands run once on the base commit, which both
   proves the commands actually work and records tests that were *already* red.
   Those go into the task prompt as "not yours to fix", so correction cycles
   aren't wasted on pre-existing failures.
3. **Worktree** — isolated branch for the worker.
4. **Delegate** — one worker, one structured prompt.
5. **Review** — Claude reads the real diff (fast lane or full lane), runs
   verification *inside the worktree*, compares against the baseline and against
   the worker's own report.
6. **Integrate** — commit + `merge --no-ff` + cleanup, or hand back for correction.

## 3. How Claude invokes the workers

```bash
scripts/cursor-task.sh      <worktree-dir> <prompt-file> <output.json>
scripts/commandcode-task.sh <worktree-dir> <prompt-file> <output.json>
```

Both are headless, auto-approve tool calls *inside the throwaway worktree*
(`--force` for Cursor, `--yolo` for CommandCode), and enforce their own timeout.

- **Cursor**: `cursor-agent -p --model <id> --output-format json --force
  --workspace <dir>`. Returns one JSON object; final answer in `result`.
  Typically 5–20s on a small task.
- **CommandCode**: `cd <dir> && commandcode -p <prompt> -m <id> --output-format
  json --yolo --skip-onboarding --no-session`. It has no `--workspace` flag, so
  the wrapper `cd`s in (`--add-dir` only *widens* context rather than setting the
  primary workspace). `--no-session` keeps these ephemeral subtasks out of your
  real CommandCode history. Returns an NDJSON event stream plus a final line.

**Timeouts.** Default 900s, overridable with `SWARM_TASK_TIMEOUT=<seconds>`.
macOS has no coreutils `timeout`, so the wrappers poll and escalate TERM → KILL
themselves. A timeout exits `124` and leaves any partial work in the worktree —
Claude checks for it and either continues from that state or resets, per
[SKILL.md](SKILL.md) §6. Exit codes: `0` ok · `124` timeout · `127` not
installed · `2` bad arguments · anything else is the worker's own failure.

## 4. Model selection

Model IDs are **pinned in the scripts, not in the protocol** — `SKILL.md`
deliberately says only "Cursor" and "CommandCode" so it doesn't drift as model
names change. To see or change them, edit the defaults in `scripts/*.sh`, or
override per-invocation:

```bash
CURSOR_SWARM_MODEL=<id>       # list options: cursor-agent --list-models
COMMANDCODE_SWARM_MODEL=<id>  # list options: commandcode --list-models
```

Current defaults are Cursor's Grok 4.6 Medium tier (`-low`/`-high`/`-xhigh`
variants also exist) and a free-tier CommandCode model. The free tier is chosen
for zero cost and comes with variable latency and occasional unavailability —
see troubleshooting.

## 5. Approval gates

Claude proceeds on its own for: preflight and inspection, running
tests/lint/type checks, delegating reasonably-scoped tasks, reviewing worker
output, small fixes, iterative debugging, and merging a passing worktree locally.

Claude stops and asks first for: large refactors, architectural changes, DB
migrations, deleting substantial code, **breaking** public API changes (adding to
an API is fine), auth/security changes, new dependencies, deployment, destructive
commands, data outside the repo, fanning out to more than one worker, pushing or
opening a PR, running at all in a **non-git directory**, or a task that's already
burned 2 correction cycles. Exact wording is [SKILL.md](SKILL.md) §3 — edit that
to change the gate.

## 6. Token/cost safeguards

- **One worker by default.** A second is brought in only when review is genuinely
  inconclusive, capped at one, and in one of two explicit modes: *review-only*
  (cheap — worker B critiques A's diff) or *blind reimplementation* (expensive —
  same prompt, fresh worktree, compare). Claude states which it's using.
- **Two review lanes.** A small, well-scoped diff (≤ ~3 files / ~100 lines, only
  the files it was told to touch, nothing security- or config-adjacent) gets a
  diff-read plus verification. Full architectural review is reserved for bigger
  or riskier diffs.
- **No pre-reading.** Claude scopes and names paths rather than ingesting the
  codebase to write a prompt — otherwise delegation saves nothing.
- **Max 2 correction cycles** per task. Only worker round-trips count against
  it; Claude's own small fixes are free.
- **No Claude subagents** layered on a delegated task — the worker already is one.
- **Serial on multi-task requests** — one worktree/review/merge at a time.
- Trivial requests bypass the pipeline entirely.

## 7. Git/worktree behavior

`new-worktree.sh <repo-root> <agent-name>` creates
`~/.swarm/worktrees/<repo>/<agent>-<timestamp>` on a `swarm/<agent>-<timestamp>`
branch from current `HEAD` (or a ref passed as a 3rd arg). After review passes,
Claude commits inside the worktree with a plain message — no `Co-Authored-By`
trailer, no mention of Claude/Cursor/CommandCode — so it lands under your normal
git identity, then merges with `git merge --no-ff` and runs
`cleanup-worktree.sh`, which removes the worktree and deletes its branch.

Merge conflicts: Claude resolves only trivially obvious ones (imports, adjacent
additions) and otherwise aborts and shows you the hunks. To undo an integrated
merge: `git revert -m 1 <merge-sha>`. Claude never pushes or opens a PR on its
own — it hands you the command.

**Non-git directories**: worktree isolation is unavailable, which means an
auto-approving worker mutating an unversioned tree with no undo. Claude will stop
and recommend `git init`, and only proceed if you explicitly say so.

## 8. Prompt-injection surface

Workers run with auto-approve. A malicious or compromised file in the repo can
steer one. The worktree contains *file* damage — it does not contain network or
environment access. Claude is instructed never to put secrets or tokens into a
task prompt file. Treat untrusted repos accordingly.

## 9. Using it

Nothing to start — it's a skill, live in any repo once `~/.claude/skills/swarm/`
exists. Trigger it by asking Claude to build/implement/refactor something
non-trivial, by saying "use the swarm" / "delegate this to Cursor", or with
`/swarm <task>`. Claude triages internally; trivial asks are handled directly.

During a run you'll see one status line per transition:

```
[Claude]  Preflight — main, tree clean, baseline pass
[Claude]  Planning — add retry wrapper to api client, delegating to Cursor
[Cursor]  Working — cycle 1/2
[Cursor]  Complete — exit 0, 2 files changed
[Claude]  Review — fast lane
[Claude]  PASS
[Claude]  Merged swarm/cursor-20260907-141302 → main
```

## 10. Troubleshooting

- **Cursor step fails immediately** — `cursor-agent status` should show "Logged
  in as ...". Re-auth with `cursor-agent login`.
- **`cursor-agent: command not found`** — different binary from `cursor` (the
  editor). Install: `curl https://cursor.com/install -fsS | bash`.
- **CommandCode fails or behaves oddly** — `commandcode status` should show
  "Authenticated as ...". Re-auth with `commandcode login`.
- **CommandCode is slow or flaky** — its default here is a free-tier model, with
  the variable latency/availability that implies. Switch with
  `COMMANDCODE_SWARM_MODEL=<id>` (§4).
- **A run hangs** — it can't; the wrappers time out at `SWARM_TASK_TIMEOUT`
  (default 900s) and exit 124. Raise it for genuinely long tasks.
- **Worker reported success but nothing changed** — an empty diff is never a
  PASS; it usually means the worker ran in the wrong directory. Claude is
  instructed to catch this, so flag it if one slips through.
- **Stale worktrees piling up** — `git -C <repo> worktree list`, then
  `scripts/cleanup-worktree.sh <repo> <path>` on orphans. `preflight.sh` also
  counts them.
- **A commit shows tool attribution you didn't want** — that's a bug against
  [SKILL.md](SKILL.md) §9; flag it so the instruction can be sharpened.

## 11. Disabling it

Delete or rename `~/.claude/skills/swarm/` (or just its `SKILL.md`) — without a
`SKILL.md`, Claude Code won't discover it. Nothing else depends on it; the
wrapper scripts never run on their own.

## 12. Modifying the rules

Everything behavioral — triage, approval gates, worker selection, review lanes
and classifications, failure protocol, budgets, commit/integration rules — is
plain instructions in [SKILL.md](SKILL.md). Edit it directly; no code changes
needed. Mechanical concerns (timeouts, model IDs, worktree paths, preflight
checks) live in `scripts/` so the protocol file stays short — it's loaded into
context every time the skill fires, so brevity there is a real cost saving.

## Note on CommandCode's own "taste" learning

CommandCode maintains a project-local preference file
(`<repo>/.commandcode/taste/taste.md`) that it reads and updates based on how you
work with it directly. That's separate from this skill's rules and needs no
wiring — CommandCode picks it up on its own whenever it runs in that repo.
