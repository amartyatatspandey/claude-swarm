# Swarm — Claude orchestrating Cursor + CommandCode

A Claude Code skill that turns Claude into a senior-engineer orchestrator over
two local coding workers: **Cursor Agent** (Grok 4.6 Medium) and
**CommandCode** (`poolside/laguna-s-2.1-free`). Single-worker by default —
Claude picks one per task, not both. Works in any repo — it's installed
globally.

## 1. Architecture

```
YOU
 ↓
CLAUDE CODE — plans, picks ONE worker, reviews the real diff, decides
 ↓
 ├── Cursor Agent (cursor-grok-4.6-medium)     — default primary
 └── CommandCode (poolside/laguna-s-2.1-free)  — alternate / on-demand 2nd opinion
 ↓
Claude inspects git diff + runs verification (never trusts the worker's report)
 ↓
PASS → commit + merge (Claude's own commit, no tool attribution)
MINOR FIX → Claude fixes it · MAJOR FIX → back to the worker
ARCHITECTURAL ISSUE / big decision → stops and asks you
```

Only one worker runs per task by default. A second worker is only brought in
when the first diff's review is genuinely inconclusive — not automatically in
parallel. Each worker gets its own **git worktree** so it never writes to your
real working tree directly; Claude only merges in a worktree's changes after
review passes.

Everything lives in `~/.claude/skills/swarm/`:
```
SKILL.md              orchestration protocol Claude follows
scripts/
  cursor-task.sh         headless call to cursor-agent
  commandcode-task.sh    headless call to commandcode
  new-worktree.sh        creates an isolated worktree for a worker
  cleanup-worktree.sh    removes a worktree + branch after integration
templates/task-prompt.md  structured delegation template
```

## 2. How Claude invokes Cursor

```bash
scripts/cursor-task.sh <worktree-dir> <prompt-file> <output.json>
```
which runs:
```bash
cursor-agent -p --model cursor-grok-4.6-medium --output-format json --force \
  --workspace <worktree-dir> "$(cat <prompt-file>)"
```
`-p` is headless/scriptable mode with full file/shell tool access. `--force`
auto-approves tool calls (safe here because it's confined to a throwaway
worktree, not your real working tree). Output is a single JSON object; the
final answer is in its `result` field. Typically 5-20s for a small task.

## 3. How Claude invokes CommandCode

```bash
scripts/commandcode-task.sh <worktree-dir> <prompt-file> <output.json>
```
which runs:
```bash
cd <worktree-dir> && commandcode -p "$(cat <prompt-file>)" \
  -m poolside/laguna-s-2.1-free --output-format json --yolo \
  --skip-onboarding --no-session
```
CommandCode has no `--workspace` flag (unlike `cursor-agent`), so the wrapper
`cd`s into the worktree instead of using `--add-dir` (which only *widens*
context rather than setting the primary workspace). `--yolo` auto-approves
tool calls inside that worktree. `--skip-onboarding` avoids an interactive
prompt on automated runs. `--no-session` keeps these ephemeral delegated
subtasks out of your real CommandCode session history. Output is an NDJSON
event stream plus a final result line.

## 4. How Grok 4.6 (not fast) is selected for Cursor

The model id is pinned as `cursor-grok-4.6-medium` (confirmed via
`cursor-agent --list-models` — this is the "Cursor Grok 4.6 Medium" entry, not
one of the `-fast` variants). Override per-invocation with
`CURSOR_SWARM_MODEL=<id>` if you want a different reasoning tier (`-low`,
`-high`, `-xhigh` also exist).

## 5. How the CommandCode model is selected

Pinned as `poolside/laguna-s-2.1-free` — free, open-weight, agentic coding,
confirmed via `commandcode --list-models`. This is a free-tier model, same
risk category that caused friction with OpenCode earlier (see troubleshooting
below) — chosen anyway for zero cost. Override with
`COMMANDCODE_SWARM_MODEL=<model-id>` (e.g. `deepseek/deepseek-v4-flash`,
`moonshotai/kimi-k2.7-code`, `zai-org/glm-5.2` — run
`commandcode --list-models` for the full, current catalog; most non-free
options route through your CommandCode account billing).

## 6. Approval gates

Claude proceeds on its own for: inspecting files/diffs, running tests/lint/type
checks, delegating reasonably-scoped tasks, reviewing worker output, small fixes,
normal iterative debugging, and merging a passing worktree's changes locally.

Claude stops and asks first for: large refactors, architectural changes, DB
migrations, deleting substantial code, public API changes, auth/security
changes, new dependencies, deployment, destructive commands, anything touching
data outside the repo, fanning out to more than one worker, pushing/opening a
PR, or a task that's already burned 2 correction cycles without resolving.
Full list and exact wording is in [SKILL.md](SKILL.md) §2 — edit that section
to change the gate.

## 7. Token/cost safeguards

- **Single worker by default** — Cursor or CommandCode, never both up front. A
  second worker only gets involved if the first one's review is genuinely
  inconclusive, capped at one secondary worker per task.
- **Two review lanes** — a small, well-scoped diff gets a quick diff-read +
  verification-run; only a bigger or higher-risk diff gets a full
  architectural/security pass. Most delegated tasks should hit the fast lane.
- Max **2 correction cycles** per worker per task before Claude stops and
  reports the failure instead of retrying indefinitely.
- Claude never spawns its own subagent (Task/Explore/etc.) on top of a
  delegated task — Cursor/CommandCode already are the workers.
- Trivial requests (typos, one-liners) bypass the whole pipeline — Claude just
  does them.

## 8. Git/worktree behavior

`new-worktree.sh <repo-root> <agent-name>` creates
`~/.swarm/worktrees/<repo-name>/<agent>-<timestamp>` on a new
`swarm/<agent>-<timestamp>` branch, based on the repo's current `HEAD` (or a ref
you pass as a 3rd arg). Once a worktree's diff passes review, Claude commits it
itself with a plain commit message — no `Co-Authored-By` trailer, no mention of
Claude/Cursor/CommandCode — so the commit shows up as yours, using this
machine's normal git identity. Claude then merges (`git merge --no-ff`) into
your branch and runs `cleanup-worktree.sh <repo-root> <worktree-dir>`, which
removes the worktree and deletes its branch. Claude will never push or open a
PR on its own — if a task needs that, it stops and hands you the exact command.

If the current directory isn't a git repo, worktree isolation is skipped —
Claude will say so and either work directly or suggest `git init`.

## 9. How to start/use the system

Nothing to "start" — it's a Claude Code skill, available in any repo once
`~/.claude/skills/swarm/` exists. Trigger it by:
- asking Claude to build/implement/refactor something non-trivial, or
- explicitly saying "use the swarm" / "delegate this to Cursor" / "use
  commandcode for this", or
- invoking `/swarm <task>` directly.

Claude decides internally when it's worth invoking, and which single worker to
use — trivial asks are handled directly without ceremony.

## 10. How to troubleshoot it

- **Cursor step fails immediately** — check `cursor-agent status` (should show
  "Logged in as ..."). Re-auth with `cursor-agent login`.
- **`cursor-agent: command not found`** — it's not the same binary as `cursor`
  (that's the editor). Install it with `curl https://cursor.com/install -fsS | bash`.
- **CommandCode step fails or behaves oddly** — check `commandcode status`
  (should show "Authenticated as ..."). Re-auth with `commandcode login`.
- **CommandCode step is slow or flaky** — `poolside/laguna-s-2.1-free` is a
  free-tier model; that comes with variable latency/availability. Switch to a
  paid model on your account with `COMMANDCODE_SWARM_MODEL=<model-id>` (see
  §5) if it becomes a recurring problem.
- **Stale worktrees piling up** — list them with
  `git -C <repo> worktree list`, remove any orphaned ones with
  `scripts/cleanup-worktree.sh <repo> <path>`.
- **A commit shows tool attribution you didn't want** — that would be a bug in
  how Claude wrote the commit message per [SKILL.md](SKILL.md) §7; flag it so
  the instruction can be sharpened.

## 11. How to disable the automation

Delete or rename `~/.claude/skills/swarm/` (or just its `SKILL.md`) — without a
`SKILL.md`, Claude Code won't discover or trigger it. Nothing else on the system
depends on it; the wrapper scripts don't run on their own.

## 12. How to modify the orchestration rules

Everything behavioral — the triage rules, the approval-gate list, the
worker-selection logic, the review lanes and classifications (PASS/MINOR
FIX/MAJOR FIX/ARCHITECTURAL ISSUE/NEEDS HUMAN DECISION), the loop limits, and
the commit/integration rules — lives in [SKILL.md](SKILL.md) as plain
instructions Claude reads and follows. Edit that file directly; no code
changes needed. Model choices are pulled out into script env vars
(`CURSOR_SWARM_MODEL`, `COMMANDCODE_SWARM_MODEL`) for quick overriding without
editing the protocol itself.

## Note on CommandCode's own "taste" learning

CommandCode maintains its own project-local preference file
(`<repo>/.commandcode/taste/taste.md`) that it reads and updates automatically
based on how you work with it directly — this is separate from and unrelated
to the swarm skill's own rules in `SKILL.md`, and needs no wiring from this
skill; CommandCode picks it up on its own whenever it runs in that repo.
