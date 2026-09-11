# lessons-fold.jq - shared reducer for the append-only lesson log.
#
# Included by lessons-recall.sh, check-lessons.sh and lessons-gc.sh so the three
# readers cannot drift on what "hits" or "status" mean. Input: the whole log
# slurped as an array. Output: an object keyed by lesson id.
#
#   hits    number of upsert + hit records, plus any seed_hits carried by a
#           record. An `amend` record deliberately counts for nothing: editing a
#           lesson's wording is not another occurrence of the failure, and
#           counting it would let a rewrite push a lesson up the promotion
#           ladder and trip check-lessons.sh with nothing having recurred. The seed exists because a failure can recur several times
#           before anyone records a lesson for it: adopting a draft carries the
#           occurrences already counted, so the promotion ladder is not reset by
#           the act of writing the lesson down.
#   status  active after upsert, promoted after promote, retired after retire;
#           a hit leaves it alone.
#
# Every other field: newest record wins.

def sevrank: {"low":0,"medium":1,"high":2,"critical":3}[.] // 0;

def fold:
  reduce .[] as $r ({};
    .[$r.id] = (
      (.[$r.id] // {id: $r.id, hits: 0, status: "active"})
      + ($r | del(.op, .schema, .seed_hits))
      + { hits: ( ((.[$r.id].hits) // 0)
                  + (if ($r.op // "upsert") == "upsert" or $r.op == "hit" then 1 else 0 end)
                  + (($r.seed_hits // 0)) ),
          status: (
            if $r.op == "promote" then "promoted"
            elif $r.op == "retire" then "retired"
            elif ($r.op // "upsert") == "upsert" then "active"
            # amend and hit both land here: they change fields and counts, never
            # status. An explicit `elif $r.op == "amend"` arm used to sit above
            # this line, byte-identical to it -- no mutation could kill it,
            # because deleting it changed nothing. Keeping the fallthrough and
            # naming the ops in a comment says the same thing honestly.
            else ((.[$r.id].status) // "active") end) }
    ));

# A lesson that is not active must say so in every human-facing view. Only
# --include-promoted surfaces those, and that is the command /lesson step 2 runs
# to check for an existing lesson before amending -- so an unmarked retired
# lesson reads as live and gets an amendment that does nothing, because amend
# leaves status alone. Used by both renderers in lessons-recall.sh.
def status_tag:
  if (.status // "active") == "active" then "" else " [" + .status + "]" end;
