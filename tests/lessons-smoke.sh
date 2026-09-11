#!/usr/bin/env bash
# lessons-smoke.sh - end-to-end check of the lesson-memory layer.
#
# Builds a throwaway git repo, wires in the scripts and hooks from this
# checkout, and drives the whole loop with synthetic hook payloads: two
# occurrences of one failure, a lesson recorded from the resulting draft,
# automatic hit counting, scoped recall, the PreToolUse guard, the promotion
# gate, gc, and the jq-less fallback.
#
# Usage: ./tests/lessons-smoke.sh
# Exit: 0 all assertions passed, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { # check <desc> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (wanted: $2)" ;; esac
}
check_empty() { # check_empty <desc> <haystack>
  if [ -z "$2" ]; then ok "$1"; else bad "$1 (got output: $2)"; fi
}

# ─── fixture ───────────────────────────────────────────────────────────────────

cd "$WORK" || exit 1
git init -q .
git config user.email smoke@test
git config user.name smoke
mkdir -p scripts .claude/hooks docs/lessons internal/upgrade
cp "$REPO_ROOT"/scripts/lessons-common.sh \
   "$REPO_ROOT"/scripts/lessons-append.sh \
   "$REPO_ROOT"/scripts/lessons-recall.sh \
   "$REPO_ROOT"/scripts/lessons-gc.sh \
   "$REPO_ROOT"/scripts/check-lessons.sh \
   "$REPO_ROOT"/scripts/lessons-fold.jq scripts/
cp "$REPO_ROOT"/.claude/hooks/lesson_recall.sh \
   "$REPO_ROOT"/.claude/hooks/lesson_guard.sh \
   "$REPO_ROOT"/.claude/hooks/failure_fingerprint.sh \
   "$REPO_ROOT"/.claude/hooks/lib_json.sh .claude/hooks/
chmod +x scripts/*.sh .claude/hooks/*.sh
echo seed > README.md
git add -A >/dev/null && git commit -qm init

failure() { # failure <line-number>
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"go test ./internal/upgrade"},"tool_response":{"stderr":"upgrade_test.go:%s: settings merge dropped key permissions.allow"}}' \
    "${2:-sessA}" "$1"
}

printf 'lesson-memory smoke\n\n'

# ─── AC-1 same failure, different sessions, different line numbers ─────────────

out1="$(failure 214 sessA | .claude/hooks/failure_fingerprint.sh)"
check_empty "AC-1a first occurrence is silent" "$out1"
out2="$(failure 377 sessB | .claude/hooks/failure_fingerprint.sh)"
check "AC-1b second occurrence, different session and line, is recognized" "occurrence 2" "$out2"

fp="$(basename "$(ls .git/ralph-memory/drafts/*.md)" .md)"
[ -n "$fp" ] && ok "AC-1c draft written for fingerprint $fp" || bad "AC-1c no draft"

# ─── AC-2 lesson from draft auto-counts later occurrences ─────────────────────

./scripts/lessons-append.sh --from-draft "$fp" \
  --rule "Add every new ralph-owned settings key to .ralph/core/settings.ralph.json" \
  --cause "the 3-way merge treats an unsnapshotted key as user-added and drops it" \
  --scope-paths "internal/upgrade/**" --severity high >/dev/null
[ ! -f ".git/ralph-memory/drafts/$fp.md" ] && ok "AC-2a draft cleared once adopted" || bad "AC-2a draft not cleared"
out3="$(failure 402 sessC | .claude/hooks/failure_fingerprint.sh)"
check "AC-2b third occurrence hits the recorded lesson" "already a recorded lesson" "$out3"
check "AC-2c hit count advanced without a human step" "seen 3 times" "$out3"

# ─── AC-3/AC-4 PreToolUse command scope ───────────────────────────────────────

./scripts/lessons-append.sh --rule "Run ./scripts/run-verify.sh before opening a PR" \
  --trigger-command '*gh pr create*' --severity critical >/dev/null
./scripts/lessons-append.sh --rule "Use git worktree remove, not rm -rf" \
  --trigger-command 'rm -rf*worktree*' --severity medium >/dev/null

miss="$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | .claude/hooks/lesson_guard.sh)"
check_empty "AC-3a non-matching command produces no output" "$miss"
hit="$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf ../wt/task-42-worktree"}}' | .claude/hooks/lesson_guard.sh)"
check "AC-3b matching command gets its lesson" "git worktree remove" "$hit"
askout="$(printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}' | .claude/hooks/lesson_guard.sh)"
check "AC-4 critical lesson converts the call into an ask" '"permissionDecision":"ask"' "$askout"

# ─── AC-5 path scope ──────────────────────────────────────────────────────────

clean="$(./scripts/lessons-recall.sh --paths "README.md")"
case "$clean" in *"settings.ralph.json"*) bad "AC-5 path-scoped lesson leaked on unrelated files" ;; *) ok "AC-5a scoped lesson hidden when its paths are untouched" ;; esac
scoped="$(./scripts/lessons-recall.sh --paths "internal/upgrade/settingsmerge.go")"
check "AC-5b scoped lesson appears when its paths are in play" "settings.ralph.json" "$scoped"

# ─── AC-6 once per session at UserPromptSubmit ────────────────────────────────

echo change > internal/upgrade/settingsmerge.go
first="$(printf '{"session_id":"sessD"}' | .claude/hooks/lesson_recall.sh UserPromptSubmit)"
check "AC-6a first prompt of a session speaks" "settings.ralph.json" "$first"
second="$(printf '{"session_id":"sessD"}' | .claude/hooks/lesson_recall.sh UserPromptSubmit)"
check_empty "AC-6b same session does not repeat itself" "$second"
third="$(printf '{"session_id":"sessE"}' | .claude/hooks/lesson_recall.sh UserPromptSubmit)"
check "AC-6c a new session hears it again" "settings.ralph.json" "$third"

start="$(printf '{"session_id":"sessD"}' | .claude/hooks/lesson_recall.sh SessionStart)"
check "AC-6d SessionStart injects scoped lessons" "already paid for" "$start"

# ─── AC-7/AC-8 promotion gate ─────────────────────────────────────────────────

./scripts/check-lessons.sh >/dev/null 2>&1
[ $? -ne 0 ] && ok "AC-7a gate fails on an active lesson with 3+ hits" || bad "AC-7a gate did not fail"
# The guard has to exist: lessons-append.sh refuses a promotion that points at
# a path that was never written, because a promotion with nowhere to point
# satisfies the gate while enforcing nothing.
touch internal/upgrade/settingsmerge_test.go
./scripts/lessons-append.sh --promote "$fp" --guard "internal/upgrade/settingsmerge_test.go" >/dev/null
./scripts/check-lessons.sh >/dev/null 2>&1
[ $? -eq 0 ] && ok "AC-7b gate passes once promoted" || bad "AC-7b gate still failing after promotion"
after="$(./scripts/lessons-recall.sh --paths "internal/upgrade/settingsmerge.go")"
case "$after" in *"settings.ralph.json"*) bad "AC-8 promoted lesson still costs injection budget" ;; *) ok "AC-8 promoted lesson stops being injected" ;; esac

# ─── AC-9 gc keeps history ────────────────────────────────────────────────────

# timestamps have 1-second resolution; a cutoff of "now" must be strictly later
sleep 1
./scripts/lessons-gc.sh --max-age-days 0 --keep-hits 2 >/dev/null
live="$(./scripts/lessons-recall.sh)"
check_empty "AC-9a stale low-hit lessons retired" "$live"
hist="$(./scripts/lessons-recall.sh --include-promoted --max 20)"
check "AC-9b history survives retirement" "settings.ralph.json" "$hist"

# ─── AC-10 jq-less degradation ────────────────────────────────────────────────

fakebin="$WORK/nojq"
mkdir -p "$fakebin"
for c in git date sed awk grep cat cut sort head tail tr printf sh bash mktemp basename dirname rm mkdir sha256sum cksum; do
  src="$(command -v "$c" 2>/dev/null)" && ln -sf "$src" "$fakebin/$c"
done
nojq_recall="$(PATH="$fakebin" ./scripts/lessons-recall.sh 2>&1)"
nojq_hook="$(printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create"}}' | PATH="$fakebin" .claude/hooks/lesson_guard.sh 2>&1)"
nojq_fail="$(failure 500 sessF | PATH="$fakebin" .claude/hooks/failure_fingerprint.sh 2>&1)"
case "$nojq_recall$nojq_hook" in
  *"not found"*|*"error"*|*"Error"*) bad "AC-10 hooks errored without jq" ;;
  *) ok "AC-10a recall and guard degrade quietly without jq" ;;
esac
case "$nojq_fail" in
  *"not found"*) bad "AC-10 failure hook errored without jq" ;;
  *) ok "AC-10b failure hook survives without jq" ;;
esac

# ─── regressions found by self-review of the install ──────────────────────────

# A single C0 control character in any prose field used to be accepted silently
# and then made the whole store unreadable: every reader slurps the log with
# `jq -s`, so one bad line fails the fold, and the fold is wired into
# run-verify.sh. An ANSI colour code pasted out of a terminal was enough.
ctl_store="$WORK/ctl"
mkdir -p "$ctl_store"
./scripts/lessons-append.sh --store "$ctl_store" \
  --rule "$(printf 'never do \033[31mthis\033[0m again')" >/dev/null 2>&1
ctl_rc=0
./scripts/check-lessons.sh --store "$ctl_store" >/dev/null 2>&1 || ctl_rc=$?
./scripts/lessons-recall.sh --store "$ctl_store" >/dev/null 2>&1 || ctl_rc=$((ctl_rc + 10))
if [ "$ctl_rc" -eq 0 ]; then
  ok "control characters in a rule do not corrupt the store"
else
  bad "control characters broke a reader (rc=$ctl_rc)"
fi
check "control characters round-trip losslessly" "$(printf '\033')[31m" \
  "$(jq -r '.rule' "$ctl_store/lessons.jsonl")"

# Escaping is not trusted: the composed line is parsed before it is written, so
# a future escaping bug refuses to append rather than bricking the store. Tested
# by breaking the escaper in this fixture's copy of the script -- an assertion
# that only ever sees correct escaping cannot tell the check exists.
cp scripts/lessons-common.sh "$WORK/common.orig"
sed -i 's|else if (c == "\\"") out = out "\\\\\\""|else if (0) out = out ""|' scripts/lessons-common.sh
if grep -q 'else if (0)' scripts/lessons-common.sh; then
  refuse_store="$WORK/refuse"
  mkdir -p "$refuse_store"
  refuse_out="$(./scripts/lessons-append.sh --store "$refuse_store" --rule 'a "quoted" rule' 2>&1)"
  refuse_rc=$?
  refuse_lines="$( { wc -l < "$refuse_store/lessons.jsonl"; } 2>/dev/null || echo 0)"
  if [ "$refuse_rc" -ne 0 ] && [ "$refuse_lines" -eq 0 ]; then
    ok "a record that would not parse is refused, not written"
  else
    bad "malformed record was written (rc=$refuse_rc, lines=$refuse_lines): $refuse_out"
  fi
else
  bad "could not break the escaper -- this assertion proves nothing as written"
fi
cp "$WORK/common.orig" scripts/lessons-common.sh

# Amending a lesson's wording must not walk it up the promotion ladder: the
# ladder counts occurrences of a failure, not edits to the prose.
am_store="$WORK/amend"
mkdir -p "$am_store"
am_id="$(./scripts/lessons-append.sh --store "$am_store" --rule "original wording" --occurrences 2)"
./scripts/lessons-append.sh --store "$am_store" --amend "$am_id" --rule "sharpened wording" >/dev/null
am_after="$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | .[] | "\(.hits)|\(.status)|\(.rule)"' "$am_store/lessons.jsonl" | tr -d '"')"
check "--amend rewrites the rule" "sharpened wording" "$am_after"
check "--amend does not count as an occurrence" "2|active" "$am_after"
./scripts/lessons-append.sh --store "$am_store" --hit "$am_id" >/dev/null
check "--hit still counts" "3|active" \
  "$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | .[] | "\(.hits)|\(.status)"' "$am_store/lessons.jsonl" | tr -d '"')"

# Every append leaves ACTIVE.md in step. It is the jq-less recall fallback, so a
# stale one is a stale memory for exactly the sessions least able to notice.
check "an append re-renders ACTIVE.md" "sharpened wording" "$(cat "$am_store/ACTIVE.md" 2>/dev/null)"

# The guard behind lesson 7d599d85fb14, which is recorded as promoted to
# scripts/run-verify.sh. A promoted lesson stops being injected, so the claim
# that the repo now enforces it has to be true: the gate must sit inside the
# `{ ... } 2>&1 | tee "$evidence_file"` block. Outside it, a gate failure exits
# non-zero while the evidence log ends with "All verifiers passed".
rv="$REPO_ROOT/scripts/run-verify.sh"
# Comment lines are stripped by matching the code shape, not the word: the
# comment above the gate names both `check-lessons.sh` and `tee
# "$evidence_file"`, so a naive grep matches the prose and compares the wrong
# two line numbers -- which is a dead assertion that passes either way.
gate_ln="$(grep -n '^[^#]*\./scripts/check-lessons\.sh' "$rv" | head -1 | cut -d: -f1)"
tee_ln="$(grep -n '^} 2>&1 | tee "\$evidence_file"' "$rv" | head -1 | cut -d: -f1)"
if [ -n "$gate_ln" ] && [ -n "$tee_ln" ] && [ "$gate_ln" -lt "$tee_ln" ]; then
  ok "the promotion gate runs inside run-verify's evidence block"
else
  bad "gate at line ${gate_ln:-none}, tee at ${tee_ln:-none} - gate output would be absent from docs/evidence/"
fi

# ─── gaps found by mutation testing during /test ──────────────────────────────
#
# Each of the four blocks below was a surviving mutation: the code could be
# removed or inverted and the suite still reported 30 passed, 0 failed. An
# assertion that cannot go red is not coverage, it is decoration -- see lesson
# 42475016fe97.

# 1. The RALPH_LESSONS_NO_RENDER opt-out. Bulk callers (lessons-gc.sh retiring a
#    batch) set it and render once at the end; if it stopped being honoured the
#    only symptom would be wasted work, which nothing would notice.
opt_store="$WORK/optout"
mkdir -p "$opt_store"
./scripts/lessons-append.sh --store "$opt_store" --rule "rendered lesson" >/dev/null
RALPH_LESSONS_NO_RENDER=1 ./scripts/lessons-append.sh --store "$opt_store" --rule "suppressed lesson" >/dev/null
opt_active="$(cat "$opt_store/ACTIVE.md" 2>/dev/null)"
check "the first append rendered ACTIVE.md" "rendered lesson" "$opt_active"
case "$opt_active" in
  *"suppressed lesson"*) bad "RALPH_LESSONS_NO_RENDER=1 did not suppress the re-render" ;;
  *) ok "RALPH_LESSONS_NO_RENDER=1 suppresses the re-render" ;;
esac

# 2. lessons-gc.sh's over-cap arm. Only the stale arm (age + hits) was covered,
#    so the cap could be deleted outright without the suite noticing.
cap_store="$WORK/cap"
mkdir -p "$cap_store"
for word in alpha beta gamma; do
  ./scripts/lessons-append.sh --store "$cap_store" --rule "cap probe $word lesson" \
    --occurrences 2 --severity low >/dev/null
done
cap_before="$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | map(select(.status == "active")) | length' "$cap_store/lessons.jsonl")"
check "three distinct lessons before the cap runs" "3" "$cap_before"
cap_dry="$(./scripts/lessons-gc.sh --store "$cap_store" --cap 1 --dry-run)"
check "--dry-run reports the over-cap retirements" "would retire" "$cap_dry"
cap_dry_after="$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | map(select(.status == "active")) | length' "$cap_store/lessons.jsonl")"
check "--dry-run retires nothing" "3" "$cap_dry_after"
./scripts/lessons-gc.sh --store "$cap_store" --cap 1 >/dev/null
cap_after="$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | map(select(.status == "active")) | length' "$cap_store/lessons.jsonl")"
check "over-cap lessons are retired down to the cap" "1" "$cap_after"
cap_total="$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | length' "$cap_store/lessons.jsonl")"
check "over-cap retirement loses no history" "3" "$cap_total"

# 3. `**` must cross a directory boundary and `*` must not. The existing fixture
#    never nests, so the two globs were indistinguishable to the suite.
glob_store="$WORK/glob"
mkdir -p "$glob_store"
./scripts/lessons-append.sh --store "$glob_store" --rule "recursive glob lesson" \
  --scope-paths "pkg/**" --occurrences 2 >/dev/null
./scripts/lessons-append.sh --store "$glob_store" --rule "flat glob lesson" \
  --scope-paths "pkg/*.go" --occurrences 2 >/dev/null
deep="$(./scripts/lessons-recall.sh --store "$glob_store" --paths "pkg/inner/deep/file.go")"
check "** matches across directory boundaries" "recursive glob lesson" "$deep"
case "$deep" in
  *"flat glob lesson"*) bad "pkg/*.go wrongly matched pkg/inner/deep/file.go" ;;
  *) ok "* does not match across a directory boundary" ;;
esac
flat="$(./scripts/lessons-recall.sh --store "$glob_store" --paths "pkg/top.go")"
check "* matches within its own directory" "flat glob lesson" "$flat"
# The match is anchored at both ends. Unanchored it succeeds on any substring,
# so `pkg/**` would also claim a vendored copy of the same tree -- a scope that
# silently widens is worse than no scope, because the lesson still looks scoped.
nested="$(./scripts/lessons-recall.sh --store "$glob_store" --paths "vendor/pkg/inner.go")"
case "$nested" in
  *"recursive glob lesson"*) bad "pkg/** matched vendor/pkg/inner.go - the glob is not anchored" ;;
  *) ok "a scope glob does not match the same tree nested elsewhere" ;;
esac

# 4. The character budget. Every budget the layer actually passes is far larger
#    than a fixture lesson, so the cutoff arithmetic was never executed.
bud_store="$WORK/budget"
mkdir -p "$bud_store"
./scripts/lessons-append.sh --store "$bud_store" --rule "budget probe one, high severity so it ranks first" --severity high --occurrences 2 >/dev/null
./scripts/lessons-append.sh --store "$bud_store" --rule "budget probe two, low severity so it ranks second" --severity low --occurrences 2 >/dev/null
bud_all="$(./scripts/lessons-recall.sh --store "$bud_store" --max 10 --budget 100000)"
check "both lessons fit an unbounded budget" "budget probe two" "$bud_all"
bud_cut="$(./scripts/lessons-recall.sh --store "$bud_store" --max 10 --budget 90)"
check "the top-ranked lesson survives a tight budget" "budget probe one" "$bud_cut"
case "$bud_cut" in
  *"budget probe two"*) bad "--budget 90 did not cut the second lesson" ;;
  *) ok "--budget cuts lessons past the character limit" ;;
esac
bud_tiny="$(./scripts/lessons-recall.sh --store "$bud_store" --max 10 --budget 5)"
if [ -n "$bud_tiny" ]; then
  ok "a budget too small for even one lesson still yields the top-ranked one"
else
  bad "a too-small budget silently returned nothing (FR-5 says the top lesson always survives)"
fi

# ─── contract violations found by /cross-review (codex) ───────────────────────
#
# All five reproduced against the code before being fixed, and none of the 45
# assertions above went red for any of them.

# F1. "severity, then hits, then recency" -- recency means NEWEST first. The old
#     sort negated severity and hits but left .ts ascending, ranking the OLDEST
#     first among ties, which hides a newer lesson behind --max.
ord_store="$WORK/order"
mkdir -p "$ord_store"
./scripts/lessons-append.sh --store "$ord_store" --rule "older tie lesson" --severity medium --occurrences 2 >/dev/null
sleep 1
./scripts/lessons-append.sh --store "$ord_store" --rule "newer tie lesson" --severity medium --occurrences 2 >/dev/null
ord_first="$(./scripts/lessons-recall.sh --store "$ord_store" --max 5 --budget 100000 | head -1)"
check "equal severity and hits rank the newer lesson first" "newer tie lesson" "$ord_first"
#     The same sort decides what lessons-gc.sh's cap retires: the tail must be
#     the OLDER of a tie, not the newer.
./scripts/lessons-gc.sh --store "$ord_store" --cap 1 >/dev/null
ord_kept="$(./scripts/lessons-recall.sh --store "$ord_store" --max 5 --budget 100000)"
check "the cap retires the older of a tie, not the newer" "newer tie lesson" "$ord_kept"
case "$ord_kept" in
  *"older tie lesson"*) bad "the cap kept the older lesson and retired the newer" ;;
  *) ok "the cap retired the older lesson" ;;
esac

# F2. --paths with an empty value means "nothing is touched", not "no filter".
#     Collapsing the two gave a clean SessionStart every path-scoped lesson in
#     the store -- the exact inverse of AC-5.
pf_store="$WORK/pathfilter"
mkdir -p "$pf_store"
./scripts/lessons-append.sh --store "$pf_store" --rule "global reach lesson" --occurrences 2 >/dev/null
./scripts/lessons-append.sh --store "$pf_store" --rule "narrow reach lesson" --scope-paths "internal/**" --occurrences 2 >/dev/null
pf_empty="$(./scripts/lessons-recall.sh --store "$pf_store" --paths "" --max 10 --budget 100000)"
check "an empty --paths still yields repo-global lessons" "global reach lesson" "$pf_empty"
case "$pf_empty" in
  *"narrow reach lesson"*) bad "an empty --paths leaked a path-scoped lesson" ;;
  *) ok "an empty --paths does not leak path-scoped lessons" ;;
esac
pf_none="$(./scripts/lessons-recall.sh --store "$pf_store" --max 10 --budget 100000)"
check "omitting --paths entirely still yields everything (--render relies on it)" "narrow reach lesson" "$pf_none"

# F3. A trigger is a glob for the WHOLE command line, and its metacharacters are
#     literal. Unanchored, a critical `rm -rf` lesson fired on
#     `echo rm -rf is forbidden` -- a spurious permission prompt.
trg_store="$WORK/trigger"
mkdir -p "$trg_store"
./scripts/lessons-append.sh --store "$trg_store" --rule "bare trigger lesson" \
  --trigger-command "rm -rf" --severity critical --occurrences 2 >/dev/null
trg_exact="$(./scripts/lessons-recall.sh --store "$trg_store" --command "rm -rf" --max 5 --budget 100000)"
check "an unglobbed trigger matches the command it names" "bare trigger lesson" "$trg_exact"
trg_mention="$(./scripts/lessons-recall.sh --store "$trg_store" --command "echo rm -rf is forbidden" --max 5 --budget 100000)"
check_empty "an unglobbed trigger does not fire on a command that merely mentions it" "$trg_mention"
./scripts/lessons-append.sh --store "$trg_store" --rule "alternation trigger lesson" \
  --trigger-command "go build|npm ci" --occurrences 2 >/dev/null
trg_alt="$(./scripts/lessons-recall.sh --store "$trg_store" --command "npm ci" --max 5 --budget 100000)"
check_empty "a pipe in a trigger is literal, not regex alternation" "$trg_alt"

# F4. A retired lesson must not absorb later occurrences of its failure. The old
#     raw grep matched its historical records, so it took the known-lesson path
#     forever: hits accrued, status could not change back, the draft path was
#     blocked, and the message degraded to "(lesson <id>)".
rm -rf .git/ralph-memory/failures .git/ralph-memory/drafts
retire_fp="$(./scripts/lessons-recall.sh --include-promoted --max 200 --budget 1000000 --format json \
  | jq -r --arg r "Add every new ralph-owned settings key" '.[] | select(.rule | startswith($r)) | .id')"
if [ -n "$retire_fp" ]; then
  ./scripts/lessons-append.sh --retire "$retire_fp" --reason "smoke: exercising the retired path" >/dev/null
  ret_out1="$(failure 511 sessG | .claude/hooks/failure_fingerprint.sh)"
  ret_out2="$(failure 512 sessH | .claude/hooks/failure_fingerprint.sh)"
  case "$ret_out1$ret_out2" in
    *"already a recorded lesson"*) bad "a retired lesson still absorbed a recurrence as a hit" ;;
    *) ok "a retired lesson does not absorb later occurrences" ;;
  esac
  check "a recurrence after retirement drafts a replacement" "occurrence 2" "$ret_out2"
else
  bad "could not locate the fingerprint lesson to retire"
fi

# F5. --include-promoted is the historical view. FR-7, the lessons-gc.sh header
#     and docs/lessons/README.md all promise it surfaces retired history; it was
#     the one flag that explicitly excluded it, leaving no way to see it.
hist_retired="$(./scripts/lessons-recall.sh --include-promoted --max 200 --budget 1000000)"
check "--include-promoted surfaces retired lessons" "settings.ralph.json" "$hist_retired"
live_only="$(./scripts/lessons-recall.sh --max 200 --budget 1000000)"
case "$live_only" in
  *"settings.ralph.json"*) bad "a retired lesson is still being injected without --include-promoted" ;;
  *) ok "a retired lesson is not injected by default" ;;
esac

# ─── cycle-2 self-review findings ─────────────────────────────────────────────

# A glob must match the literal string it was copied from. Every earlier
# assertion used a backslash-free fixture, so three rounds of adding
# metacharacters to the escaper each looked complete while `\` stayed live: a
# critical lesson triggered on a real `find -exec` command matched nothing at
# all, and a trailing backslash swallowed the closing anchor.
esc_store="$WORK/escape"
mkdir -p "$esc_store"
esc_cmd='find . -exec rm {} \;'
./scripts/lessons-append.sh --store "$esc_store" --rule "backslash trigger lesson" \
  --trigger-command "*${esc_cmd}*" --severity critical --occurrences 2 >/dev/null
esc_hit="$(./scripts/lessons-recall.sh --store "$esc_store" --command "$esc_cmd" --max 5 --budget 100000)"
check "a trigger fires on the exact command it was copied from" "backslash trigger lesson" "$esc_hit"
# Each metacharacter class gets its own fixture, so reverting any single one of
# them is killed by its own assertion rather than by a neighbour's.
# `{a,b}` is not valid repetition syntax, so it stays literal with or without
# escaping -- a fixture using it proves nothing. `{2}` is repetition.
./scripts/lessons-append.sh --store "$esc_store" --rule "brace trigger lesson" \
  --trigger-command '*retry a{2}*' --occurrences 2 >/dev/null
check "braces in a trigger are literal" "brace trigger lesson" \
  "$(./scripts/lessons-recall.sh --store "$esc_store" --command 'retry a{2} now' --max 5 --budget 100000)"
check_empty "braces in a trigger are not a repetition count" \
  "$(./scripts/lessons-recall.sh --store "$esc_store" --command 'retry aa now' --max 5 --budget 100000)"
# Unescaped, `(x)` is a capture group that matches a bare `x`; escaped, it
# demands the literal parentheses. The command without them is what separates
# the two.
./scripts/lessons-append.sh --store "$esc_store" --rule "paren trigger lesson" \
  --trigger-command '*(x)*' --occurrences 2 >/dev/null
check "parentheses in a trigger are literal" "paren trigger lesson" \
  "$(./scripts/lessons-recall.sh --store "$esc_store" --command 'run (x) now' --max 5 --budget 100000)"
check_empty "parentheses in a trigger are not a capture group" \
  "$(./scripts/lessons-recall.sh --store "$esc_store" --command 'run x now' --max 5 --budget 100000)"
# Escaping the backslash LAST re-escapes what the other rules inserted, so `.`
# stops being literal. This catches the wrong order, which the assertion above
# cannot.
./scripts/lessons-append.sh --store "$esc_store" --rule "dot trigger lesson" \
  --trigger-command '*a.b*' --occurrences 2 >/dev/null
check "a dot in a trigger still matches itself" "dot trigger lesson" \
  "$(./scripts/lessons-recall.sh --store "$esc_store" --command 'run a.b now' --max 5 --budget 100000)"
check_empty "a dot in a trigger is not a wildcard" \
  "$(./scripts/lessons-recall.sh --store "$esc_store" --command 'run axb now' --max 5 --budget 100000)"

# A non-active lesson must be marked in every human-facing view. Only
# --include-promoted surfaces one, and that is the command /lesson runs before
# amending -- an unmarked retired lesson reads as live and gets an amendment
# that silently does nothing.
tag_store="$WORK/statustag"
mkdir -p "$tag_store"
tag_id="$(./scripts/lessons-append.sh --store "$tag_store" --rule "status tag lesson" --occurrences 2)"
check_empty "an active lesson carries no status tag" \
  "$(./scripts/lessons-recall.sh --store "$tag_store" --max 5 --budget 100000 | grep -o '\[active\]' || printf '')"
./scripts/lessons-append.sh --store "$tag_store" --retire "$tag_id" --reason "smoke" >/dev/null
check "a retired lesson is marked in the text view" "[retired]" \
  "$(./scripts/lessons-recall.sh --store "$tag_store" --include-promoted --max 5 --budget 100000)"
check "a retired lesson is marked in the md view" "[retired]" \
  "$(./scripts/lessons-recall.sh --store "$tag_store" --include-promoted --format md --max 5 --budget 100000)"

# The grep pre-filter is not only a hot-path saving. It is what lets the hook
# still recognise a lesson when the fold cannot run at all -- without it, a
# store the readers cannot parse makes the hook forget every lesson and draft
# duplicates of failures it already has answers for.
corrupt_repo="$WORK/corruptcheck"
mkdir -p "$corrupt_repo"
cp -r scripts .claude "$corrupt_repo/" 2>/dev/null
mkdir -p "$corrupt_repo/docs/lessons"
( cd "$corrupt_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
# The hook fingerprints the failure signature -- the error text alone -- which
# is exactly what `lessons-append.sh --signature` hashes, so a lesson recorded
# by hand and a later occurrence of that failure meet on the same id. The
# assertion below pins that; it is what caught the change when the hook still
# hashed tool + command + error together.
corrupt_fp="$( cd "$corrupt_repo" && ./scripts/lessons-append.sh \
  --rule "corrupt store probe lesson" --signature "probe failure signature" --occurrences 2 )"
# A line the readers cannot fold. Hand-written on purpose: the append path now
# refuses to produce one, so this is the only way to exercise the fallback.
printf 'this line is not json\n' >> "$corrupt_repo/docs/lessons/lessons.jsonl"
corrupt_out="$( cd "$corrupt_repo" && printf '{"session_id":"sessZ","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stderr":"probe failure signature"}}' \
  | .claude/hooks/failure_fingerprint.sh 2>/dev/null )"
check "an unfoldable store still recognises a known lesson" "already a recorded lesson" "$corrupt_out"
check "the seeded id and the hook fingerprint are the same" "$corrupt_fp" "$corrupt_out"

# ─── cycle-2 /test survivors ──────────────────────────────────────────────────
#
# 21 mutations, 8 survivors. These close five of them; the rest are recorded in
# docs/tech-debt/README.md with why they are not worth an assertion.

# Only the DIRECTION of the recency tie-break was pinned. The precedence itself
# -- severity outranks hits, hits outrank recency -- was not, so swapping the
# first two sort keys changed nothing the suite could see.
prec_store="$WORK/precedence"
mkdir -p "$prec_store"
./scripts/lessons-append.sh --store "$prec_store" --rule "low severity many hits lesson" \
  --severity low --occurrences 9 >/dev/null
./scripts/lessons-append.sh --store "$prec_store" --rule "high severity few hits lesson" \
  --severity high --occurrences 2 >/dev/null
check "severity outranks hits" "high severity few hits lesson" \
  "$(./scripts/lessons-recall.sh --store "$prec_store" --max 5 --budget 100000 | head -1)"
# The same precedence decides which lesson lessons-gc.sh sacrifices to the cap.
./scripts/lessons-gc.sh --store "$prec_store" --cap 1 >/dev/null
gc_kept="$(./scripts/lessons-recall.sh --store "$prec_store" --max 5 --budget 100000)"
check "the cap sacrifices the low-severity lesson, not the high-hit one" "high severity few hits lesson" "$gc_kept"
case "$gc_kept" in
  *"low severity many hits lesson"*) bad "the cap kept the low-severity lesson" ;;
  *) ok "the cap retired the low-severity lesson despite its higher hit count" ;;
esac

# The stale arm is `hits < --keep-hits`, so a lesson sitting exactly ON the floor
# must survive. `<=` would quietly retire the whole floor.
floor_store="$WORK/keepfloor"
mkdir -p "$floor_store"
./scripts/lessons-append.sh --store "$floor_store" --rule "exactly at the keep floor lesson" \
  --occurrences 2 >/dev/null
./scripts/lessons-append.sh --store "$floor_store" --rule "below the keep floor lesson" \
  --occurrences 1 >/dev/null
# The stale arm needs `.ts < cutoff`, strictly. With --max-age-days 0 the cutoff
# is *now*, and a lesson written in this same second is not older than it -- so
# without this sleep the arm never fires and BOTH assertions below pass while
# testing nothing. lessons_ts has one-second resolution.
sleep 1
./scripts/lessons-gc.sh --store "$floor_store" --keep-hits 2 --max-age-days 0 >/dev/null
floor_left="$(./scripts/lessons-recall.sh --store "$floor_store" --max 5 --budget 100000)"
check "a lesson exactly at --keep-hits is not retired as stale" "exactly at the keep floor lesson" "$floor_left"
case "$floor_left" in
  *"below the keep floor lesson"*) bad "a lesson below --keep-hits was not retired as stale" ;;
  *) ok "a lesson below --keep-hits is retired as stale" ;;
esac

# --amend must refuse a call that changes nothing. The validation existed and no
# assertion ever reached it.
amv_store="$WORK/amendvalid"
mkdir -p "$amv_store"
amv_id="$(./scripts/lessons-append.sh --store "$amv_store" --rule "amend validation lesson" --occurrences 2)"
amv_rc=0
./scripts/lessons-append.sh --store "$amv_store" --amend "$amv_id" >/dev/null 2>&1 || amv_rc=$?
if [ "$amv_rc" -ne 0 ]; then ok "--amend with no fields is refused"; else bad "--amend with no fields was accepted"; fi
amv_lines="$(wc -l < "$amv_store/lessons.jsonl")"
check "a refused --amend writes nothing" "1" "$amv_lines"

# --occurrences 0 and 1 are both reachable (--from-draft passes whatever
# lessons_failure_count returns) and must seed no extra hits rather than
# underflowing or aborting under set -e.
occ_store="$WORK/occ"
mkdir -p "$occ_store"
./scripts/lessons-append.sh --store "$occ_store" --rule "zero occurrences lesson" --occurrences 0 >/dev/null 2>&1
./scripts/lessons-append.sh --store "$occ_store" --rule "one occurrence lesson" --occurrences 1 >/dev/null 2>&1
occ_hits="$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | map(.hits) | join(",")' "$occ_store/lessons.jsonl" | tr -d '"')"
# Removing the guard entirely makes --occurrences 0 seed -1, so hits folds to 0
# and the lesson can never reach the promotion ladder. (Changing `-gt 1` to
# `-gt 0` is an equivalent mutation: at 1 the arithmetic yields 0 either way.)
check "--occurrences 0 and 1 both yield exactly one hit" "1,1" "$occ_hits"
occ_min="$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | map(.hits) | min' "$occ_store/lessons.jsonl")"
if [ "$occ_min" -ge 1 ]; then ok "--occurrences 0 cannot underflow the hit count"; else bad "--occurrences 0 produced hits=$occ_min"; fi

# The budget test is `<=`, so a lesson costing exactly the remaining budget must
# be kept; `<` would drop it. This needs TWO lessons: FR-5 guarantees the
# top-ranked one survives any budget at all, so a single-lesson fixture never
# reaches the comparison and cannot tell `<=` from `<`.
#
# cost = rule length + cause length + 24 (lessons-recall.sh). Both rules below
# are the same length, so the exact-fit budget is the sum of the two costs.
bex_store="$WORK/budgetexact"
mkdir -p "$bex_store"
bex_a="budget alpha lesson AA"
bex_b="budget beta lesson BBB"
./scripts/lessons-append.sh --store "$bex_store" --rule "$bex_a" --severity high --occurrences 2 >/dev/null
./scripts/lessons-append.sh --store "$bex_store" --rule "$bex_b" --severity low --occurrences 2 >/dev/null
# Measure the exact fit from the rendered output rather than recomputing the
# cost model here -- a fixture that duplicates the model cannot detect the model
# changing, and it did change: cost is now the length of the rendered line, not
# rule + cause + 24. The budget counts each line, not the newline that join
# inserts between them, so the fit is the total minus (lessons - 1).
bex_full="$(./scripts/lessons-recall.sh --store "$bex_store" --max 5 --budget 100000)"
bex_fit=$(( $(printf '%s' "$bex_full" | wc -c) - 1 ))
check "the second lesson is kept when it costs exactly the remaining budget" "$bex_b" \
  "$(./scripts/lessons-recall.sh --store "$bex_store" --max 5 --budget "$bex_fit")"
case "$(./scripts/lessons-recall.sh --store "$bex_store" --max 5 --budget $((bex_fit - 1)))" in
  *"$bex_b"*) bad "one byte under the exact fit still admitted the second lesson" ;;
  *) ok "one byte under the exact fit drops the second lesson" ;;
esac

# ─── cycle-2 /cross-review findings ───────────────────────────────────────────

# F1. The documented manual-recording workflow must actually link up: a lesson
# recorded with `--signature "<raw error>"` has to be found by the hook the next
# time that error occurs. It did not -- the hook hashed tool+command+error while
# --signature hashes the error alone, so the two ids never met and the promise
# of automatic hit counting (FR-3) was false for every hand-recorded lesson,
# including the whole Codex workaround in .codex/README.md.
sig_repo="$WORK/signature"
mkdir -p "$sig_repo"
cp -r scripts .claude "$sig_repo/" 2>/dev/null
mkdir -p "$sig_repo/docs/lessons"
( cd "$sig_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
sig_err='go: cannot find module providing package foo'
sig_id="$( cd "$sig_repo" && ./scripts/lessons-append.sh \
  --rule "Run go mod tidy before building" --signature "$sig_err" --occurrences 2 )"
sig_out="$( cd "$sig_repo" && printf '{"session_id":"sigA","tool_name":"Bash","tool_input":{"command":"go build ./..."},"tool_response":{"stderr":"%s"}}' "$sig_err" \
  | .claude/hooks/failure_fingerprint.sh )"
check "a hand-recorded --signature lesson is found by the failure hook" "already a recorded lesson" "$sig_out"
check "and it is found by its own id" "$sig_id" "$sig_out"
check "and its rule is reported, not the placeholder" "Run go mod tidy before building" "$sig_out"
check "and the hit lands on the recorded lesson count, not the raw counter" "seen 3 times" "$sig_out"
# The same error from a different command is the same failure shape.
sig_out2="$( cd "$sig_repo" && printf '{"session_id":"sigB","tool_name":"Bash","tool_input":{"command":"go test ./pkg/..."},"tool_response":{"stderr":"%s"}}' "$sig_err" \
  | .claude/hooks/failure_fingerprint.sh )"
check "the same error from a different command counts toward the same lesson" "$sig_id" "$sig_out2"

# F2. Promotion is what satisfies the gate and stops a lesson being injected.
# Without --guard it claims a constraint moved into the repo without saying
# where, which is indistinguishable from silencing an inconvenient lesson.
prm_store="$WORK/promote"
mkdir -p "$prm_store"
prm_id="$(./scripts/lessons-append.sh --store "$prm_store" --rule "promotion guard lesson" --occurrences 3)"
prm_rc=0
./scripts/lessons-append.sh --store "$prm_store" --promote "$prm_id" >/dev/null 2>&1 || prm_rc=$?
if [ "$prm_rc" -ne 0 ]; then ok "--promote without --guard is refused"; else bad "--promote without --guard was accepted"; fi
check "a refused promotion leaves the lesson active" "active" \
  "$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | .[] | .status' "$prm_store/lessons.jsonl" | tr -d '"')"
./scripts/lessons-append.sh --store "$prm_store" --promote "$prm_id" --guard "scripts/check-lessons.sh" >/dev/null
check "--promote with --guard is accepted" "promoted" \
  "$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | .[] | .status' "$prm_store/lessons.jsonl" | tr -d '"')"
check "and the guard path is recorded" "scripts/check-lessons.sh" \
  "$(jq -s "$(cat scripts/lessons-fold.jq)"'fold | .[] | .promoted_to' "$prm_store/lessons.jsonl" | tr -d '"')"

# F3. The once-per-session filter must run BEFORE the per-prompt limit, and the
# limit and the character budget must still apply to what survives it. Both live
# in lessons-recall.sh (--exclude-ids), because FR-5 puts the budget in exactly
# one place and a caller that re-implements the cap loses the budget with it.
#
# Isolated in its own repo: this block deliberately creates lessons at hits 5,
# which would fail check-lessons.sh for every later assertion sharing the store.
rank_repo="$WORK/rank"
mkdir -p "$rank_repo/internal/upgrade"
cp -r scripts .claude "$rank_repo/" 2>/dev/null
mkdir -p "$rank_repo/docs/lessons"
( cd "$rank_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
( cd "$rank_repo" && echo change > internal/upgrade/rank_probe.go )
for w in alpha bravo charlie delta; do
  ( cd "$rank_repo" && ./scripts/lessons-append.sh --rule "prompt budget $w lesson" \
      --severity critical --occurrences 5 >/dev/null )
done
( cd "$rank_repo" && ./scripts/lessons-append.sh --rule "prompt budget echo lesson" \
    --severity low --scope-paths "internal/upgrade/**" --occurrences 2 >/dev/null )
rp1="$( cd "$rank_repo" && printf '{"session_id":"rankP"}' | .claude/hooks/lesson_recall.sh UserPromptSubmit)"
rp2="$( cd "$rank_repo" && printf '{"session_id":"rankP"}' | .claude/hooks/lesson_recall.sh UserPromptSubmit)"
rp3="$( cd "$rank_repo" && printf '{"session_id":"rankP"}' | .claude/hooks/lesson_recall.sh UserPromptSubmit)"
case "$rp1$rp2$rp3" in
  *"prompt budget echo lesson"*) ok "a lower-ranked lesson still surfaces once the top ones are seen" ;;
  *) bad "the lowest-ranked lesson never surfaced across three prompts" ;;
esac
check_empty "a fourth prompt has nothing left to say" \
  "$( cd "$rank_repo" && printf '{"session_id":"rankP"}' | .claude/hooks/lesson_recall.sh UserPromptSubmit)"
# The per-prompt cap itself. Deleting it leaves the two assertions above green:
# every lesson still surfaces, just all at once on the first prompt.
rp1_n="$(printf '%s' "$rp1" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -c '^- (x' || true)"
if [ "$rp1_n" -le 3 ]; then ok "a single prompt emits at most three lessons"; else bad "one prompt emitted $rp1_n lessons, cap is 3"; fi
# And the character budget, which capping outside lessons-recall.sh silently
# removed: measured 787 chars emitted where FR-5 caps this point at 600.
bud_repo="$WORK/promptbudget"
mkdir -p "$bud_repo"
cp -r scripts .claude "$bud_repo/" 2>/dev/null
mkdir -p "$bud_repo/docs/lessons"
( cd "$bud_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
for c in a b c d; do
  ( cd "$bud_repo" && ./scripts/lessons-append.sh \
      --rule "long lesson $c $(head -c 240 /dev/zero | tr '\0' "$c")" \
      --severity critical --occurrences 5 >/dev/null )
done
bud_out="$( cd "$bud_repo" && printf '{"session_id":"budP"}' | .claude/hooks/lesson_recall.sh UserPromptSubmit \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || printf '')"
bud_n="$(printf '%s' "$bud_out" | grep -c '^- (x' || true)"
if [ "${#bud_out}" -le 900 ]; then
  ok "UserPromptSubmit respects its character budget (${#bud_out} chars, $bud_n lesson(s))"
else
  bad "UserPromptSubmit emitted ${#bud_out} chars; FR-5 caps this point at 600 plus the header"
fi

# F4. Status for a known id must be resolved by folding the log, not by paging a
# ranked listing. `--max 200` meant that past 200 historical lessons a retired
# one fell off the end, read as status-unknown, and defaulted to active --
# reopening the retired-lesson black hole by a different route. Asserted
# structurally because reproducing it needs a 200-lesson store on every run.
# Comments are stripped first: this file explains in prose why it does NOT use
# lessons-recall.sh, and a grep over the raw text matches that explanation and
# turns the suite red with the code unchanged. Asserting the absence of any
# recall invocation, rather than of one literal flag value, also survives
# someone "fixing" it by raising --max 200 to --max 500.
ff_code="$(sed 's/#.*//' "$REPO_ROOT/.claude/hooks/failure_fingerprint.sh")"
case "$ff_code" in
  *"lessons-recall.sh"*) bad "failure_fingerprint.sh resolves a known id through a ranked listing" ;;
  *) ok "failure_fingerprint.sh does not resolve a known id through a ranked listing" ;;
esac
case "$ff_code" in
  *"lessons-fold.jq"*) ok "failure_fingerprint.sh folds the log directly for a known id" ;;
  *) bad "failure_fingerprint.sh no longer folds the log directly" ;;
esac

# A guard that points at nothing is the same failure as no guard, only harder to
# notice: the gate passes, the lesson stops being injected, and nothing enforces
# it. Reachable by a typo or by a refactor that deletes the guard file.
gp_store="$WORK/guardpath"
mkdir -p "$gp_store"
gp_id="$(./scripts/lessons-append.sh --store "$gp_store" --rule "guard path lesson" --occurrences 3)"
gp_rc=0
./scripts/lessons-append.sh --store "$gp_store" --promote "$gp_id" --guard "no/such/guard.sh" >/dev/null 2>&1 || gp_rc=$?
if [ "$gp_rc" -ne 0 ]; then ok "--promote with a nonexistent --guard is refused"; else bad "--promote accepted a guard path that does not exist"; fi
gp_rc2=0
RALPH_LESSONS_SKIP_GUARD_CHECK=1 ./scripts/lessons-append.sh --store "$gp_store" \
  --promote "$gp_id" --guard "external/ci-job" >/dev/null 2>&1 || gp_rc2=$?
if [ "$gp_rc2" -eq 0 ]; then ok "RALPH_LESSONS_SKIP_GUARD_CHECK allows a guard outside the repo"; else bad "the escape hatch did not work"; fi

# Indented error text must still be captured. The old guard tested the RAW
# subject for a leading space -- harmless while the subject began with the tool
# name, and silently fatal once it became arbitrary tool output, because most
# compiler and build output is indented.
ind_repo="$WORK/indent"
mkdir -p "$ind_repo"
cp -r scripts .claude "$ind_repo/" 2>/dev/null
mkdir -p "$ind_repo/docs/lessons"
( cd "$ind_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
ind_pay='{"session_id":"indA","tool_name":"Bash","tool_input":{"command":"cargo build"},"tool_response":{"stderr":"   Compiling foo v0.1.0 (/w/foo)"}}'
( cd "$ind_repo" && printf '%s' "$ind_pay" | .claude/hooks/failure_fingerprint.sh >/dev/null )
ind_out="$( cd "$ind_repo" && printf '%s' "$ind_pay" | .claude/hooks/failure_fingerprint.sh )"
check "an indented error is still fingerprinted and counted" "occurrence 2" "$ind_out"

# The complement: whitespace-only error text normalizes to the empty string,
# whose fingerprint is sha256("") -- one universal id shared by every tool and
# command. Adopting its draft would mint a lesson that claims every
# whitespace-error failure in the repo.
ws_repo="$WORK/whitespace"
mkdir -p "$ws_repo"
cp -r scripts .claude "$ws_repo/" 2>/dev/null
mkdir -p "$ws_repo/docs/lessons"
( cd "$ws_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
ws_out1="$( cd "$ws_repo" && printf '{"session_id":"wsA","tool_name":"Bash","tool_input":{"command":"make all"},"tool_response":{"stderr":"\t\t"}}' \
  | .claude/hooks/failure_fingerprint.sh )"
ws_out2="$( cd "$ws_repo" && printf '{"session_id":"wsB","tool_name":"Read","tool_input":{"command":"x.go"},"tool_response":{"stderr":"   "}}' \
  | .claude/hooks/failure_fingerprint.sh )"
check_empty "whitespace-only errors produce no output" "$ws_out1$ws_out2"
ws_counters="$( cd "$ws_repo" && ls .git/ralph-memory/failures 2>/dev/null | wc -l )"
check "whitespace-only errors create no universal counter" "0" "$ws_counters"

# Volatile counters and drafts live in the git common dir so they survive
# sessions and worktrees -- which also means nothing ever removed them. A change
# to what the hook fingerprints orphans every existing counter at once.
vol_repo="$WORK/volatile"
mkdir -p "$vol_repo"
cp -r scripts .claude "$vol_repo/" 2>/dev/null
mkdir -p "$vol_repo/docs/lessons"
( cd "$vol_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
( cd "$vol_repo" && mkdir -p .git/ralph-memory/failures .git/ralph-memory/drafts \
  && echo 2 > .git/ralph-memory/failures/deadbeefcafe.count \
  && echo draft > .git/ralph-memory/drafts/deadbeefcafe.md \
  && touch -d '400 days ago' .git/ralph-memory/failures/deadbeefcafe.count .git/ralph-memory/drafts/deadbeefcafe.md )
( cd "$vol_repo" && ./scripts/lessons-gc.sh --max-age-days 90 >/dev/null 2>&1 )
# Counted with a glob rather than `ls | grep`: the sweep deletes by path, so
# asking the filesystem directly is the accurate question, and it also avoids
# SC2010. (A comment line must not begin with the word shellcheck -- that is
# parsed as a directive, not prose.)
vol_left=0
for _f in "$vol_repo"/.git/ralph-memory/failures/deadbeefcafe.* "$vol_repo"/.git/ralph-memory/drafts/deadbeefcafe.*; do
  [ -e "$_f" ] && vol_left=$((vol_left + 1))
done
check "lessons-gc sweeps stale volatile counters and drafts" "0" "$vol_left"

# ─── cycle-3 /test survivors ──────────────────────────────────────────────────
#
# 23 mutations, 5 survivors, none of them a shipped defect -- all five were
# behaviour that works and that nothing asserted. Probed each shape directly
# before writing the assertion, because a survivor report describing a crash
# that does not reproduce is itself a finding.

# 1. --exclude-ids must degrade to "exclude nothing" for anything that is not a
#    readable file. The only real caller pre-creates the file, so a broken
#    fallback would have stayed hidden until the second caller.
exf_store="$WORK/excludefallback"
mkdir -p "$exf_store"
./scripts/lessons-append.sh --store "$exf_store" --rule "exclude fallback lesson" --occurrences 2 >/dev/null
for shape in "$exf_store/absent" "$exf_store/no/such/dir/file" "" "$exf_store"; do
  case "$(./scripts/lessons-recall.sh --store "$exf_store" --exclude-ids "$shape" --max 5 --budget 100000)" in
    *"exclude fallback lesson"*) ;;
    *) bad "--exclude-ids did not degrade for shape [$shape]"; continue ;;
  esac
done
ok "--exclude-ids degrades to excluding nothing for an absent path, an absent directory, an empty value and a directory"
# And the positive control, so the assertion above cannot pass by the filter
# never working at all.
exf_id="$(jq -r -s "$(cat scripts/lessons-fold.jq)"'fold | keys[0]' "$exf_store/lessons.jsonl")"
printf '%s\n' "$exf_id" > "$exf_store/seen"
check_empty "--exclude-ids with a real file does exclude" \
  "$(./scripts/lessons-recall.sh --store "$exf_store" --exclude-ids "$exf_store/seen" --max 5 --budget 100000)"

# 2. The volatile sweep must say nothing when there is nothing to sweep. Without
#    the glob-no-match guard an empty directory yields a literal unexpanded path
#    and a false "swept 1 file" report.
vq_repo="$WORK/volquiet"
mkdir -p "$vq_repo"
cp -r scripts .claude "$vq_repo/" 2>/dev/null
mkdir -p "$vq_repo/docs/lessons"
( cd "$vq_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
( cd "$vq_repo" && mkdir -p .git/ralph-memory/failures .git/ralph-memory/drafts )
vq_out="$( cd "$vq_repo" && ./scripts/lessons-gc.sh 2>&1 )"
case "$vq_out" in
  *swept*) bad "the sweep reported work on empty directories: $vq_out" ;;
  *) ok "the volatile sweep is silent when there is nothing to sweep" ;;
esac

# 3. --dry-run must not delete. This sweep runs unattended from
#    scripts/gc-artifacts.sh, whose own default is dry-run, so a dry run that
#    deletes is the worst failure in this file.
vd_repo="$WORK/voldry"
mkdir -p "$vd_repo"
cp -r scripts .claude "$vd_repo/" 2>/dev/null
mkdir -p "$vd_repo/docs/lessons"
( cd "$vd_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
( cd "$vd_repo" && mkdir -p .git/ralph-memory/failures \
  && echo 2 > .git/ralph-memory/failures/staleprobe1234.count \
  && touch -d '400 days ago' .git/ralph-memory/failures/staleprobe1234.count )
vd_out="$( cd "$vd_repo" && ./scripts/lessons-gc.sh --max-age-days 90 --dry-run 2>&1 )"
check "--dry-run reports the stale volatile file" "would sweep" "$vd_out"
if [ -f "$vd_repo/.git/ralph-memory/failures/staleprobe1234.count" ]; then
  ok "--dry-run left the stale volatile file in place"
else
  bad "--dry-run deleted a volatile file"
fi
( cd "$vd_repo" && ./scripts/lessons-gc.sh --max-age-days 90 >/dev/null 2>&1 )
if [ -f "$vd_repo/.git/ralph-memory/failures/staleprobe1234.count" ]; then
  bad "the real sweep did not delete the stale volatile file"
else
  ok "the real sweep deletes what --dry-run only reported"
fi

# 4. check-lessons.sh --json: nothing in this suite referenced it at all.
cj_store="$WORK/checkjson"
mkdir -p "$cj_store"
cj_empty_rc=0
cj_empty="$(./scripts/check-lessons.sh --store "$cj_store" --json 2>/dev/null)" || cj_empty_rc=$?
check "--json on an empty store is an empty array" "[]" "$cj_empty"
if [ "$cj_empty_rc" -eq 0 ]; then ok "--json on an empty store exits 0"; else bad "--json on an empty store exited $cj_empty_rc"; fi
./scripts/lessons-append.sh --store "$cj_store" --rule "json offender lesson" --occurrences 3 >/dev/null
cj_rc=0
cj_out="$(./scripts/check-lessons.sh --store "$cj_store" --json 2>/dev/null)" || cj_rc=$?
if [ "$cj_rc" -eq 1 ]; then ok "--json exits 1 when an offender exists"; else bad "--json exited $cj_rc with an offender present"; fi
check "--json reports the offender id" "$(jq -r -s "$(cat scripts/lessons-fold.jq)"'fold | keys[0]' "$cj_store/lessons.jsonl")" "$cj_out"
check "--json output parses as JSON" "json offender lesson" \
  "$(printf '%s' "$cj_out" | jq -r '.[0].rule' 2>/dev/null || printf 'PARSE FAILED')"

# 5. Every script's --help must print its whole header and keep its documented
#    exit code. The help ranges used to be hard-coded line numbers that fell
#    behind their own headers; nothing here covered --help at all.
for spec in "lessons-recall:1" "lessons-append:1" "lessons-gc:2" "check-lessons:2"; do
  hs_name="${spec%%:*}"
  hs_want="${spec##*:}"
  hs_rc=0
  hs_out="$(./scripts/$hs_name.sh --help 2>&1)" || hs_rc=$?
  if [ "$hs_rc" -eq "$hs_want" ]; then
    ok "$hs_name.sh --help exits $hs_want"
  else
    bad "$hs_name.sh --help exited $hs_rc, expected $hs_want"
  fi
  if [ "$(printf '%s' "$hs_out" | wc -l)" -ge 5 ]; then
    ok "$hs_name.sh --help prints its header"
  else
    bad "$hs_name.sh --help printed only $(printf '%s' "$hs_out" | wc -l) line(s)"
  fi
done
# The header must reach its own last line -- the old sed ranges silently cut the
# Usage and Exit lines off as headers grew.
check "lessons-append.sh --help reaches its Exit line" "Exit:" "$(./scripts/lessons-append.sh --help 2>&1)"
check "check-lessons.sh --help reaches its Exit line" "Exit:" "$(./scripts/check-lessons.sh --help 2>&1)"

# ─── cycle-3 /cross-review findings ───────────────────────────────────────────

# The cross-worktree tally must not lose updates. This counter exists to be
# shared between sessions and worktrees, so two of them hitting the same failure
# at once is its normal operating condition, not an edge case. Read-modify-write
# recorded 1 out of 50 parallel occurrences.
cc_repo="$WORK/concurrent"
mkdir -p "$cc_repo"
cp -r scripts .claude "$cc_repo/" 2>/dev/null
mkdir -p "$cc_repo/docs/lessons"
( cd "$cc_repo" && git init -q . && git config user.email s@t && git config user.name s \
  && echo seed > README.md && git add -A >/dev/null && git commit -qm init ) >/dev/null 2>&1
cc_pay='{"session_id":"ccA","tool_name":"Bash","tool_input":{"command":"go build"},"tool_response":{"stderr":"undefined: someSymbol"}}'
( cd "$cc_repo" && i=1; while [ "$i" -le 20 ]; do
    printf '%s' "$cc_pay" | .claude/hooks/failure_fingerprint.sh >/dev/null 2>&1 &
    i=$((i + 1))
  done; wait ) 2>/dev/null
cc_fp="$( cd "$cc_repo" && . scripts/lessons-common.sh && lessons_fingerprint "undefined: someSymbol" )"
cc_n="$( cd "$cc_repo" && . scripts/lessons-common.sh && lessons_failure_count "$cc_fp" )"
check "20 concurrent occurrences of one failure all count" "20" "$cc_n"

# The budget must measure what is actually printed. `rule + cause + 24` was
# smaller than the fixed text of every format, so two lessons could pass a
# 600-character budget and render as 609.
rb_store="$WORK/renderbudget"
mkdir -p "$rb_store"
rb_rule="$(head -c 250 /dev/zero | tr '\0' 'r')"
rb_cause="$(head -c 20 /dev/zero | tr '\0' 'c')"
./scripts/lessons-append.sh --store "$rb_store" --rule "A$rb_rule" --cause "$rb_cause" \
  --severity critical --occurrences 5 >/dev/null
./scripts/lessons-append.sh --store "$rb_store" --rule "B$rb_rule" --cause "$rb_cause" \
  --severity critical --occurrences 5 >/dev/null
rb_out="$(./scripts/lessons-recall.sh --store "$rb_store" --max 3 --budget 600)"
rb_len="$(printf '%s' "$rb_out" | wc -c)"
if [ "$rb_len" -le 600 ]; then
  ok "rendered output stays inside the character budget ($rb_len <= 600)"
else
  bad "rendered $rb_len chars against a 600 budget"
fi
# md renders longer than text for the same lessons, so it must be budgeted
# against its own output, not against the text form.
rb_md_out="$(./scripts/lessons-recall.sh --store "$rb_store" --max 3 --budget 600 --format md)"
rb_md="$(printf '%s' "$rb_md_out" | wc -c)"
if [ "$rb_md" -le 600 ]; then
  ok "md output is budgeted against md, not against the text form ($rb_md <= 600)"
else
  bad "md rendered $rb_md chars against a 600 budget"
fi
# ...and it has to actually be md. Checking only the length lets a mutation that
# renders md AS text pass: text is shorter, so the budget assertion still holds.
check "md output is md-formatted" "- **" "$rb_md_out"
check "md output carries the metadata line md callers expect" "hits " "$rb_md_out"
# And a budget generous enough must still admit the second lesson, so the two
# assertions above cannot pass by the budget simply rejecting everything.
check "a generous budget still admits both" "B$rb_rule" \
  "$(./scripts/lessons-recall.sh --store "$rb_store" --max 3 --budget 100000)"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
