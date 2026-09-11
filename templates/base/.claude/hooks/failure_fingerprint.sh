#!/usr/bin/env sh
# failure_fingerprint.sh - PostToolUseFailure: notice that this already happened.
#
# The shipped post_tool_failure_feedback.sh counts failures per session and says
# "stop repeating the same move" after three of anything. It is content-blind and
# it forgets at session end, which is exactly the amnesia that lets a mistake
# recur for weeks.
#
# This one hashes the *shape* of the failure (paths, numbers, quoted strings and
# hex normalized away) into a fingerprint, and counts that fingerprint in the
# git common dir - shared by every worktree of the repo, surviving every session.
#
# Then:
#   - fingerprint already carries a recorded lesson -> append a hit (this is what
#     drives promotion) and re-state the rule, loudly.
#   - second occurrence, no lesson yet -> write a draft and tell the agent to run
#     /lesson. Drafts are deliberately not written into the committed store: an
#     unreviewed auto-summary of an error message is not a lesson, and a store
#     full of them is worse than no store.

set -eu

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
. "$HOOK_DIR/lib_json.sh"
. "$REPO_ROOT/scripts/lessons-common.sh" 2>/dev/null || exit 0

flat="$(cat | tr '\n' ' ')"
tool="$(extract_json_field "$flat" "tool_name")"
cmd="$(extract_json_field "$flat" "tool_input.command")"
err="$(extract_json_field "$flat" "tool_response.stderr")"
[ -n "$err" ] || err="$(extract_json_field "$flat" "tool_response.error")"
[ -n "$err" ] || err="$(extract_json_field "$flat" "error")"

# The failure signature IS the error text, and nothing else. FR-3: the id is
# derived from "the normalized failure signature", and automatic hit counting is
# "the mechanism that makes the whole thing self-driving".
#
# This used to hash "tool command error" together, which quietly broke the one
# workflow the docs tell people to use: a lesson recorded by hand with
# `lessons-append.sh --signature "<raw error>"` hashed the error alone, so the
# two ids never met and the next occurrence started a fresh counter instead of
# counting toward the recorded lesson. It also made the Codex workaround in
# .codex/README.md -- record by hand, let a later Claude Code session pick it up
# -- simply false.
#
# Two different commands that fail with the same normalized error are the same
# failure shape, which is the whole premise of fingerprinting shape rather than
# text. Tool and command stay available for the draft, as context.
subject="${err:-}"
[ -n "$subject" ] || subject="${tool:-} ${cmd:-}"

# Bail only when there is nothing to fingerprint, and decide that on the
# NORMALIZED subject -- the same string the id is derived from.
#
# The old guard tested the raw subject for a leading space or emptiness. That
# was written when the subject always began with the tool name, so it never
# fired. Once the subject became arbitrary tool output it started rejecting
# every error whose text happens to be indented -- `   Compiling foo v0.1.0` and
# most compiler output -- silently: no counter, no draft, no message, ever.
#
# The complement is just as bad. Whitespace-only stderr passes a raw non-empty
# test but normalizes to "", whose fingerprint is sha256("") = e3b0c44298fc,
# shared by every tool and every command. That mints one universal counter, and
# adopting its draft would create a lesson that claims every whitespace-error
# failure in the repo and climbs the ladder on unrelated ones.
#
# Testing the normalized form answers both: it is non-empty exactly when there
# is a real failure shape to remember.
case "$(lessons_normalize "$subject")" in
  "") exit 0 ;;
esac

fp="$(lessons_fingerprint "$subject")"
# One atomic append, one read back. The previous read-increment-write lost
# updates whenever two sessions or worktrees hit the same failure at once, which
# for a counter whose entire purpose is to be shared across sessions and
# worktrees is the normal case: 50 parallel invocations recorded a count of 1.
count="$(lessons_failure_bump "$fp")"
case "$count" in ''|*[!0-9]*) count=0 ;; esac

lessons_file_path="$(lessons_file)"

# Is this fingerprint a lesson that is still live?
#
# Two steps, cheapest first. The grep is a pre-filter: on the overwhelmingly
# common miss it answers in one pass over a small file and no subprocess runs on
# the failure hot path. It cannot be the whole answer, though, because the log
# is append-only -- a retired lesson keeps every record it ever had, so the grep
# still matches it. Taking the known-lesson path on that made a retired lesson a
# black hole: it absorbed every later occurrence as a hit against a status that
# could never change back, blocked the draft that would have replaced it, and
# reported the placeholder "(lesson <id>)". So on a match, fold and read the
# current status.
#
# If the fold cannot run -- no jq, or a store the readers cannot parse -- fall
# back to treating a grep match as live. That is the behaviour this hook had
# before the fold existed, so it is never worse than the status quo, and it
# keeps a transient store problem from making the hook forget every lesson and
# draft duplicates. Be clear about the cost: on that path a retired lesson does
# still take a hit, which is an unattended write into the committed store.
folded="[]"
lesson_status=""
if [ -f "$lessons_file_path" ] && grep -q "\"id\":\"$fp\"" "$lessons_file_path" 2>/dev/null; then
  lesson_status="active"
  if lessons_have_jq; then
    # Fold the log and look the id up directly. Going through lessons-recall.sh
    # meant asking a ranked, paged, budgeted listing for one exact id: past 200
    # historical lessons the match falls off the end, the status reads empty,
    # and the default below treats a RETIRED lesson as live -- reopening the
    # black hole this branch closed, by a different route. Ranking is for
    # deciding what is worth injecting; it is the wrong tool for a key lookup.
    _st="$(jq -r -s --arg id "$fp" "$(cat "$REPO_ROOT/scripts/lessons-fold.jq")"'
      fold | .[$id].status // ""' "$lessons_file_path" 2>/dev/null || printf '')"
    [ -n "$_st" ] && lesson_status="$_st"
  fi
fi

# Known failure with a live lesson: count the hit and say the rule again.
# A retired lesson is deliberately NOT live -- retiring it was a decision that
# it is not worth carrying, so a recurrence should draft a fresh one rather
# than silently resurrect the old.
if [ "$lesson_status" = "active" ] || [ "$lesson_status" = "promoted" ]; then
  "$REPO_ROOT/scripts/lessons-append.sh" --hit "$fp" >/dev/null 2>&1 || true
  # Report the lesson's own hit count, not the raw counter: they can differ when
  # the lesson was recorded after the first few occurrences, and the lesson's
  # count is the one the promotion gate acts on. Re-fold after the hit so the
  # number shown is the one the gate will act on, not the pre-hit value.
  # Fold once to the record for this id, then read the two fields off it. An
  # earlier version joined them with a NUL and split in the shell -- command
  # substitution discards NUL bytes, so the rule came back empty and the message
  # degraded to the "(lesson <id>)" placeholder with the wrong hit count.
  _rec="$(jq -c -s --arg id "$fp" "$(cat "$REPO_ROOT/scripts/lessons-fold.jq")"'
    fold | (.[$id] // {})' "$lessons_file_path" 2>/dev/null || printf '{}')"
  rule="$(printf '%s' "$_rec" | jq -r '.rule // ""' 2>/dev/null || printf '')"
  hits="$(printf '%s' "$_rec" | jq -r '(.hits // "") | tostring' 2>/dev/null || printf '')"
  [ -n "$rule" ] || rule="(lesson $fp)"
  [ -n "$hits" ] || hits="$count"
  lessons_emit_context "PostToolUseFailure" \
"This failure is already a recorded lesson [$fp], now seen $hits times: $rule
Do not retry the same move. Apply the lesson, or if the lesson is wrong, run /lesson to amend it."
  exit 0
fi

# Second occurrence of an unrecorded failure: draft it, do not commit it.
if [ "$count" -ge 2 ]; then
  drafts="$(lessons_volatile_dir)/drafts"
  mkdir -p "$drafts" 2>/dev/null || true
  if [ ! -f "$drafts/$fp.md" ]; then
    {
      printf '# Draft lesson %s\n\n' "$fp"
      printf -- '- first drafted: %s\n' "$(lessons_ts)"
      printf -- '- occurrences: %s\n' "$count"
      printf -- '- tool: %s\n' "${tool:-unknown}"
      printf -- '- command: %s\n' "${cmd:-n/a}"
      printf -- '- signature: %s\n' "$(lessons_normalize "$subject")"
    } > "$drafts/$fp.md" 2>/dev/null || true
  else
    sed -i.bak "s/^- occurrences: .*/- occurrences: $count/" "$drafts/$fp.md" 2>/dev/null || true
    rm -f "$drafts/$fp.md.bak" 2>/dev/null || true
  fi
  lessons_emit_context "PostToolUseFailure" \
"This is occurrence $count of the same failure shape in this repo (fingerprint $fp), across sessions - not just this one.
Stop retrying. Find the actual cause, then run /lesson to record it so the next session does not rediscover it.
Draft: $drafts/$fp.md"
fi

exit 0
