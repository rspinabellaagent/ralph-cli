# Lesson memory

This repo remembers its own mistakes. Two stores, deliberately separated:

- `docs/lessons/lessons.jsonl` - committed, append-only, merges into main.
  The lessons themselves. This is what survives worktrees, sessions, and clones.
- `<git-common-dir>/ralph-memory/` - volatile per-repo counters, drafts and
  per-session injection records. Never committed, shared by every worktree.

Anything kept in `.harness/state/` is per-worktree and dies with the task, so it
is not memory. `/plan` creates a clean-base worktree for every task; that is
exactly why the tally lives in the git common dir and the lessons live in git.

## How it reaches you

You do not read the store. It is pushed at you, scoped:

| Moment | What arrives |
|---|---|
| session start | up to 6 lessons, ranked, budgeted, scoped to the files this branch touches |
| prompt submit | only lessons scoped to currently-modified files, only recurring ones, once per session each |
| before a Bash call | only lessons whose `trigger_command` glob matches that command; `critical` ones convert the call into an `ask` |
| after a tool failure | the fingerprint of that failure, its cross-session occurrence count, and the matching lesson if one exists |

Silence is the normal output of all four. If a lesson did surface, it survived
ranking and a character budget - treat it as relevant, not as boilerplate.

## The ladder

1. **One occurrence** - nothing is recorded. One-off failures are noise, and
   recording them is how a lesson store rots into a wall nobody reads.
2. **Two** - a lesson record. Cheap, scoped, revocable.
3. **Three or more** - it must graduate into a deterministic guard: a
   `pre_bash_guard.sh` case, a `PostToolUse.d/` check, a `run-verify.sh` check, a
   test, a lint rule, or CI. `./scripts/check-lessons.sh` fails the pipeline until
   it does, and `--promote <id>` requires `--guard <path>` naming the thing that
   now enforces it — a promotion with nowhere to point is just a lesson being
   silenced. The path must exist; a guard deleted in a later refactor silently
   un-enforces its lesson while the gate keeps passing. Set
   `RALPH_LESSONS_SKIP_GUARD_CHECK=1` only when the guard genuinely lives
   outside this repository, such as a CI job defined elsewhere. If nothing can
   enforce it, `--retire` it and say why. A promoted lesson stops being injected: the constraint has moved out
   of the context window and into the repo, which is the whole point.

Prose you can ignore is not a guarantee. Do not rely on a lesson where a hook,
a test, or a script would settle it - that is the same rule as the rest of this
scaffold, applied to memory.

## Under Codex: recall yes, capture no

`.codex/hooks.json` routes `SessionStart`, `UserPromptSubmit` and `PreToolUse`,
so a Codex session is injected with lessons exactly as a Claude Code session
is. It has no `PostToolUseFailure` route, so nothing fingerprints failures or
writes drafts: a repeat failure under Codex does not climb the ladder by
itself. Record it by hand with `./scripts/lessons-append.sh --signature "<raw
error>"` — the id derives from the normalized signature, so the lesson is still
recognised automatically the next time that failure happens under Claude Code.
See `.codex/README.md` for why the route was left out rather than guessed at.

## Working with it

- Record, amend, promote or retire through `/lesson`, or call
  `./scripts/lessons-append.sh` directly from a seat with no slash-command
  dispatch. Amending is `--amend <id>`, which changes fields without counting
  as another occurrence; restating a lesson as a fresh `--rule` does count, and
  will walk it up the ladder for a failure that never recurred. Never hand-edit
  `lessons.jsonl`; it is append-only and readers fold it by id.
- When a lesson comes from a tool failure, pass `--signature` with the raw error.
  The id is derived from the normalized signature, so the failure hook can count
  later occurrences by itself and drive the promotion without anyone remembering to.
- Write rules as instructions that stand alone. They are injected verbatim into a
  session that has no memory of the conversation that produced them.
- Scope every lesson you can. An unscoped lesson is paid for on every session.
- `docs/lessons/ACTIVE.md` is regenerated on every append (`lessons-append.sh`
  calls `lessons-recall.sh --render`), not only by gc — it is the jq-less
  recall fallback, so a stale copy is a stale memory for exactly the sessions
  least equipped to notice. Bulk callers that render once at the end can set
  `RALPH_LESSONS_NO_RENDER=1` to skip the per-append re-render.
- `./scripts/lessons-gc.sh` retires stale low-hit lessons and also regenerates
  `docs/lessons/ACTIVE.md`. Run it with the other artifact GC. It also sweeps
  volatile failure counters and drafts past the same age limit — those live in
  the git common dir so they survive sessions and worktrees, which means nothing
  else ever removes them, and a change to what the failure hook fingerprints
  orphans every existing counter at once.
