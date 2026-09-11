#!/usr/bin/env bash
# lessons-recall.sh - Select the few lessons worth spending context on.
#
# This is the half that decides whether the memory works. Injecting the whole
# store on every turn is not memory, it is noise with a token bill: the model
# skims it, and the one line that mattered is buried. Recall is therefore
# always scoped and always budgeted.
#
# Usage:
#   lessons-recall.sh [--command "<pending bash command>"]
#                     [--paths "a/b.go,c/**"]
#                     [--max N] [--budget CHARS] [--exclude-ids FILE]
#
# --exclude-ids FILE  Newline-separated ids to drop, applied BEFORE ranking so an
#                     excluded lesson cannot consume a slot. A missing or empty
#                     file excludes nothing. This is how once-per-session
#                     delivery is enforced without the caller having to
#                     re-implement --max and --budget.
#                     [--min-hits N] [--severity-min low|medium|high|critical]
#                     [--include-promoted] [--format text|json|md]
#                     [--render]            # rewrite docs/lessons/ACTIVE.md
#
# With --command, only lessons whose trigger_command glob matches are returned:
# that is the PreToolUse path, where the reminder lands on the exact keystroke
# that went wrong last time.
# With --paths, lessons are filtered to those scoped to the files in play, plus
# repo-global lessons (empty scope_paths).
#
# Prints nothing and exits 0 when there is nothing worth saying. Hooks depend on
# that: silence is the common case.

set -euo pipefail

_here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lessons-common.sh
. "$_here/lessons-common.sh"
_lib="$(cat "$_here/lessons-fold.jq")"

_command=""
_paths=""
_paths_given=0
_exclude=""
_max=6
_budget=1200
_min_hits=1
_sev_min="low"
_include_promoted=0
_format="text"
_render=0

while [ $# -gt 0 ]; do
  case "$1" in
    --command)           shift; _command="${1:-}" ;;
    --paths)             shift; _paths="${1:-}"; _paths_given=1 ;;
    --max)               shift; _max="${1:-6}" ;;
    --budget)            shift; _budget="${1:-1200}" ;;
    --min-hits)          shift; _min_hits="${1:-1}" ;;
    --severity-min)      shift; _sev_min="${1:-low}" ;;
    --include-promoted)  _include_promoted=1 ;;
    --format)            shift; _format="${1:-text}" ;;
    --exclude-ids)       shift; _exclude="${1:-}" ;;
    --store)             shift; RALPH_LESSONS_STORE="${1:-}"; export RALPH_LESSONS_STORE ;;
    --render)            _render=1; _format="md" ;;
    -h|--help)           awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 1 ;;
    *) printf 'lessons-recall.sh: unknown flag: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift || true
done

_file="$(lessons_file)"
[ -s "$_file" ] || exit 0

if ! lessons_have_jq; then
  # Degraded path: no folding possible without a JSON parser. Fall back to the
  # rendered cache so a jq-less machine still gets its top lessons at session
  # start, and stay silent for the command-scoped path (a wrong match there is
  # worse than no match).
  if [ -z "$_command" ] && [ -f "$(lessons_store)/ACTIVE.md" ]; then
    head -c "$_budget" "$(lessons_store)/ACTIVE.md"
  fi
  exit 0
fi

_exclude_arg="/dev/null"
[ -n "$_exclude" ] && [ -f "$_exclude" ] && _exclude_arg="$_exclude"

_out="$(jq -r -s \
  --arg cmd "$_command" \
  --arg paths "$_paths" \
  --rawfile excluded "$_exclude_arg" \
  --argjson pathsgiven "$_paths_given" \
  --argjson max "$_max" \
  --argjson budget "$_budget" \
  --argjson minhits "$_min_hits" \
  --arg sevmin "$_sev_min" \
  --argjson promoted "$_include_promoted" \
  --arg format "$_format" "$_lib"'

  # Shell globs are what a human writes in a scope field; regex is what jq can
  # match with. ** crosses directory separators, * does not.
  def globesc:
    # The backslash MUST come first. Escaping it last re-escapes the
    # backslashes the earlier rules just inserted: `*a.b*` becomes
    # `.*a\\\\.b.*`, which stops matching `a.b` altogether. Escaping it not at
    # all leaves it live, so a trigger copied from a real command --
    # `*find . -exec rm {} \\;*` -- compiled to a pattern that matched nothing,
    # and a trailing one swallowed the closing anchor.
    #
    # The set below is every Oniguruma metacharacter except `*` and `?`, which
    # are the glob wildcards and are translated afterwards. Derived from the
    # metacharacter set rather than grown one review round at a time -- growing
    # it that way is what left `|`, `{`, `}` out of the first version and `\\`
    # out of the second.
    gsub("\\\\"; "\\\\")
    | gsub("\\."; "\\.") | gsub("\\+"; "\\+") | gsub("\\("; "\\(") | gsub("\\)"; "\\)")
    | gsub("\\["; "\\[") | gsub("\\]"; "\\]") | gsub("\\^"; "\\^") | gsub("\\$"; "\\$")
    | gsub("\\|"; "\\|") | gsub("\\{"; "\\{") | gsub("\\}"; "\\}");
  # Path globs: ** crosses directory separators, * does not. The match below is
  # anchored at both ends. Unanchored, that distinction is not merely weaker but
  # false: the jq test builtin succeeds on any substring, so `pkg/*` compiled to
  # `pkg/[^/]*` matches the prefix `pkg/inner` inside `pkg/inner/deep/file.go`
  # and crosses a directory boundary after all -- the one thing `*` is
  # documented not to do. Found by a mutation that made ** non-recursive and
  # changed no test result.
  def glob2re:
    globesc
    | gsub("\\*\\*"; "@GS@") | gsub("\\*"; "[^/]*") | gsub("@GS@"; ".*")
    | gsub("\\?"; ".");
  # Command globs: a shell command line is not a path, so * spans anything.
  # Anchored at both ends by the caller below, like the path globs -- a glob
  # describes the whole string it is matched against. Write `*rm -rf*` to match
  # anywhere in a command; a bare `rm -rf` unanchored also fired on
  # `echo rm -rf is forbidden`, and for a `critical` lesson that is a spurious
  # permission prompt, which is what got the gh-pr-create rule deleted from
  # pre_bash_guard.sh.
  def cmd2re:
    globesc | gsub("\\*"; ".*") | gsub("\\?"; ".");

  # One rendered line, for whichever format this run asked for. Defined once and
  # called from both the budget reduction and the output, so a change to the
  # printed shape cannot silently invalidate the budget that measured it.
  def render_line:
    if $format == "md" then
      "- **" + .rule + "**"
      + (if (.cause // "") != "" then "  \n  why: " + .cause else "" end)
      + "  \n  `" + .id + "` - hits " + (.hits | tostring) + " - " + (.severity // "medium")
      + status_tag
      + (if (.trigger_command // "") != "" then " - trigger `" + .trigger_command + "`" else "" end)
    else
      "- (x" + (.hits | tostring) + ")" + status_tag + " " + .rule
      + (if (.cause // "") != "" then " - because " + .cause else "" end)
      + " [" + .id + "]"
    end;

  # Fold the append-only log into current state, newest record wins per field.

  ( $paths | split(",") | map(select(length > 0)) ) as $plist
  | fold
  | [ .[] ]
  | map(select(.rule != null and .rule != ""))
  # --include-promoted is the historical view: every state, including retired.
  # FR-7, the lessons-gc.sh header and docs/lessons/README.md all promise that
  # retirement preserves history this flag still surfaces; excluding retired
  # left no supported command that could show it.
  | map(select( if $promoted == 1 then true else .status == "active" end ))
  | map(select(.hits >= $minhits))
  | map(select((.severity // "medium" | sevrank) >= ($sevmin | sevrank)))

  # Command scope: only fire on an actual glob hit against the pending command.
  | (if $cmd == "" then .
     else map(select(.trigger_command != null and .trigger_command != ""
                     and ((.trigger_command | cmd2re) as $re | ($cmd | test("^" + $re + "$"; "i"))))) end)

  # Path scope: repo-global lessons always survive; scoped ones need a hit.
  # A caller that passed no --paths at all wants everything (that is how
  # --render builds ACTIVE.md). A caller that passed --paths with an empty value
  # is saying "nothing is touched", and the honest answer to that is repo-global
  # lessons only. Collapsing the two let a clean SessionStart -- where the hook
  # always passes --paths and the branch touches nothing -- receive every
  # path-scoped lesson in the store, the exact inverse of AC-5.
  | (if $pathsgiven == 0 then .
     else map(select(
       ((.scope_paths // []) | length) == 0
       or ((.scope_paths // []) | any(. as $g | $plist | any(test("^" + ($g | glob2re) + "$")))))) end)

  # Descending on all three keys. `.ts` is a string, so it cannot be negated
  # the way severity and hits are; sorting ascending and reversing gives
  # severity desc, hits desc, newest first -- the documented "severity, then
  # hits, then recency". The previous form negated the first two and left `.ts`
  # ascending, which ranked the OLDEST lesson first among ties.
  # Ids the caller has already delivered this session. Dropped here, before
  # ranking and before the cap, so a lesson the agent has already read cannot
  # consume a slot -- and so the cap and the character budget below still apply
  # to what actually gets emitted. Doing this in the caller instead means the
  # caller has to re-implement the budget, and FR-5 puts the budget in exactly
  # one place on purpose.
  | ( ($excluded | split("\n") | map(select(length > 0))) as $ex
      | if ($ex | length) == 0 then . else map(select(.id as $i | ($ex | index($i)) | not)) end )

  | sort_by([ (.severity // "medium" | sevrank), (.hits), (.ts // "") ]) | reverse
  | .[0:$max]

  # Budget: cumulative character cap, so one verbose lesson cannot crowd out
  # three sharp ones.
  #
  # The cost of a lesson is the length of the line this run will actually print,
  # not an estimate of it. The previous model was rule + cause + 24, and 24 is
  # smaller than the fixed text of every format -- so two lessons could pass a
  # 600-character budget and render as 609. render_line below is the single
  # definition used both here and to produce the output, which is the only way
  # the two cannot drift apart.
  | . as $ranked
  | reduce .[] as $l ({acc: [], used: 0};
      ($l | render_line) as $cost_text
      | ($cost_text | length) as $cost
      | if (.used + $cost) <= $budget
        then {acc: (.acc + [$l]), used: (.used + $cost)}
        else . end)
  | .acc
  # A budget smaller than the top lesson must not silence it entirely -
  # the highest-ranked lesson always survives.
  | (if length == 0 then $ranked[0:1] else . end)
  | if $format == "json" then tojson
    else (map(render_line) | join("\n")) end
' "$_file")"

if [ "$_render" -eq 1 ]; then
  _store="$(lessons_store)"
  {
    printf '%s\n\n' '# Active lessons'
    printf '%s\n\n' '<!-- generated by scripts/lessons-recall.sh --render; do not edit by hand -->'
    printf '%s\n' "$_out"
  } > "$_store/ACTIVE.md"
  exit 0
fi

[ -n "$_out" ] || exit 0
printf '%s\n' "$_out"
