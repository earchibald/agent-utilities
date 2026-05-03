#!/usr/bin/env bash
# Stop hook: schedules a warning 60 s before the next 1h cache cliff,
# writing HANDOFF.md when the timer trips and emitting a systemMessage
# banner in the Claude UI (not context) after the cliff passes.
set -uo pipefail

input=$(cat)
transcript=$(printf '%s' "$input" | /usr/bin/jq -r '.transcript_path // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id  // "default"' 2>/dev/null)

[[ -z "$transcript" || ! -f "$transcript" ]] && exit 0

now_epoch=$(date +%s)

# Find oldest active 1h cache entry — its cliff is ts + 3600
oldest_ts=$(
  /usr/bin/jq -rs --argjson now "$now_epoch" '
    [ .[]
      | select(.type=="assistant" and (.message.usage // empty))
      | { ts: (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
          m1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) }
    ]
    | [ .[] | select(.ts > ($now - 3600) and .m1h > 0) ]
    | sort_by(.ts) | first // {ts: 0}
    | .ts | floor
  ' "$transcript" 2>/dev/null
)

oldest_ts=${oldest_ts:-0}
[ "$oldest_ts" -le 0 ] && exit 0

cliff_time=$(( oldest_ts + 3600 ))
warn_time=$(( cliff_time - 60 ))
rem=$(( cliff_time - now_epoch ))

cliff_hhmm=$(date -r "$cliff_time" '+%H:%M' 2>/dev/null \
  || date -d "@$cliff_time" '+%H:%M' 2>/dev/null \
  || echo "soon")

handoff_path="$HOME/.claude/HANDOFF.md"

# ── Cancel previous timer for this session ──────────────────────────────────
pid_file="/tmp/claude-cliff-pid-${session_id}"
if [[ -f "$pid_file" ]]; then
  old_pid=$(cat "$pid_file" 2>/dev/null || true)
  [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
  rm -f "$pid_file"
fi

# ── Schedule the 1-minute-before warning ────────────────────────────────────
if [ "$rem" -gt 0 ]; then
  delay=$(( warn_time - now_epoch ))
  [ "$delay" -lt 0 ] && delay=0

  (
    [ "$delay" -gt 0 ] && sleep "$delay"

    # Write HANDOFF.md
    cat > "$handoff_path" <<HANDOFF
# Session Handoff

**⚠️  The 1h token cache will expire at ${cliff_hhmm}. Treat this session as dead.**

Cached tokens are expiring — continuing here costs as much as starting fresh but
without clean context.

## How to continue

1. Run \`/compact\` now to get a summary you can carry forward
2. Commit any in-progress changes (\`git add -p && git commit -m "wip: ..."\`)
3. Type \`/quit\` (or Ctrl-C) to end this session
4. Start a new Claude Code session in the same working directory
5. Begin with: *"Continuing from HANDOFF.md — \`cat ~/.claude/HANDOFF.md\`"*

## What to brief the new session on

- Current task / goal
- Files recently edited (check \`git status\` and \`git diff HEAD\`)
- Any decisions made, blockers hit, or context the model held
- The plan document or issue number if applicable

## Session info

- Transcript: ${transcript}
- Cache expired at: ${cliff_hhmm}
HANDOFF

    rm -f "$pid_file"
  ) > /dev/null 2>&1 &
  disown $!
  echo $! > "$pid_file"
fi

# ── systemMessage: shown in Claude UI (not injected into context) ────────────
# Only surfaces after the cliff passes — the statusline handles pre-cliff colour.
if [ "$rem" -le 0 ]; then
  printf '{"systemMessage": "💀 1h cache expired at %s — this session is dead. Run /compact, commit WIP, then /quit and start fresh. See ~/.claude/HANDOFF.md"}\n' \
    "$cliff_hhmm"
fi

exit 0
