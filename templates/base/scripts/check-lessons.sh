#!/usr/bin/env bash
# check-lessons.sh - The promotion gate. This is where memory grows teeth.
#
# A lesson written as prose is a reminder the agent may or may not read. A
# lesson compiled into a hook, a verifier check, a lint rule, or a test is a
# constraint it cannot skip. This gate refuses to let a lesson stay prose once
# it has proven it recurs.
#
#   hits 1        nothing. One-off failures are noise.
#   hits 2        lesson recorded, injected at matching scope. Cheap, revocable.
#   hits >= 3     must graduate: --promote it to a deterministic guard, or
#                 --retire it as not actually true. This check fails otherwise.
#
# Wire it into ./scripts/run-verify.sh (or .ralph/local/verify.d/) so a repeat
# offender blocks the pipeline rather than accumulating quietly.
#
# Usage: check-lessons.sh [--threshold N] [--store DIR] [--json]
# Exit: 0 clean, 1 un-promoted repeat offenders found, 2 setup problem.

set -euo pipefail

_here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lessons-common.sh
. "$_here/lessons-common.sh"
_lib="$(cat "$_here/lessons-fold.jq")"

_threshold="${RALPH_LESSONS_PROMOTE_AT:-3}"
_json=0

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold) shift; _threshold="${1:-3}" ;;
    --store)     shift; RALPH_LESSONS_STORE="${1:-}"; export RALPH_LESSONS_STORE ;;
    --json)      _json=1 ;;
    -h|--help)   awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'check-lessons.sh: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift || true
done

_file="$(lessons_file)"
[ -s "$_file" ] || { [ "$_json" -eq 1 ] && printf '[]\n'; exit 0; }

if ! lessons_have_jq; then
  printf '[check-lessons] jq not found; promotion gate skipped.\n' >&2
  exit 0
fi

_offenders="$(jq -r -s --argjson t "$_threshold" --argjson json "$_json" "$_lib"'
  fold
  | [ .[] | select(.status == "active" and .hits >= $t) ]
  | sort_by(-(.hits))
  | if $json == 1 then tojson
    else (map("  \(.id)  hits=\(.hits)  \(.rule)") | join("\n")) end
' "$_file")"

if [ "$_json" -eq 1 ]; then
  printf '%s\n' "$_offenders"
  [ "$_offenders" = "[]" ] && exit 0 || exit 1
fi

if [ -z "$_offenders" ]; then
  printf '[check-lessons] no un-promoted repeat offenders.\n'
  exit 0
fi

cat >&2 <<EOF
[check-lessons] These lessons have recurred $_threshold+ times and are still prose:

$_offenders

Prose is a staging area, not a destination. For each one, do exactly one of:

  1. Compile it into a deterministic guard, then record the graduation:
       .claude/hooks/pre_bash_guard.sh      a command the agent must not run
       .claude/hooks/PostToolUse.d/         a shape edits must satisfy
       ./scripts/run-verify.sh              a check the pipeline runs anyway
       a test, a linter rule, or a CI job   the strongest form
     ./scripts/lessons-append.sh --promote <id> --guard <path>

  2. Decide it is not actually true and drop it:
     ./scripts/lessons-append.sh --retire <id> --reason "..."
EOF
exit 1
