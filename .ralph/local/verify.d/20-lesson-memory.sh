#!/usr/bin/env sh
# Run the lesson-memory suites as part of verification.
#
# tests/lessons-smoke.sh carries the assertions for the whole layer. Any
# tests/test-lesson-*.sh a project adds alongside it is picked up too -- that is
# where the guards a promoted lesson graduated into belong.
#
# The guards are the reason this wiring exists. Promotion is what takes a lesson
# OUT of the context window: a promoted lesson stops being injected, because the
# constraint is supposed to live in the repo instead. So a guard that silently
# stops working takes its lesson with it, and nothing is left enforcing either --
# the one failure mode the ladder is built to prevent.
#
# A drop-in rather than a line in scripts/run-verify.sh on purpose: a new file
# survives `ralph upgrade` without ejecting run-verify.sh, and
# .github/workflows/verify.yml already runs ./scripts/run-verify.sh, so local
# runs and CI are covered in one place.
set -eu

_root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$_root"

_status=0

# The suites build throwaway repos under $TMPDIR and need jq. Skipping is correct
# when jq is absent -- the layer itself degrades rather than failing in that case
# -- but it has to say so, because a suite that silently does not run is
# indistinguishable from one that passes.
if ! command -v jq >/dev/null 2>&1; then
  printf '[lesson-memory] jq not found; skipping the lesson-memory suites.\n' >&2
else
  for _suite in tests/lessons-smoke.sh tests/test-lesson-*.sh; do
    [ -f "$_suite" ] || continue
    printf '[lesson-memory] %s\n' "$_suite"
    # Execute the file, do not force `sh`. lessons-smoke.sh is bash and uses
    # `set -o pipefail`, which dash rejects outright -- running it under `sh`
    # aborts and reports a failure that is entirely an artifact of the
    # invocation.
    if [ -x "$_suite" ]; then
      _out="$("$_suite" 2>&1)" || _status=1
    else
      _out="$(sh "$_suite" 2>&1)" || _status=1
    fi
    printf '%s\n' "$_out"
    # These suites report per-assertion and summarise at the end; some exit 0
    # even with failures, so the summary is checked as well as the exit code.
    case "$_out" in
      *"FAIL"*|*" failed"*)
        case "$_out" in
          *"0 failed"*) : ;;
          *) _status=1 ;;
        esac
        ;;
    esac
  done
fi

if [ "$_status" -ne 0 ]; then
  printf '[lesson-memory] a lesson-memory suite failed.\n' >&2
fi
exit "$_status"
