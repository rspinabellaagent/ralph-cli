#!/usr/bin/env bash
# test-pre-bash-guard.sh — smoke tests for .claude/hooks/pre_bash_guard.sh
# against the real PreToolUse payload shape.
#
# Regression guard for tech-debt row 100 (docs/tech-debt/README.md): the jq
# path used to call extract_json_field "$payload" "command" (top-level),
# but real Claude Code PreToolUse payloads nest the Bash command under
# .tool_input.command, so every deny/ask rule silently never matched when
# jq was present. The guard only worked via the sed fallback, which matches
# the leaf key anywhere in the payload regardless of nesting.
#
# Cases, each run on BOTH the jq path and the jq-absent (sed fallback) path
# using the same real-shape fixture:
#   A. Denied command (git push --force) nested under tool_input.command
#      -> permissionDecision: deny
#   B. Benign command nested under tool_input.command -> no decision (allow)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/pre_bash_guard.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

pass=0
fail=0
results=()

record_pass() {
  results+=("PASS  $1")
  pass=$((pass + 1))
}
record_fail() {
  results+=("FAIL  $1")
  fail=$((fail + 1))
}

# make_payload <command> — real-shape PreToolUse payload: the Bash tool's
# command argument nested under .tool_input.command, matching what Claude
# Code actually sends (not a flat top-level .command).
make_payload() {
  local command="$1"
  printf '{"session_id":"test","tool_name":"Bash","tool_input":{"command":"%s"}}' "$command"
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/pre-bash-guard-test.XXXXXX")"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

# Minimal PATH without jq, mirroring tests/test-check-mojibake.sh's Case E
# technique: symlink only the tools the hook needs, omitting jq so
# `command -v jq` fails and lib_json.sh falls back to its sed path.
minimal_path="$workdir/no-jq-bin"
mkdir -p "$minimal_path"
for tool in sh bash dash cat grep sed awk printf dirname env tr command test; do
  resolved="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$resolved" ] && ln -sf "$resolved" "$minimal_path/$tool" 2>/dev/null || true
done

run_case() {
  local label="$1" command="$2" expect_deny="$3" use_path="$4"
  local out
  out="$(make_payload "$command" | PATH="$use_path" "$HOOK" 2>/dev/null)"
  local saw_deny=no
  case "$out" in
    *'"permissionDecision":"deny"'*) saw_deny=yes ;;
  esac
  if [ "$saw_deny" = "$expect_deny" ]; then
    record_pass "$label"
  else
    record_fail "$label (expected deny=$expect_deny, got deny=$saw_deny, output: $out)"
  fi
}

# run_advisory <label> <command> <expect: deny|warn|silent> <path>
# The guard must never emit permissionDecision "ask": a hook ask forces an
# interactive permission prompt even when settings allow Bash. Advisories are
# additionalContext warnings; any "ask" in the output fails the case outright.
run_advisory() {
  local label="$1" command="$2" expect="$3" use_path="$4"
  local out rc got
  out="$(make_payload "$command" | PATH="$use_path" "$HOOK" 2>/dev/null)"
  rc=$?
  case "$out" in
    *'"permissionDecision":"ask"'*) got=ask ;;
    *'"permissionDecision":"deny"'*) got=deny ;;
    *'"permissionDecision"'*) got=other-decision ;;
    *'"additionalContext"'*) got=warn ;;
    '') got=silent ;;
    *) got=unrecognized ;;
  esac
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then
    record_pass "$label"
  else
    record_fail "$label (expected $expect, got $got, exit $rc, output: $out)"
  fi
}

real_path="$PATH"

# ── A. jq path: denied command, real nested payload -> deny ────────────
run_case "A. jq path: git push --force (nested tool_input.command) denies" \
  "git push --force origin main" yes "$real_path"

# ── B. jq path: benign command, real nested payload -> allow ───────────
run_case "B. jq path: benign command (nested tool_input.command) allows" \
  "echo hello" no "$real_path"

# ── C. sed fallback path (jq absent): denied command -> deny ───────────
run_case "C. no-jq fallback: git push --force (nested tool_input.command) denies" \
  "git push --force origin main" yes "$minimal_path"

# ── D. sed fallback path (jq absent): benign command -> allow ──────────
run_case "D. no-jq fallback: benign command (nested tool_input.command) allows" \
  "echo hello" no "$minimal_path"

# ── E–K. advisories warn and never ask, on both paths ─────────────────────
for variant in "jq path|$real_path" "no-jq fallback|$minimal_path"; do
  vname="${variant%%|*}"
  vpath="${variant#*|}"
  run_advisory "E. $vname: rm -rf warns without asking" \
    "rm -rf build" warn "$vpath"
  run_advisory "F. $vname: write to .env warns without asking" \
    "echo KEY=x > .env" warn "$vpath"
  run_advisory "G. $vname: tee into .git warns without asking" \
    "printf x | tee -a .git/info/exclude" warn "$vpath"
  run_advisory "H. $vname: gh pr create warns without asking" \
    "gh pr create --fill" warn "$vpath"
  run_advisory "I. $vname: os.environ plus 2>&1 is not an env write" \
    "grep -c os.environ app.py 2>&1" silent "$vpath"
  run_advisory "J. $vname: appending to .gitignore is not a .git write" \
    "echo cache/ >> .gitignore" silent "$vpath"
  run_advisory "K. $vname: a deny still wins over an advisory in the same command" \
    "rm -rf build && git push --force origin main" deny "$vpath"
done

# ── L. no hook in either tree can emit an ask ─────────────────────────────
ask_emitters="$(grep -rnE 'permissionDecision"?[^,}]*"ask"|emit_decision[[:space:]]+"ask"' \
  "$REPO_ROOT/.claude/hooks" "$REPO_ROOT/templates/base/.claude/hooks" 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [ -z "$ask_emitters" ]; then
  record_pass "L. no hook under .claude/hooks or templates/base/.claude/hooks emits permissionDecision ask"
else
  record_fail "L. hooks still emit permissionDecision ask: $ask_emitters"
fi

echo ""
echo "=== test-pre-bash-guard.sh results ==="
for line in "${results[@]}"; do
  echo "  $line"
done
echo ""
echo "  PASS: $pass"
echo "  FAIL: $fail"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
