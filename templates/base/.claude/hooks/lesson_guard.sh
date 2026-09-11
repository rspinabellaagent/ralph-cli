#!/usr/bin/env sh
# lesson_guard.sh - PreToolUse: put the lesson where the mistake happens.
#
# This is the highest-value injection point in the whole layer. A lesson read at
# session start competes with everything else in context; a lesson delivered at
# the instant the agent is about to run the exact command that failed last time
# cannot be skimmed past. It costs nothing on the (overwhelmingly common) miss:
# no matching trigger, no output.
#
# Severity decides the shape of the intervention:
#   critical  -> permissionDecision "ask": the agent must justify itself first
#   otherwise -> additionalContext: a reminder attached to this one call
#
# Ordering note: this runs after 10-pre-bash-guard.sh, and the dispatcher stops
# at the first decision, so a hard scaffold deny still wins.

set -eu

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
. "$HOOK_DIR/lib_json.sh"
. "$REPO_ROOT/scripts/lessons-common.sh" 2>/dev/null || exit 0

recall="$REPO_ROOT/scripts/lessons-recall.sh"
[ -x "$recall" ] || exit 0

payload="$(cat | tr '\n' ' ')"
command_line="$(extract_json_field "$payload" "tool_input.command")"
[ -n "$command_line" ] || exit 0

# Critical first: if one of these matches, it is the whole response.
critical="$($recall --command "$command_line" --severity-min critical --max 1 --budget 400 2>/dev/null || printf '')"
if [ -n "$critical" ]; then
  reason="This exact command has burned this repo before. $critical Confirm the lesson does not apply before proceeding."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
    "$(lessons_json_escape "$reason")"
  exit 0
fi

out="$($recall --command "$command_line" --max 3 --budget 600 2>/dev/null || printf '')"
[ -n "$out" ] || exit 0

lessons_emit_context "PreToolUse" "Before running this: prior lessons matched this command.
$out"
exit 0
