# docs/lessons - Lesson memory

Durable, cross-session memory of mistakes this repo has already paid for.

Written by `scripts/lessons-append.sh` (usually via the `/lesson` skill), read by
`scripts/lessons-recall.sh`, gated by `scripts/check-lessons.sh`, pruned by
`scripts/lessons-gc.sh`, and injected into agent context by
`.claude/hooks/lesson_recall.sh`, `.claude/hooks/lesson_guard.sh`, and
`.claude/hooks/failure_fingerprint.sh`.

## Files

| Path | Nature |
|---|---|
| `lessons.jsonl` | committed, append-only event log. The source of truth. |
| `ACTIVE.md` | generated view (`lessons-recall.sh --render`). Human reading and the jq-less fallback. Never edit. |
| `<git-common-dir>/ralph-memory/failures/<fp>.count` | volatile cross-session occurrence tally, shared by every worktree. |
| `<git-common-dir>/ralph-memory/drafts/<fp>.md` | volatile auto-drafts awaiting `/lesson`. Never committed: an unreviewed summary of an error message is not a lesson. |
| `<git-common-dir>/ralph-memory/injected/<session-id>` | ids already injected this session, so a reminder is said once, not every turn. |

## Why the split

`ralph` is worktree-first: `/plan` creates a clean-base worktree per task, so
`.harness/state/` is reborn empty on every task and cannot hold memory. Lessons
are therefore committed (they travel with the branch and merge into `main`), and
volatile counters live under `git rev-parse --git-common-dir`, which every
worktree of the clone shares - the same place the worktree lifecycle records
already live.

## Schema v1

One JSON object per line. **Append-only**: nothing is ever rewritten. Readers
fold the log by `id` - the newest record wins per field, and `hits` is the count
of `upsert` + `hit` records (`amend` counts for nothing -- editing a lesson's
wording is not another occurrence of the failure). Two worktrees appending concurrently therefore
produce a git conflict whose resolution is "keep both lines".

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema` | integer | yes | Always `1`. |
| `ts` | string | yes | ISO8601 UTC. |
| `id` | string | yes | 12 hex chars. Derived from `signature` if present, else `trigger_command`, else the rule text - so a failure fingerprint and its lesson share an id. |
| `op` | string | yes | `upsert` \| `amend` \| `hit` \| `promote` \| `retire`. |
| `rule` | string | on `upsert` | The imperative injected verbatim into future context. Must stand alone. |
| `cause` | string | no | Why it happened. The part actually worth remembering. |
| `symptom` | string | no | What it looked like from the outside. |
| `signature` | string | no | Normalized failure text (lowercased, paths/digits/quoted strings collapsed). Seeds the id. |
| `trigger_command` | string | no | Shell glob matched against a pending Bash command at `PreToolUse`, anchored against the whole command line -- write `*rm -rf*` to match anywhere, since a bare `rm -rf` matches only that exact command. Metacharacters (`|`, `{}`, `()`, `[]`) are literal. |
| `scope_paths` | array | no | Path globs (`**` crosses `/`, `*` does not), matched anchored at both ends against repo-relative paths -- `pkg/**` does not match `vendor/pkg/x.go`. Empty means repo-global. |
| `phase` | string | no | `plan`\|`implement`\|`self_review`\|`verify`\|`test`\|`sync_docs`\|`pr`. |
| `severity` | string | on `upsert` | `low`\|`medium`\|`high`\|`critical`. `critical` converts a matching Bash call into an `ask`. Emitted on `hit`/`promote`/`retire` only when explicitly passed, so a follow-up record cannot silently demote a lesson. |
| `slug` | string | no | Task slug it came from. |
| `evidence` | string | no | Report, log, or commit backing it. |
| `promoted_to` | string | on `promote` | Path of the guard that now enforces it. Required and enforced: `lessons-append.sh --promote` refuses without `--guard`. |
| `reason` | string | on `retire` | Why it stopped being true. |

Unknown fields are tolerated (forward-compatible). Absent optional fields are
omitted entirely, never emitted as `null`.

### Folded state

| Field | Derivation |
|---|---|
| `hits` | count of `upsert` + `hit` records for the id |
| `status` | `active` after `upsert`, `promoted` after `promote`, `retired` after `retire`; `hit` and `amend` leave it unchanged |

## Selection

`lessons-recall.sh` never returns everything. In order: drop non-`active`
(unless `--include-promoted`, which is the historical view and includes
retired lessons too, each tagged `[promoted]` or `[retired]` in the output so a
non-active lesson cannot be mistaken for a live one), drop below `--min-hits`
and `--severity-min`,
apply command-glob scope (`--command`) and path scope (`--paths`, repo-global
lessons always survive), drop any id listed in `--exclude-ids <file>` (one id
per line; a missing or empty file excludes nothing), rank by severity then hits
then recency, cut to
`--max`, then cut to a cumulative `--budget` in characters - with the
top-ranked lesson always surviving a budget too small for it.

`--exclude-ids` is applied *before* ranking on purpose. It is how the
`UserPromptSubmit` hook enforces once-per-session delivery: a lesson the agent
has already been shown must not consume one of the three slots. Filtering after
the cut instead — in the caller — means the caller also has to re-apply the cap,
and the character budget goes with it. The budget lives in exactly one place.

Without `jq`, recall degrades to `head -c` on `ACTIVE.md` for the unscoped path
and stays silent for the command-scoped path, where a wrong match would be worse
than no match.

## The promotion ladder

| Occurrences | State |
|---|---|
| 1 | volatile counter only; nothing recorded |
| 2 | lesson recorded, injected at matching scope |
| 3+ | must be promoted to a deterministic guard or retired; `check-lessons.sh` fails until then |

The ladder is the reason this store does not rot. Prose competes for attention
every session; a hook, a verify check, a test, or a CI job does not. Recording a
lesson is a way to buy time until the guard exists - not a substitute for it.
