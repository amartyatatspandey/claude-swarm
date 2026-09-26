# Swarm (Cursor-orchestrated) — Cursor as senior engineer over CommandCode / OpenCode / a cheaper Cursor worker

The Cursor-side counterpart to the Claude Code `swarm` skill
(`~/.claude/skills/swarm/`). Same idea, different orchestrator: here, **Cursor
itself** — running headless as `cursor-agent -p --force`, on whatever model
tier you've configured — is the senior engineer. It plans, delegates to one
worker, inspects the real diff, and reviews before accepting.

**Independent entry point, not a replacement.** Both skills coexist. Invoke
`/swarm` inside Claude Code and Claude orchestrates; invoke it inside Cursor
and Cursor orchestrates. They share the worktree namespace (`~/.swarm/worktrees/`)
and some scripts are line-for-line copies of the Claude skill's — kept
duplicated here (not symlinked) so each skill stays independently deletable.

## 1. Why this exists

`cursor-agent` headless mode, when given `-p --force`, has a native `Task` tool
that can spawn its own subagents from `.cursor/agents/*.md` — verified
empirically, not assumed (see §9). That's a real capability, but it's Cursor
delegating to more Cursor, all under the same account/billing. This skill is
about a different thing: putting a **bigger, smarter Cursor model in the
orchestrator seat**, and having it delegate actual implementation work to a
**different tool or a cheaper model tier** — for cost or perspective diversity,
not just context isolation.

## 2. Architecture

```
YOU
 ↓
CURSOR (cursor-agent -p, orchestrator model) — preflights, scopes, picks ONE
worker, reviews the real diff, decides
 ↓
 ├── CommandCode              — independent model family
 ├── OpenCode                 — independent model family, alternate
 └── cursor-agent (worker tier) — same tool, cheaper model, separate process
 ↓
Cursor inspects git diff + runs verification (never trusts the worker's report)
 ↓
PASS → commit + merge (your git identity, no tool attribution)
MINOR FIX → Cursor fixes it · MAJOR FIX → back to the worker
ARCHITECTURAL ISSUE / big decision → stops and asks you
```

```
SKILL.md                     orchestration protocol Cursor follows
scripts/
  preflight.sh                  one-call repo/worker state check (shared w/ Claude skill)
  commandcode-task.sh           headless call to commandcode (shared w/ Claude skill)
  opencode-task.sh              headless call to opencode (Cursor-orchestrated only)
  cursor-worker-task.sh         headless call to a second cursor-agent, worker tier
  new-worktree.sh               creates an isolated worktree (shared w/ Claude skill)
  cleanup-worktree.sh           removes a worktree + branch (shared w/ Claude skill)
templates/task-prompt.md      structured delegation template (shared w/ Claude skill)
```

## 3. How Cursor invokes each worker

```bash
scripts/commandcode-task.sh   <worktree-dir> <prompt-file> <output.json>
scripts/opencode-task.sh      <worktree-dir> <prompt-file> <output.json>
scripts/cursor-worker-task.sh <worktree-dir> <prompt-file> <output.json>
```

- **CommandCode**: `cd <dir> && commandcode -p <prompt> -m <id> --output-format
  json --yolo --skip-onboarding --no-session`.
- **OpenCode**: `opencode run <prompt> --dir <dir> --model <id> --format json
  --auto`. `--auto` is OpenCode's auto-approve flag (its own docs call it
  "dangerous" — same rationale as `--force`/`--yolo`: it's confined to the
  throwaway worktree). No `--workspace` flag; `--dir` sets the run directory.
- **cursor-worker**: same as the Claude skill's `cursor-task.sh` invocation
  (`cursor-agent -p --model <id> --output-format json --force --workspace
  <dir>`), just renamed and re-pinned to a cheaper default tier so it's not
  confused with the orchestrator's own model.

All three self-enforce a timeout (default 900s, `SWARM_TASK_TIMEOUT` to
override) by polling and escalating TERM → KILL — no coreutils `timeout` on
macOS. Exit codes: `0` ok · `124` timeout · `127` not installed · `2` bad
arguments · anything else is the worker's own failure.

## 4. Model selection

Pinned in the scripts, not the protocol — same rationale as the Claude skill.

```bash
COMMANDCODE_SWARM_MODEL=<id>       # commandcode --list-models
OPENCODE_SWARM_MODEL=<id>          # opencode models
CURSOR_SWARM_WORKER_MODEL=<id>     # cursor-agent --list-models
```

The orchestrator's own model is whatever you invoked `cursor-agent` with — set
that yourself when starting the session (`cursor-agent --model <big-tier-id>`);
this skill doesn't set it for you, since it's the model *you're already running
as* when this file gets read.

## 5. Approval gates

Same list as the Claude-orchestrated skill: Cursor proceeds on its own for
preflight, inspection, tests/lint/type checks, review, small fixes, iterative
debugging, and merging a passing worktree locally. It stops and asks first for
large refactors, architectural changes, DB migrations, deleting substantial
code, breaking public API changes, auth/security changes, new dependencies,
deployment, destructive commands, data outside the repo, fanning out to more
than one worker, pushing/opening a PR, running in a non-git directory, or 2+
burned correction cycles. Exact wording: [SKILL.md](SKILL.md) §3.

**Worker choice is always confirmed, never assumed** — one mandatory numbered
question per task (§2), skipped only when the user's request already named a
worker. Not a high-risk STOP gate; a standing question asked every time.

## 6. Token/cost safeguards

- **One worker by default**, picked deliberately from three options (§2 above),
  not launched in parallel "just in case."
- **Never use the native `Task` subagent tool as part of this flow.** Cursor's
  own subagent system is a real, separate capability — verified working in §9 —
  but using it *inside* swarm delegation defeats the single-worker discipline
  the whole skill exists to enforce. [SKILL.md](SKILL.md) states this as a hard
  rule, not a suggestion.
- **Two review lanes** — small/well-scoped diffs get a quick diff-read +
  verification; bigger/riskier diffs get full architectural review.
- **Max 2 correction cycles**, only worker round-trips count against it.
- **Serial on multi-task requests.**
- Trivial requests bypass the pipeline entirely.

## 7. Git/worktree behavior

Identical to the Claude-orchestrated skill — same `new-worktree.sh` /
`cleanup-worktree.sh`, same `~/.swarm/worktrees/<repo>/<agent>-<ts>` layout, same
no-attribution commit rule, same "never push/PR without asking." Because the
worktree root is shared, `git -C <repo> worktree list` shows worktrees from
*either* orchestrator — useful if you switch between Claude Code and Cursor
mid-project and want to see everything at once.

## 8. Prompt-injection surface

Workers run with auto-approve. A malicious or compromised file in the repo can
steer one. The worktree contains *file* damage — not network or environment
access. Never put secrets or tokens in a task prompt file.

## 9. Verified capability: `cursor-agent`'s native subagents

This isn't documented behavior taken on faith — it was tested directly in this
skill's design. A `.cursor/agents/echo-tester.md` subagent was created in a
throwaway repo; `cursor-agent -p --force` was asked to inventory its tools, then
separately asked to actually invoke that subagent. It reported having a `Task`
tool (via `CallDynamicTool`, namespace `cursor`) for exactly this, and a follow-up
run confirmed it: delegating through `Task` returned the subagent's exact
expected output, not a fabricated report. Conclusion: headless `cursor-agent`
can and does self-delegate on its own, independent of this skill — which is
exactly why §6/§8 in [SKILL.md](SKILL.md) treat "don't use `Task` inside swarm"
as a hard rule rather than an assumption that it wouldn't come up.

## 10. Using it

Trigger inside Cursor by asking it to build/implement/refactor something
non-trivial, saying "use the swarm" / "delegate this to CommandCode", or with
`/swarm <task>`. Cursor triages internally; trivial asks are handled directly.

## 11. Troubleshooting

- **CommandCode fails or behaves oddly** — `commandcode status` should show
  "Authenticated as ...". Re-auth with `commandcode login`.
- **OpenCode fails, or errors on an unrelated billing/payment message** —
  this has happened before: some "free" OpenCode models still make a
  side-call (e.g. auto-title generation) on a *different*, non-free model that
  needs a payment method on file even though the task model itself is free.
  Check `opencode providers list` for auth status; if it's the side-call
  erroring, that's an OpenCode account-config issue, not a bug in this skill.
  Switch worker or model via `OPENCODE_SWARM_MODEL` if it's a recurring problem.
- **cursor-worker step fails immediately** — `cursor-agent status` should show
  "Logged in as ...". Re-auth with `cursor-agent login`.
- **A run hangs** — it can't; wrappers time out at `SWARM_TASK_TIMEOUT` (default
  900s) and exit 124.
- **Worker reported success but nothing changed** — empty diff is never a PASS;
  usually means the worker ran in the wrong directory.
- **Stale worktrees piling up** — `git -C <repo> worktree list`, then
  `scripts/cleanup-worktree.sh <repo> <path>` on orphans. Remember this list
  includes worktrees from the Claude-orchestrated skill too.
- **A commit shows tool attribution you didn't want** — bug against
  [SKILL.md](SKILL.md) §9; flag it.

## 12. Disabling it

Delete or rename `~/.cursor/skills/swarm/` (or just its `SKILL.md`). This has no
effect on the Claude Code skill at `~/.claude/skills/swarm/` — they're
independent.

## 13. Modifying the rules

Behavioral rules live in [SKILL.md](SKILL.md) — edit directly, no code changes
needed. Model choices are in `scripts/*.sh` env-var defaults.
