#!/usr/bin/env sh
# lesson_recall.sh - inject scoped lessons into the agent's context.
#
# Called by the dispatcher for SessionStart and UserPromptSubmit:
#   SessionStart      the repo's standing lessons, plus any scoped to the files
#                     this branch already touches. Budgeted, ranked, capped.
#   UserPromptSubmit  only lessons scoped to files currently modified, only
#                     recurring ones, and only once per session per lesson.
#
# The once-per-session rule matters more than it looks. A reminder repeated
# every turn stops being read by turn three, and it costs tokens each time. Say
# it once, then rely on the PreToolUse guard to catch the actual moment.
#
# Usage: lesson_recall.sh <SessionStart|UserPromptSubmit>

set -eu

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
. "$HOOK_DIR/lib_json.sh"
. "$REPO_ROOT/scripts/lessons-common.sh" 2>/dev/null || exit 0

event="${1:-SessionStart}"
recall="$REPO_ROOT/scripts/lessons-recall.sh"
[ -x "$recall" ] || exit 0

payload="$(cat 2>/dev/null || printf '')"
session_id="$(extract_json_field "$(printf '%s' "$payload" | tr '\n' ' ')" "session_id")"
[ -n "$session_id" ] || session_id="nosession"

# Files in play: what this branch has touched, plus the dirty work tree. Cheap,
# and it is what makes path-scoped lessons fire only where they apply.
paths=""
if command -v git >/dev/null 2>&1; then
  base="$(git merge-base HEAD origin/HEAD 2>/dev/null || git merge-base HEAD main 2>/dev/null || printf '')"
  {
    [ -n "$base" ] && git diff --name-only "$base"...HEAD 2>/dev/null
    # -uall, not the default: git collapses untracked directories to "dir/",
    # which never matches a path glob like "internal/upgrade/**".
    # cut -c4-, not awk $NF: paths can contain spaces.
    git status --porcelain -uall 2>/dev/null | cut -c4- | sed 's/.* -> //'
  } 2>/dev/null | sort -u | head -n 60 > "${TMPDIR:-/tmp}/.ralph-lesson-paths.$$" || true
  paths="$(tr '\n' ',' < "${TMPDIR:-/tmp}/.ralph-lesson-paths.$$" 2>/dev/null || printf '')"
  rm -f "${TMPDIR:-/tmp}/.ralph-lesson-paths.$$"
fi

case "$event" in
  SessionStart)
    out="$($recall --paths "$paths" --max 6 --budget 1200 2>/dev/null || printf '')"
    header="Lessons this repo has already paid for (ids in brackets; /lesson to add, amend, or retire one):"
    ;;
  UserPromptSubmit)
    # Nothing scoped to the current work means nothing to say. Silence is the
    # correct output for most prompts.
    [ -n "$paths" ] || exit 0
    lessons_have_jq || exit 0
    seen_dir="$(lessons_volatile_dir)/injected"
    mkdir -p "$seen_dir" 2>/dev/null || true
    seen_file="$seen_dir/$session_id"
    [ -f "$seen_file" ] || : > "$seen_file"
    # The once-per-session exclusion is handed to lessons-recall.sh, which
    # applies it before ranking -- so a lesson already delivered cannot consume
    # one of the three slots -- and then applies the cap and the character
    # budget to what survives. Capping in this hook instead meant fetching with
    # an effectively unlimited budget and slicing afterwards, which emitted 787
    # characters where FR-5 caps this point at 600.
    json="$($recall --paths "$paths" --min-hits 2 --max 3 --budget 600 \
      --exclude-ids "$seen_file" --format json 2>/dev/null || printf '[]')"
    out="$(printf '%s' "$json" | jq -r '
      map("- (x" + (.hits | tostring) + ") " + .rule
          + (if (.cause // "") != "" then " - because " + .cause else "" end)
          + " [" + .id + "]")
      | join("\n")' 2>/dev/null || printf '')"
    # Mark only what was actually emitted.
    if [ -n "$out" ]; then
      printf '%s' "$json" | jq -r '.[].id' >> "$seen_file" 2>/dev/null || true
    fi
    header="Relevant to the files you are touching:"
    ;;
  *)
    exit 0
    ;;
esac

[ -n "$out" ] || exit 0
lessons_emit_context "$event" "$header
$out"
exit 0
