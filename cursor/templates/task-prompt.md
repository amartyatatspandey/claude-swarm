OBJECTIVE:
{one or two sentences: exactly what to implement/fix/review}

CONTEXT:
{what the app/module currently does, why this change is needed}

RELEVANT FILES:
{explicit paths — don't make the worker go hunting}

CONSTRAINTS:
{what NOT to touch, style/conventions to follow, dependencies not to add}

ACCEPTANCE CRITERIA:
{numbered, concrete, individually checkable conditions — the worker reports
pass/fail against these one by one, so write them so that's possible}
1.
2.

VERIFICATION:
{exact commands to run: tests, type check, lint, build. Only commands you have
already confirmed exist and run in this repo.}

KNOWN PRE-EXISTING FAILURES:
{tests/checks already failing on the base commit — not yours to fix, ignore
them. Write "none" if the baseline was green.}

DO NOT MODIFY:
{files/directories that are off-limits}

REPORT:
End your response with exactly these four sections, nothing else:

FILES CHANGED
- <path> — <one line: what changed and why>

CRITERIA
- 1. PASS|FAIL — <evidence, or why not>
- 2. PASS|FAIL — <evidence, or why not>

VERIFICATION
- <command> → <exit status and the relevant output lines>

DEVIATIONS
- <anything you did differently than instructed, anything you're unsure about,
  anything you couldn't do — or "none">
