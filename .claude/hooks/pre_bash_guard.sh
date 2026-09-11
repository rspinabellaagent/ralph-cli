#!/usr/bin/env sh
set -eu

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$HOOK_DIR/lib_json.sh"

payload="$(cat | tr '\n' ' ')"
# Real Claude Code PreToolUse payloads nest the Bash tool's argument under
# .tool_input.command, not a top-level .command. On the jq path,
# extract_json_field's dotted-path support (lib_json.sh) resolves this
# directly. The sed fallback (jq absent) matches the leaf key name
# ("command") anywhere in the payload regardless of nesting, so it already
# handled both shapes and needs no change — this fix only affects the jq
# path, which previously read the top-level (nonexistent) key and always
# got empty, silently disabling every deny/ask rule below.
command="$(extract_json_field "$payload" "tool_input.command")"

emit_decision() {
  decision="$1"
  reason="$2"
  escaped="$(printf '%s' "$reason" | sed 's/"/\\\"/g')"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$decision" "$escaped"
  exit 0
}

case "$command" in
  *"sudo "*)
    emit_decision "deny" "Avoid sudo inside the harness. Use project-local commands or escalate to a human only if truly necessary."
    ;;
  *"git push --force"*|*"git push -f"*)
    emit_decision "deny" "Force push is blocked by the scaffold."
    ;;
  *"git reset --hard"*)
    emit_decision "deny" "Hard reset is blocked by the scaffold."
    ;;
  *".git/"*">"*|*"> .git"*|*"tee .git"*)
    emit_decision "ask" "Direct writes into .git require explicit confirmation."
    ;;
  *".env"*">"*|*"> .env"*|*"tee .env"*)
    emit_decision "ask" "Secret or environment file writes require explicit confirmation."
    ;;
  *"rm -rf "*)
    emit_decision "ask" "Recursive delete requires explicit confirmation."
    ;;
  *"gh pr create"*)
    emit_decision "ask" "Detected gh pr create. Are you invoking it through the /pr skill? /pr enforces the PR template, the pre-checks, and plan archival. Running it directly is discouraged."
    ;;
esac

# Layer: detect command substitution inside double-quoted git commit -m messages
# Prevents shell expansion of backticks or $() that could leak env vars / secrets
case "$command" in
  *"git commit"*"-m "*)
    # Extract the part after -m
    msg_part="${command#*-m }"
    # Check if message uses double quotes containing backticks or $(...)
    case "$msg_part" in
      '"'*'`'*|'"'*'$('*)
        emit_decision "deny" "Detected a backtick or \$() inside a double-quoted commit message. The shell would interpret it as command substitution, which can leak environment variables or secrets into the commit. Use single quotes or a HEREDOC (<<'EOF') instead."
        ;;
    esac
    ;;
esac

exit 0
