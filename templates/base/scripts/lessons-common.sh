#!/usr/bin/env sh
# lessons-common.sh - shared helpers for the lesson-memory layer.
#
# Sourced by scripts/lessons-*.sh and .claude/hooks/lesson_*.sh.
# POSIX sh only: hooks run under sh, not bash.

# ─── Paths ─────────────────────────────────────────────────────────────────────
#
# Two stores, deliberately:
#
#   docs/lessons/lessons.jsonl   committed, append-only, travels with the branch
#                                and merges into main. This is the memory.
#   <git-common-dir>/ralph-memory/  volatile per-repo counters shared by every
#                                worktree, never committed. This is the tally.
#
# ralph is worktree-first: every /plan creates a clean-base worktree. Anything
# kept in .harness/state/ is therefore reborn empty on each task. Memory that is
# supposed to outlive a task must live in one of the two places above.

lessons_store() {
  printf '%s' "${RALPH_LESSONS_STORE:-docs/lessons}"
}

lessons_file() {
  printf '%s/lessons.jsonl' "$(lessons_store)"
}

lessons_volatile_dir() {
  if [ -n "${RALPH_LESSONS_VOLATILE:-}" ]; then
    printf '%s' "$RALPH_LESSONS_VOLATILE"
    return 0
  fi
  _common=""
  if command -v git >/dev/null 2>&1; then
    _common="$(git rev-parse --git-common-dir 2>/dev/null || printf '')"
  fi
  if [ -n "$_common" ]; then
    printf '%s/ralph-memory' "$_common"
  else
    printf '%s' '.harness/state/ralph-memory'
  fi
}

lessons_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

lessons_have_jq() {
  command -v jq >/dev/null 2>&1
}

# ─── Fingerprinting ────────────────────────────────────────────────────────────
#
# A fingerprint is what makes "the same mistake" detectable. Raw error text is
# never equal twice (paths, line numbers, timestamps, pids), so it is normalized
# to its shape before hashing: lowercase, digits and hex collapsed, absolute
# paths collapsed, whitespace squeezed, first 240 chars.

lessons_normalize() {
  printf '%s' "$1" \
    | tr 'A-Z' 'a-z' \
    | sed -e 's#/[^ ]*/#/*/#g' \
          -e 's/0x[0-9a-f]\{2,\}/0xH/g' \
          -e 's/[0-9]\{1,\}/N/g' \
          -e "s/'[^']*'/'S'/g" \
          -e 's/"[^"]*"/"S"/g' \
          -e 's/[[:space:]]\{1,\}/ /g' \
          -e 's/^ //' -e 's/ $//' \
    | cut -c1-240
}

lessons_fingerprint() {
  _norm="$(lessons_normalize "$1")"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$_norm" | sha256sum | cut -c1-12
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$_norm" | shasum -a 256 | cut -c1-12
  else
    # No hasher: fall back to a stable-enough cksum of the normalized text.
    printf '%s' "$_norm" | cksum | tr -d ' ' | cut -c1-12
  fi
}

# ─── JSON emit helpers ─────────────────────────────────────────────────────────

lessons_json_escape() {
  # Escapes the full set JSON requires, not just the four that show up in
  # everyday prose. A single unescaped C0 control -- an ANSI colour code pasted
  # out of a terminal into --rule or --signature is the realistic source -- used
  # to be accepted silently by append and then made the whole store unreadable:
  # every reader slurps the log with `jq -s`, so one bad line fails the fold,
  # and the fold is wired into run-verify.sh. That turned an unrelated paste
  # into a repo-wide red verify with no legal way to recover (editing
  # lessons.jsonl by hand is forbidden by .claude/rules/ralph/lessons.md).
  #
  # Done in awk rather than sed because sed cannot portably name the control
  # characters; the table is built from sprintf("%c") so it needs no ord().
  printf '%s' "$1" | awk '
    BEGIN {
      ORS = ""
      for (i = 1; i < 32; i++) ctrl[sprintf("%c", i)] = sprintf("\\u%04x", i)
      ctrl[sprintf("%c", 127)] = "\\u007f"
      ctrl["\t"] = "\\t"
      ctrl["\r"] = "\\r"
      ctrl["\b"] = "\\b"
      ctrl["\f"] = "\\f"
    }
    {
      if (NR > 1) print "\\n"
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c in ctrl) out = out ctrl[c]
        else out = out c
      }
      print out
    }'
}

# Emit a Claude Code / Codex hook context envelope on stdout.
lessons_emit_context() {
  _event="$1"
  _text="$2"
  [ -n "$_text" ] || return 0
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' \
    "$_event" "$(lessons_json_escape "$_text")"
}

# How many times this failure shape has been seen in this clone, across every
# session and worktree. Zero when never seen.
#
# The tally is the SIZE of a file that each occurrence appends one byte to, not
# a number that each occurrence reads, increments and rewrites. Read-modify-write
# loses updates whenever two sessions or two worktrees hit the same failure at
# once -- and this counter exists precisely to be shared across sessions and
# worktrees, so concurrency is its normal operating condition, not an edge case.
# Measured before the change: 50 parallel invocations recorded a count of 1.
#
# A single-byte append under O_APPEND is atomic, so the count cannot be lost and
# no lock is needed. The trade is that the file grows one byte per occurrence,
# which for a counter that graduates at 3 is not a trade at all.
lessons_failure_count() {
  _cf="$(lessons_volatile_dir)/failures/$1.tally"
  [ -f "$_cf" ] || { printf '0'; return 0; }
  _n="$(wc -c < "$_cf" 2>/dev/null || printf '0')"
  _n="$(printf '%s' "$_n" | tr -d ' \t\n')"
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  printf '%s' "$_n"
}

# Record one occurrence and return the new total. Append-only on purpose: see
# lessons_failure_count.
lessons_failure_bump() {
  _bd="$(lessons_volatile_dir)/failures"
  mkdir -p "$_bd" 2>/dev/null || { printf '0'; return 0; }
  printf 'x' >> "$_bd/$1.tally" 2>/dev/null || { printf '0'; return 0; }
  lessons_failure_count "$1"
}
