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

# Sanitize session_id for use in /tmp paths (prevent traversal / shell metas)
session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-' | head -c 64)
[[ -z "$session_id" ]] && session_id="default"

# A Stop fired, so the agent has just finished — clear the busy flag so the
# next UserPromptSubmit (start of next turn) can re-set it cleanly.
busy_sentinel="/tmp/claude-cliff-busy-${session_id}"
rm -f "$busy_sentinel"

[[ -z "$transcript" || ! -f "$transcript" ]] && exit 0

now_epoch=$(date +%s)

# Parse oldest active 1h cache ts and total active 1h token count
read -r oldest_ts total_m1h < <(
  /usr/bin/jq -rs --argjson now "$now_epoch" '
    [ .[]
      | select(.type=="assistant" and (.message.usage // empty))
      | { ts: (try (.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601) catch 0),
          m1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) }
    ]
    | [ .[] | select(.ts >= ($now - 3600) and .m1h > 0) ]
    | sort_by(.ts)
    | { oldest: (first // {ts:0} | .ts | floor),
        total:  (map(.m1h) | add // 0) }
    | "\(.oldest) \(.total)"
  ' "$transcript" 2>/dev/null
)

oldest_ts=${oldest_ts:-0}
total_m1h=${total_m1h:-0}

# Test override: echo a future epoch into this file to skip transcript parsing
# e.g. echo $(( $(date +%s) + 180 )) > /tmp/claude-cliff-test-cliff
test_flag="/tmp/claude-cliff-test-cliff"
if [[ -f "$test_flag" ]]; then
  cliff_time=$(cat "$test_flag")
  oldest_ts=$(( cliff_time - 3600 ))
  total_m1h=999999
else
  [ "$oldest_ts" -le 0 ] && exit 0
  cliff_time=$(( oldest_ts + 3600 ))
fi

warn_time=$(( cliff_time - 120 ))
rem=$(( cliff_time - now_epoch ))

[ "$rem" -le 0 ] && exit 0  # cliff already passed; warn hook handles UI

# Threshold gate: skip if cache is too small to justify generation cost
min_tokens=${CACHE_CLIFF_MIN_TOKENS:-20000}
[ "$total_m1h" -lt "$min_tokens" ] && exit 0

pid_file="/tmp/claude-cliff-handoff-pid-${session_id}"
sentinel_file="/tmp/claude-cliff-handoff-sentinel-${session_id}"

# Atomically replace pid_file and sentinel_file via tmp+mv, so concurrent
# Stops cannot observe a half-written or rm'd state. Read old PID first.
old_pid=""
[[ -f "$pid_file" ]] && old_pid=$(cat "$pid_file" 2>/dev/null || true)

own_token="${cliff_time}_$$"
printf '%s' "$$"        > "${pid_file}.tmp.$$"      && mv -f "${pid_file}.tmp.$$"      "$pid_file"
printf '%s' "$own_token" > "${sentinel_file}.tmp.$$" && mv -f "${sentinel_file}.tmp.$$" "$sentinel_file"

# Kill the previous instance now that our registration is committed. A
# concurrent peer Stop will see our PID/sentinel (post-mv) and quietly bail
# at the cliff-token check on wake.
if [[ -n "$old_pid" && "$old_pid" != "$$" ]]; then
  pkill -P "$old_pid" 2>/dev/null || true
  kill  "$old_pid"  2>/dev/null || true
fi

# On TERM/INT, kill our sleep child AND remove our pid/sentinel files —
# otherwise Claude Code timeout / session exit leaks them into /tmp until
# a future Stop overwrites.
cleanup() {
  pkill -P $$ 2>/dev/null || true
  # Only clean up the sentinel if we still own it (prevents racing a successor)
  [[ "$(cat "$sentinel_file" 2>/dev/null || echo)" = "$own_token" ]] && rm -f "$sentinel_file" "$pid_file"
  exit 0
}
trap cleanup TERM INT

delay=$(( warn_time - now_epoch ))
# If we're already past warn_time and the ready-sentinel exists, we already
# fired this round — bail to prevent a tight re-fire loop.
ready_sentinel="/tmp/claude-cliff-handoff-ready-${session_id}"
[ "$delay" -le 0 ] && [ -f "$ready_sentinel" ] && exit 0
[ "$delay" -gt 0 ] && sleep "$delay"

# Bail if superseded by a later Stop event (token mismatch = newer registrant)
current=$(cat "$sentinel_file" 2>/dev/null || echo "")
[ "$current" = "$own_token" ] || exit 0

# Bail if the agent is mid-turn — UserPromptSubmit set this flag and no Stop
# has fired since to clear it. Injecting a rewake directive now would
# interrupt their flow. Leave a sentinel so warn.sh can surface a "missed
# cliff" banner on the next Stop — pointing the user at /handoff.
if [[ -f "$busy_sentinel" ]]; then
  printf '%s %s\n' "$cliff_time" "$total_m1h" > "/tmp/claude-cliff-skipped-busy-${session_id}"
  exit 0
fi

cliff_hhmm=$(date -r "$cliff_time" '+%H:%M' 2>/dev/null \
  || date -d "@$cliff_time" '+%H:%M' 2>/dev/null \
  || echo "soon")

# Per-session artifact: lets multiple Claude sessions share a CWD without
# clobbering each other's HANDOFF. Banner prints the full path so the user
# always knows which file goes with which session.
session_short="${session_id:0:8}"
handoff_path="${cwd:-.}/HANDOFF-${session_short}.md"

# Check Write permissions. Look for the wildcard form (Write(HANDOFF-*.md))
# which covers all sessions, or the exact session-suffixed form. Anchored
# matches only — substring/contains() would falsely match Read/Bash rules.
missing_perms=()
for pattern in "HANDOFF-*.md" "HANDOFF-stats-*.json"; do
  exact_session_form="${pattern/\*/$session_short}"
  found=false
  for sf in "$HOME/.claude/settings.json" "${cwd:-.}/.claude/settings.json"; do
    [[ -f "$sf" ]] || continue
    if /usr/bin/jq -e \
         --arg wild "$pattern" \
         --arg exact "$exact_session_form" \
         '(.permissions.allow // [])[] | select(
            . == "Write(" + $wild + ")"
            or . == "Write(" + $exact + ")"
            or (startswith("Write(") and (endswith("/" + $wild + ")") or endswith("/" + $exact + ")")))
         )' "$sf" &>/dev/null; then
      found=true; break
    fi
  done
  $found || missing_perms+=("$pattern")
done

rm -f "$pid_file" "$sentinel_file"

echo "$total_m1h" > "$ready_sentinel"

# Snapshot cumulative token counts so warn.sh can report the generation delta
stats_file="/tmp/claude-cliff-stats-${session_id}"
/usr/bin/jq -rs '
  [ .[] | select(.type=="assistant" and (.message.usage // empty)) | .message.usage ]
  | "\(map(.input_tokens  // 0) | add // 0) \(map(.output_tokens // 0) | add // 0)"
' "$transcript" > "$stats_file" 2>/dev/null || true

# Flag for warn.sh: permission creation was requested this cycle
perm_request_sentinel="/tmp/claude-cliff-perm-requested-${session_id}"
perm_note=""
if [ "${#missing_perms[@]}" -gt 0 ]; then
  printf '%s\n' "${missing_perms[@]}" > "$perm_request_sentinel"
  missing_list=$(printf '"Write(%s)" ' "${missing_perms[@]}")
  perm_note="
## Permission Setup
The following Write permission patterns were not found in ~/.claude/settings.json or .claude/settings.json: ${missing_list}
These are wildcard patterns covering all sessions — adding them once gives every future session permission to write its own per-session handoff file.
Tell the user (in your reply): add these manually to permissions.allow in ~/.claude/settings.json (global, preferred) or .claude/settings.json (project-only).
Only attempt the edit yourself if you already have Edit permission for the settings file — otherwise asking will stall the cliff window. The next agent session can complete the add."
else
  rm -f "$perm_request_sentinel"
fi

# Output the directive prompt — appended to rewakeMessage, injected as
# system-reminder into the model's context to trigger HANDOFF.md authoring.
cat <<PROMPT
The 1h prompt-cache expires at ${cliff_hhmm} (~2m). Write ${handoff_path} now.
Be concise. Target under 800 words. The next agent is capable — orient them, don't exhaustively document.

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
${perm_note}
PROMPT

exit 2
