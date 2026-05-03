#!/usr/bin/env bash
# UserPromptSubmit hook: marks the agent as "busy" so cache-cliff-handoff.sh
# bails on wake instead of injecting a rewake directive into an in-flight turn.
# The Stop hooks (warn.sh + handoff.sh) clear this flag at the top, so it
# only persists for the lifetime of an active turn (UserPromptSubmit → Stop).
set -uo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id // "default"' 2>/dev/null)
session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-' | head -c 64)
[[ -z "$session_id" ]] && session_id="default"

touch "/tmp/claude-cliff-busy-${session_id}"
exit 0
