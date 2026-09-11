#!/usr/bin/env bash
# lessons-gc.sh - Forgetting, on purpose.
#
# A memory that only accumulates degrades into a wall of stale advice that costs
# context on every session and earns nothing. This retires lessons that have
# stopped paying rent, and regenerates the human-readable ACTIVE.md.
#
# Retirement rules (all conservative, none touch a promoted lesson):
#   - active, hits below --keep-hits, and no record newer than --max-age-days
#   - active lessons beyond --cap, lowest-ranked first
#
# Retirement is itself an append (op=retire), so nothing is ever lost: the
# history stays in the log and `--include-promoted` still surfaces it.
#
# It also sweeps volatile failure counters and drafts past --max-age-days. Those
# live in the git common dir so a failure is recognised across sessions and
# worktrees, which also means nothing else ever removes them; and a change to
# what the failure hook fingerprints orphans every existing counter at once.
# They are cheap to rebuild -- the next occurrence starts one -- so this runs
# even when the lesson store is empty or jq is missing.
#
# Usage: lessons-gc.sh [--max-age-days N] [--keep-hits N] [--cap N]
#                      [--store DIR] [--dry-run]
# Exit: 0 always (except setup errors).

set -euo pipefail

_here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lessons-common.sh
. "$_here/lessons-common.sh"
_lib="$(cat "$_here/lessons-fold.jq")"

_max_age="${RALPH_LESSONS_MAX_AGE_DAYS:-90}"
_keep_hits=2
_cap="${RALPH_LESSONS_CAP:-40}"
_dry=0

while [ $# -gt 0 ]; do
  case "$1" in
    --max-age-days) shift; _max_age="${1:-90}" ;;
    --keep-hits)    shift; _keep_hits="${1:-2}" ;;
    --cap)          shift; _cap="${1:-40}" ;;
    --store)        shift; RALPH_LESSONS_STORE="${1:-}"; export RALPH_LESSONS_STORE ;;
    --dry-run)      _dry=1 ;;
    -h|--help)      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'lessons-gc.sh: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift || true
done

# Volatile failure counters and drafts, which nothing collected until now. They
# live in the git common dir on purpose -- that is what lets a failure be
# recognised across sessions and worktrees -- but that also means they outlive
# everything: a counter whose fingerprint no longer corresponds to any lesson,
# or whose failure stopped happening months ago, just accumulates. Worse, a
# change to what the hook fingerprints (as in 758da9f) orphans every existing
# counter at once, leaving in-flight ladders stuck at a count nothing will ever
# advance.
#
# Same age limit as the lessons themselves. Counters are cheap to rebuild -- the
# next occurrence starts one -- so this is safe to be aggressive about.
_vol="$(lessons_volatile_dir)"
_swept=0
for _d in "$_vol/failures" "$_vol/drafts"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    if [ -z "$(find "$_f" -mtime "-$_max_age" 2>/dev/null)" ]; then
      if [ "$_dry" -eq 1 ]; then
        printf '[lessons-gc] would sweep stale volatile file %s\n' "$_f"
      else
        rm -f "$_f" 2>/dev/null || true
      fi
      _swept=$((_swept + 1))
    fi
  done
done
[ "$_swept" -eq 0 ] || [ "$_dry" -eq 1 ] \
  || printf '[lessons-gc] swept %s stale volatile counter/draft file(s).\n' "$_swept"

_file="$(lessons_file)"
[ -s "$_file" ] || exit 0
lessons_have_jq || { printf '[lessons-gc] jq not found; skipped.\n' >&2; exit 0; }

_cutoff="$(date -u -d "-${_max_age} days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -v-"${_max_age}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || printf '')"
[ -n "$_cutoff" ] || { printf '[lessons-gc] cannot compute cutoff date; skipped.\n' >&2; exit 0; }

_stale="$(jq -r -s \
  --arg cutoff "$_cutoff" \
  --argjson keep "$_keep_hits" \
  --argjson cap "$_cap" "$_lib"'
  fold
  | [ .[] | select(.status == "active") ]
  # Same ordering as lessons-recall.sh, and for the same reason: this sort
  # decides what `.[$cap:]` retires. Ascending `.ts` put the oldest first, so
  # the tail -- the part that gets retired -- was the NEWEST among ties, which
  # is the opposite of forgetting.
  | sort_by([ (.severity // "medium" | sevrank), (.hits), (.ts // "") ]) | reverse
  | ( [ .[] | select(.hits < $keep and (.ts // "") < $cutoff) | {id, why: "stale"} ]
      + [ .[$cap:][] | {id, why: "over cap"} ] )
  | unique_by(.id)
  | .[] | "\(.id)\t\(.why)"
' "$_file")"

if [ -z "$_stale" ]; then
  printf '[lessons-gc] nothing to retire.\n'
else
  printf '%s\n' "$_stale" | while IFS="$(printf '\t')" read -r id why; do
    [ -n "$id" ] || continue
    if [ "$_dry" -eq 1 ]; then
      printf '[lessons-gc] would retire %s (%s)\n' "$id" "$why"
    else
      "$_here/lessons-append.sh" --retire "$id" --reason "gc: $why" >/dev/null
      printf '[lessons-gc] retired %s (%s)\n' "$id" "$why"
    fi
  done
fi

[ "$_dry" -eq 1 ] || "$_here/lessons-recall.sh" --render --max 40 --budget 100000 || true
