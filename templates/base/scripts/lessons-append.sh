#!/usr/bin/env bash
# lessons-append.sh - Append one schema-v1 lesson record to the committed store.
#
# The store (docs/lessons/lessons.jsonl) is append-only, exactly like
# docs/insights/events/. Readers fold the log by `id`: the newest record for an
# id wins for its fields, and `hits` is the count of upsert+hit records. Nothing
# is ever rewritten in place, so two worktrees appending concurrently produce a
# git conflict that resolves as "keep both lines".
#
# Usage:
#   lessons-append.sh --rule "..." [options]          # record or re-state a lesson
#   lessons-append.sh --hit <id> [--evidence P]       # another occurrence
#   lessons-append.sh --amend <id> --rule "..."       # edit wording, no hit
#   lessons-append.sh --promote <id> --guard <path>   # graduated to a hard guard
#   lessons-append.sh --retire <id> [--reason "..."]  # no longer true / stale
#
# Options for --rule:
#   --rule TEXT             Imperative one-liner injected into context. Required.
#   --symptom TEXT          What the agent saw when it went wrong.
#   --cause TEXT            Why it happened (the part worth remembering).
#   --signature TEXT        Raw error/output text; normalized + hashed into the id.
#   --trigger-command GLOB  Match against a pending Bash command (PreToolUse).
#   --scope-paths GLOBS     Comma-separated path globs this lesson applies to.
#   --phase PHASE           plan|implement|self_review|verify|test|sync_docs|pr
#   --severity LEVEL        low|medium|high|critical   (default: medium)
#   --slug SLUG             Task slug the lesson came out of.
#   --evidence PATH         Report/commit/log backing the lesson.
#   --occurrences N         Seed the hit count: this failure was already seen N
#                           times before anyone wrote it down. --from-draft sets
#                           this from the volatile counter automatically.
#   --id ID                 Force an id instead of deriving one.
#   --from-draft FP         Adopt a failure-hook draft: reuses its fingerprint as
#                           the id (so later occurrences auto-count toward
#                           promotion) and its signature, then clears the draft.
#   --guard PATH            Required by --promote: the hook case, check, test or
#                           CI job that now enforces the lesson. The path must
#                           exist -- a promotion pointing nowhere satisfies the
#                           gate while enforcing nothing. Set
#                           RALPH_LESSONS_SKIP_GUARD_CHECK=1 for a guard that
#                           genuinely lives outside this repository.
#   --store DIR             Override store dir (default: docs/lessons).
#
# Exit: 0 success, 1 validation failure.

set -euo pipefail

_here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lessons-common.sh
. "$_here/lessons-common.sh"

_op="upsert"
_id=""
_rule=""
_symptom=""
_cause=""
_signature=""
_trigger=""
_scope=""
_phase=""
_severity="medium"
_severity_explicit=0
_slug=""
_evidence=""
_guard=""
_reason=""
_draft=""
_occurrences=""

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 1
}

[ $# -gt 0 ] || usage

while [ $# -gt 0 ]; do
  case "$1" in
    --rule)             shift; _rule="${1:-}" ;;
    --symptom)          shift; _symptom="${1:-}" ;;
    --cause)            shift; _cause="${1:-}" ;;
    --signature)        shift; _signature="${1:-}" ;;
    --trigger-command)  shift; _trigger="${1:-}" ;;
    --scope-paths)      shift; _scope="${1:-}" ;;
    --phase)            shift; _phase="${1:-}" ;;
    --severity)         shift; _severity="${1:-}"; _severity_explicit=1 ;;
    --slug)             shift; _slug="${1:-}" ;;
    --evidence)         shift; _evidence="${1:-}" ;;
    --id)               shift; _id="${1:-}" ;;
    --from-draft)       shift; _draft="${1:-}" ;;
    --occurrences)      shift; _occurrences="${1:-}" ;;
    --store)            shift; RALPH_LESSONS_STORE="${1:-}"; export RALPH_LESSONS_STORE ;;
    --hit)              _op="hit";     shift; _id="${1:-}" ;;
    --amend)            _op="amend";   shift; _id="${1:-}" ;;
    --promote)          _op="promote"; shift; _id="${1:-}" ;;
    --guard)            shift; _guard="${1:-}" ;;
    --retire)           _op="retire";  shift; _id="${1:-}" ;;
    --reason)           shift; _reason="${1:-}" ;;
    -h|--help)          usage ;;
    *) printf 'lessons-append.sh: unknown flag: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift || true
done

if [ -n "$_draft" ]; then
  # The failure hook already computed the fingerprint that future occurrences
  # will hash to. Reusing it as the lesson id is what closes the loop: the next
  # occurrence counts as a hit against this lesson instead of drafting a new one.
  _id="$_draft"
  _draft_file="$(lessons_volatile_dir)/drafts/$_draft.md"
  if [ -z "$_signature" ] && [ -f "$_draft_file" ]; then
    _signature="$(sed -n 's/^- signature: //p' "$_draft_file" | head -n 1)"
  fi
  # Writing the lesson down must not reset the ladder: the occurrences already
  # counted before anyone noticed still count toward promotion.
  if [ -z "$_occurrences" ]; then
    _occurrences="$(lessons_failure_count "$_draft")"
  fi
fi

_seed=0
case "$_occurrences" in
  ''|*[!0-9]*) _seed=0 ;;
  *) [ "$_occurrences" -gt 1 ] && _seed=$((_occurrences - 1)) ;;
esac

case "$_op" in
  upsert)
    [ -n "$_rule" ] || { printf 'lessons-append.sh: --rule is required\n' >&2; exit 1; }
    if [ -z "$_id" ]; then
      # Identity is derived from the most stable thing available: the failure
      # signature if we have one, else the trigger, else the rule text itself.
      _idseed="${_signature:-${_trigger:-$_rule}}"
      _id="$(lessons_fingerprint "$_idseed")"
    fi
    ;;
  hit|retire)
    [ -n "$_id" ] || { printf 'lessons-append.sh: %s needs an id\n' "$_op" >&2; exit 1; }
    ;;
  promote)
    [ -n "$_id" ] || { printf 'lessons-append.sh: promote needs an id\n' >&2; exit 1; }
    # Promotion is the enforcement mechanism of the whole ladder: it is what
    # satisfies check-lessons.sh and what stops a lesson being injected. Without
    # --guard it asserts that a constraint moved into the repo without saying
    # where, which is indistinguishable from silencing an inconvenient lesson --
    # and docs/lessons/README.md already documents promoted_to as required here.
    [ -n "$_guard" ] || {
      printf 'lessons-append.sh: promote needs --guard <path> -- the hook case,\n' >&2
      printf '  check, test or CI job that now enforces this lesson. If nothing\n' >&2
      printf '  does, the lesson has not graduated; --retire it instead.\n' >&2
      exit 1
    }
    # And it has to point at something that exists. A promotion recorded against
    # a path that was never written, or was deleted in a later refactor, silently
    # un-enforces its lesson while still satisfying the gate -- the same failure
    # as no guard at all, only harder to notice. RALPH_LESSONS_SKIP_GUARD_CHECK=1
    # is the escape hatch for a guard that genuinely lives outside this repo
    # (a CI job defined elsewhere, say).
    if [ -z "${RALPH_LESSONS_SKIP_GUARD_CHECK:-}" ] && [ ! -e "$_guard" ]; then
      printf 'lessons-append.sh: --guard path does not exist: %s\n' "$_guard" >&2
      printf '  Point it at the hook, check, test or CI file that now enforces\n' >&2
      printf '  this lesson. Set RALPH_LESSONS_SKIP_GUARD_CHECK=1 if the guard\n' >&2
      printf '  genuinely lives outside this repository.\n' >&2
      exit 1
    fi
    ;;
  amend)
    # Amend exists so that improving a lesson's wording is free. Restating it
    # as an upsert was the only way to edit one, and an upsert counts as an
    # occurrence -- so sharpening a rule pushed it up the promotion ladder and
    # could trip check-lessons.sh with no failure having actually recurred.
    # The ladder must count occurrences, not edits.
    [ -n "$_id" ] || { printf 'lessons-append.sh: amend needs an id\n' >&2; exit 1; }
    if [ -z "$_rule$_symptom$_cause$_trigger$_scope$_phase$_slug$_evidence$_reason" ] \
       && [ "$_severity_explicit" -eq 0 ]; then
      printf 'lessons-append.sh: amend needs at least one field to change\n' >&2
      exit 1
    fi
    ;;
esac

case "$_severity" in
  low|medium|high|critical) ;;
  *) printf 'lessons-append.sh: --severity must be low|medium|high|critical\n' >&2; exit 1 ;;
esac

_store="$(lessons_store)"
mkdir -p "$_store"
_file="$(lessons_file)"

# Build the scope array literal from a comma-separated list.
_scope_json="[]"
if [ -n "$_scope" ]; then
  _scope_json="$(printf '%s' "$_scope" | awk -F, '{
    out="[";
    for (i=1; i<=NF; i++) {
      gsub(/^[ \t]+|[ \t]+$/, "", $i);
      if ($i == "") continue;
      gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i);
      out = out (i>1 && length(out)>1 ? "," : "") "\"" $i "\"";
    }
    print out "]";
  }')"
fi

esc() { lessons_json_escape "$1"; }

_line="$(
  printf '{"schema":1'
  printf ',"ts":"%s"' "$(lessons_ts)"
  printf ',"id":"%s"' "$_id"
  printf ',"op":"%s"' "$_op"
  [ -n "$_rule" ]      && printf ',"rule":"%s"' "$(esc "$_rule")"
  [ -n "$_symptom" ]   && printf ',"symptom":"%s"' "$(esc "$_symptom")"
  [ -n "$_cause" ]     && printf ',"cause":"%s"' "$(esc "$_cause")"
  [ -n "$_signature" ] && printf ',"signature":"%s"' "$(esc "$(lessons_normalize "$_signature")")"
  [ -n "$_trigger" ]   && printf ',"trigger_command":"%s"' "$(esc "$_trigger")"
  [ "$_scope_json" != "[]" ] && printf ',"scope_paths":%s' "$_scope_json"
  [ -n "$_phase" ]     && printf ',"phase":"%s"' "$_phase"
  [ -n "$_slug" ]      && printf ',"slug":"%s"' "$(esc "$_slug")"
  [ -n "$_evidence" ]  && printf ',"evidence":"%s"' "$(esc "$_evidence")"
  [ -n "$_guard" ]     && printf ',"promoted_to":"%s"' "$(esc "$_guard")"
  [ -n "$_reason" ]    && printf ',"reason":"%s"' "$(esc "$_reason")"
  [ "$_seed" -gt 0 ]   && printf ',"seed_hits":%s' "$_seed"
  # A hit/promote/retire record must not silently restate severity: the fold
  # takes the newest value per field, so a default here would quietly demote a
  # critical lesson to medium.
  if [ "$_op" = "upsert" ] || [ "$_severity_explicit" -eq 1 ]; then
    printf ',"severity":"%s"' "$_severity"
  fi
  printf '}'
)"

# Append-time integrity check. The store is append-only and hand-editing it is
# forbidden, so a malformed line is not a small problem: every reader folds the
# whole log with `jq -s`, and the fold is wired into run-verify.sh, so one bad
# record fails verification for the entire repo until someone breaks the
# no-hand-edit rule to remove it. Refusing to write is the only recovery that
# stays inside the rules.
#
# Cheap enough to be unconditional: one jq parse of one line.
if lessons_have_jq; then
  if ! printf '%s\n' "$_line" | jq -e . >/dev/null 2>&1; then
    printf 'lessons-append.sh: refusing to append a record that is not valid JSON.\n' >&2
    printf '  This is a bug in the escaping, not in your input. Nothing was written.\n' >&2
    printf '  Record: %s\n' "$_line" >&2
    exit 1
  fi
fi

printf '%s\n' "$_line" >> "$_file"

# Keep ACTIVE.md in step with the log. It is not decoration: lessons-recall.sh
# falls back to reading it verbatim when jq is missing, so a stale ACTIVE.md is
# a stale memory for exactly the sessions least equipped to notice. Rendering
# here, and not only in lessons-gc.sh, closes the window in which any append --
# including the unattended --hit from failure_fingerprint.sh -- leaves the two
# disagreeing. RALPH_LESSONS_NO_RENDER=1 opts out for bulk callers that render
# once at the end themselves.
if [ -z "${RALPH_LESSONS_NO_RENDER:-}" ] && [ -x "$_here/lessons-recall.sh" ]; then
  "$_here/lessons-recall.sh" --store "$(dirname "$_file")" \
    --render --max 40 --budget 100000 >/dev/null 2>&1 || true
fi

# The draft has become a lesson; it has no further job.
if [ -n "$_draft" ]; then
  rm -f "$(lessons_volatile_dir)/drafts/$_draft.md" 2>/dev/null || true
fi

printf '%s\n' "$_id"
