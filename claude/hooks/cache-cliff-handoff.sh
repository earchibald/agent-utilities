#!/usr/bin/env bash
# asyncRewake Stop hook: sleeps until 120s before the 1h cache cliff, then
# exits 2 to wake the model and instruct it to write a directive HANDOFF.md.
#
# Each Stop event kills the previous instance and reschedules, so the timer
# always reflects the current cliff. A sentinel file prevents a surviving
# stale instance from misfiring after being superseded.
#
# Gated by CACHE_CLIFF_MIN_TOKENS (default 20000): below this threshold the
# session cache is small enough that rehydration is cheaper than generation.
set -uo pipefail

input=$(cat)
transcript=$(printf '%s' "$input" | /usr/bin/jq -r '.transcript_path // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id  // "default"' 2>/dev/null)
cwd=$(       printf '%s' "$input" | /usr/bin/jq -r '.cwd         // empty'     2>/dev/null)

[[ -z "$transcript" || ! -f "$transcript" ]] && exit 0

now_epoch=$(date +%s)

# Parse oldest active 1h cache ts and total active 1h token count
read -r oldest_ts total_m1h < <(
  /usr/bin/jq -rs --argjson now "$now_epoch" '
    [ .[]
      | select(.type=="assistant" and (.message.usage // empty))
      | { ts: (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
          m1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) }
    ]
    | [ .[] | select(.ts > ($now - 3600) and .m1h > 0) ]
    | sort_by(.ts)
    | { oldest: (first // {ts:0} | .ts | floor),
        total:  (map(.m1h) | add // 0) }
    | "\(.oldest) \(.total)"
  ' "$transcript" 2>/dev/null
)

oldest_ts=${oldest_ts:-0}
total_m1h=${total_m1h:-0}

[ "$oldest_ts" -le 0 ] && exit 0

cliff_time=$(( oldest_ts + 3600 ))
warn_time=$(( cliff_time - 120 ))
rem=$(( cliff_time - now_epoch ))

[ "$rem" -le 0 ] && exit 0  # cliff already passed; warn hook handles UI

# Threshold gate: skip if cache is too small to justify generation cost
min_tokens=${CACHE_CLIFF_MIN_TOKENS:-20000}
[ "$total_m1h" -lt "$min_tokens" ] && exit 0

pid_file="/tmp/claude-cliff-handoff-pid-${session_id}"
sentinel_file="/tmp/claude-cliff-handoff-sentinel-${session_id}"

# Kill previous instance of this hook for this session
if [[ -f "$pid_file" ]]; then
  old_pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -n "$old_pid" ]]; then
    pkill -P "$old_pid" 2>/dev/null || true
    kill  "$old_pid"  2>/dev/null || true
  fi
  rm -f "$pid_file"
fi

# Register self and write sentinel
echo "$$"        > "$pid_file"
echo "$cliff_time" > "$sentinel_file"

# Ensure sleep child is killed if this process is killed
trap 'pkill -P $$ 2>/dev/null; exit 0' TERM INT

delay=$(( warn_time - now_epoch ))
[ "$delay" -gt 0 ] && sleep "$delay"

# Bail if superseded by a later Stop event
current=$(cat "$sentinel_file" 2>/dev/null || echo "")
[ "$current" = "$cliff_time" ] || exit 0

cliff_hhmm=$(date -r "$cliff_time" '+%H:%M' 2>/dev/null \
  || date -d "@$cliff_time" '+%H:%M' 2>/dev/null \
  || echo "soon")

handoff_path="${cwd:-.}/HANDOFF.md"

rm -f "$pid_file" "$sentinel_file"

ready_sentinel="/tmp/claude-cliff-handoff-ready-${session_id}"
touch "$ready_sentinel"

# Output the directive prompt — appended to rewakeMessage, injected as
# system-reminder into the model's context to trigger HANDOFF.md authoring.
cat <<PROMPT
The 1h prompt-cache expires at ${cliff_hhmm} (~2m). Write ${handoff_path} now.

This is a directive for the next agent session — not a history summary or compact.
Write as if briefing a capable replacement who has zero context but full capability.
Be opinionated and specific. The next agent will act on this immediately.

## Objective
What we are trying to accomplish and why. State as a goal, not as a description of work done.

## Decisions Made
Key decisions this session with the reasoning behind them. The next agent must not re-litigate these.

## Current State
Exact in-progress state right now: which files are modified, what works, what is broken, what is half-done. Be precise.

## Next Actions
Specific ordered steps the next agent should execute immediately on reading this. Be directive — "do X, then Y" not "you might consider X."

## Must-Know Context
Non-obvious constraints, conventions, gotchas, or background knowledge that was hard-won this session and must not be lost.

Write the file now. Output only the absolute path when done.
PROMPT

exit 2
