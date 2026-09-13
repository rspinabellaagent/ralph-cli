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

# --- advisory checks: warn, never ask ---
#
# This hook never emits permissionDecision "ask". A hook "ask" forces an
# interactive permission prompt even when the operator's settings allow Bash,
# which stalls unattended runs and trains people to click "Yes" without
# reading. Everything that must actually stop a command (sudo, force push,
# reset --hard, unsafe commit quoting) is a deny above, and runs before these
# advisories so a warning can never mask a deny. The rest attach a warning to
# the call via additionalContext and let it run.
#
# .git and .env are decided on the actual write targets (the words after >, >>,
# and tee), not on substrings of the whole command line. The previous globs
# *".env"*">"* and *"> .git"* matched "os.environ ... 2>&1" and
# "echo x >> .gitignore".
#
# write_targets prints one target per line. Quotes are stripped first so
# "> '.env'" still resolves to .env; fd duplication (2>&1, >&2) is not a target.
write_targets() {
  printf '%s\n' "$1" | tr -d "\"'" | awk '
    {
      s = $0
      while (match(s, />>?[ \t]*[^ \t&|;<>()]+/)) {
        t = substr(s, RSTART, RLENGTH)
        sub(/^>>?[ \t]*/, "", t)
        print t
        s = substr(s, RSTART + RLENGTH)
      }
      line = $0
      gsub(/[|;&()]/, " & ", line)
      n = split(line, w, /[ \t]+/)
      in_tee = 0
      for (i = 1; i <= n; i++) {
        if (w[i] ~ /^[|;&()]$/) { in_tee = 0; continue }
        if (w[i] == "tee" || w[i] ~ /\/tee$/) { in_tee = 1; continue }
        if (in_tee && w[i] != "" && w[i] !~ /^-/) print w[i]
      }
    }'
}

warnings=""
add_warning() {
  warnings="${warnings}${warnings:+ }$1"
}

git_warned=0
env_warned=0
# An advisory must never break the hook: without awk, skip target detection.
targets="$(write_targets "$command" 2>/dev/null || true)"
if [ -n "$targets" ]; then
  while IFS= read -r target; do
    case "$target" in
      .git|.git/*|*/.git|*/.git/*)
        if [ "$git_warned" -eq 0 ]; then
          add_warning "This command writes directly into .git ($target); make sure that is intended."
          git_warned=1
        fi
        ;;
    esac
    case "${target##*/}" in
      .env.example|.env.sample|.env.template) ;;
      .env|.env.*|*.env)
        if [ "$env_warned" -eq 0 ]; then
          add_warning "This command writes a secret/environment file ($target); never place real credentials anywhere they can be committed or logged."
          env_warned=1
        fi
        ;;
    esac
  done <<EOF
$targets
EOF
fi

case "$command" in
  *"rm -rf "*)
    add_warning "This command recursively deletes (rm -rf); double-check every target path."
    ;;
esac

case "$command" in
  *"gh pr create"*)
    add_warning "Detected gh pr create. Prefer the /pr skill: it enforces the PR template, the pre-checks, and plan archival."
    ;;
esac

if [ -n "$warnings" ]; then
  escaped="$(printf '%s' "$warnings" | sed 's/"/\\\"/g')"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$escaped"
fi

exit 0
