---
name: lesson
description: Record, amend, promote, or retire a durable lesson in the repo's lesson memory (docs/lessons/lessons.jsonl). Invoke automatically when the same failure recurs across sessions, when a hook reports a repeat fingerprint, when /self-review or /cross-review finds a mistake that was preventable, and before /pr when the task involved a wrong turn worth remembering.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---
Turn a mistake this repo has now made more than once into something the next
session cannot repeat.

## When this fires

- A `PostToolUseFailure` hook reported a repeat fingerprint and pointed at a draft.
- `/self-review`, `/verify`, `/test`, or `/cross-review` found a defect whose real
  cause was a wrong assumption, not a typo.
- `./scripts/check-lessons.sh` failed: a lesson has recurred enough times that it
  must graduate into a deterministic guard.
- The operator says some variant of "you keep doing this".

## The one rule that keeps this store useful

**Prose is a staging area, not a destination.** A lesson earns its place in
context only until it can be compiled into something the agent cannot skip. Every
lesson is on a ladder:

| Occurrences | What exists |
|---|---|
| 1 | Nothing. A one-off failure is noise; recording it is how stores rot. |
| 2 | A lesson record. Injected at matching scope, once per session. |
| 3+ | A guard: a hook case, a `run-verify.sh` check, a lint rule, a test, or CI. The lesson is then marked promoted and stops costing context. |

If you cannot state the guard, the lesson is probably not yet understood well
enough to record.

## Recording a lesson

1. **Find the cause, not the symptom.** Read the draft (`<git-common-dir>/ralph-memory/drafts/<fp>.md`),
   the failing output, and the diff. "The command failed" is a symptom. "This repo's
   verify script re-runs gofmt and the implementer skipped it" is a cause.
2. **Check for an existing lesson first** so you amend rather than duplicate.
   The listing below is the historical view, so it includes lessons that are no
   longer live; those carry a `[retired]` or `[promoted]` tag. Do not amend a
   tagged one — `--amend` changes fields without changing status, so amending a
   retired lesson is a silent no-op. Record a fresh lesson instead, or bring the
   old one back with `--rule` (an upsert sets it active again).
   Amend with `--amend <id> --rule "..."`, never by re-appending `--rule`: an
   `--amend` record changes the wording without counting as another occurrence,
   while a fresh `--rule` counts as a hit and can trip the promotion gate for a
   failure that never recurred.
   ```sh
   ./scripts/lessons-recall.sh --include-promoted --max 40 --budget 100000
   ```
3. **Write it as an instruction, not an observation.** The rule text is injected
   verbatim into a future session's context. It must be actionable standing alone,
   with no memory of this conversation.
   - bad: `the sync check failed again`
   - good: `Run ./scripts/sync-skills.sh after editing .claude/skills/ - CI fails on mirror drift`
4. **Scope it.** An unscoped lesson is paid for on every session; a scoped one is
   paid for only where it applies.
   - `--trigger-command '<glob>'` fires at `PreToolUse` on the exact command shape.
     This is the strongest placement short of a guard. The glob is matched
     against the whole command line, so use `'*gh pr create*'` to fire on any
     command containing it; a bare `'gh pr create'` matches only that exact
     command. Keep it narrow -- a trigger that fires on commands merely
     mentioning the phrase trains the operator to skim guard output.
   - `--scope-paths 'internal/upgrade/**,scripts/*.sh'` fires only when those files
     are in play.
   - Leave both empty only for lessons that are true everywhere in the repo.
5. **Append it:**
   ```sh
   ./scripts/lessons-append.sh \
     --rule "Run ./scripts/sync-skills.sh after editing .claude/skills/" \
     --cause "check-skill-sync.sh fails CI when the .agents mirror drifts" \
     --symptom "verify.yml red on a docs-only change" \
     --scope-paths ".claude/skills/**" \
     --signature "<raw error text, if this came from a failure>" \
     --severity medium --slug "<task-slug>" --evidence "docs/reports/verify-<date>-<slug>.md"
   ```
   Pass `--signature` whenever the lesson came from a tool failure: the id is
   derived from it, so the failure hook can auto-count future occurrences and the
   lesson promotes itself up the ladder without anyone remembering to.

## Promoting a lesson (occurrence 3+)

Write the guard first, verify it actually fires, then record the graduation:

```sh
./scripts/lessons-append.sh --promote <id> --guard ".claude/hooks/pre_bash_guard.sh"
```

`--guard` is required and its path must exist: a promotion that points nowhere
satisfies `check-lessons.sh` and stops the lesson being injected while nothing
actually enforces it, which is the same outcome as silencing it. If the guard
genuinely lives outside this repository — a CI job defined elsewhere — set
`RALPH_LESSONS_SKIP_GUARD_CHECK=1`. If nothing can enforce the lesson, it has
not graduated: `--retire` it and say why.

```sh
```

Pick the weakest guard that genuinely cannot be bypassed:

| Mistake shape | Guard |
|---|---|
| A command that must not run, or must run differently | a case in `.claude/hooks/pre_bash_guard.sh` |
| An edit that must satisfy a shape | a `PostToolUse.d/` check |
| A step skipped before done | a check in `./scripts/run-verify.sh` |
| Wrong behavior | a test |
| Drift between two files | a sync check in CI |

A promoted lesson stops being injected. That is the payoff: the constraint moved
from the context window into the repo.

## Retiring a lesson

A lesson that stopped being true is worse than no lesson. Retire it explicitly,
with a reason:

```sh
./scripts/lessons-append.sh --retire <id> --reason "verify.sh now runs gofmt itself"
```

`./scripts/lessons-gc.sh` retires stale low-hit lessons on its own; you never need
to prune by hand, and never edit `lessons.jsonl` directly - it is append-only, and
hand edits break the fold.

## Output

- one or more appended records in `docs/lessons/lessons.jsonl`
- a regenerated `docs/lessons/ACTIVE.md` (`./scripts/lessons-recall.sh --render`)
- for a promotion: the guard itself, plus evidence that it fires
- state plainly which rung of the ladder each lesson is now on

## Insight event (best-effort)

```sh
./scripts/insights-append.sh --slug <slug> --flow standard --phase self_review \
  --verdict complete --source skill || true
```

## CLI execution modes

This skill runs under both Claude Code and Codex. The execution mode follows the
conventions in AGENTS.md and `.codex/AGENTS.override.md`.

| Aspect | Claude Code | Codex |
|--------|-------------|-------|
| Skill invocation | `/lesson` slash command | `$lesson` mention or the `/skills` menu |
| Skill body path | `.claude/skills/lesson/SKILL.md` | `.agents/skills/lesson/SKILL.md` |
| Structured prompts | `AskUserQuestion` | Numbered options printed to stdout |
| Artifacts | `docs/lessons/` (shared) | Same (CLI-agnostic) |

The drift check (`./scripts/check-skill-sync.sh`) cross-checks both bodies -
editing only one side will fail CI.
