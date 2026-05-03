---
title: agent-utilities
description: Claude Code hooks and utilities for session management
---

# agent-utilities

Hooks and utilities that run alongside Claude Code sessions.

## Hooks

### [[claude/hooks/cache-cliff-handoff|cache-cliff-handoff]]

**Stop hook (asyncRewake)** — sleeps until 2 minutes before the active 1h prompt-cache cliff, then wakes the model to write `HANDOFF.md`.

- Reads transcript on every Stop event; computes `cliff_time` from the oldest live 1h cache entry
- Kills and reschedules any prior instance so the timer always reflects the latest cliff
- Gated by `CACHE_CLIFF_MIN_TOKENS` (env, default 20000): skips if cache is too small to justify generation
- At `cliff_time − 120s`: touches ready-sentinel, exits 2 to inject a directive rewake prompt
- The rewake prompt instructs the model to write a structured `HANDOFF.md` in the agent CWD
- Wired into `~/.claude/settings.json` → `hooks.Stop`

### [[claude/hooks/cache-cliff-warn|cache-cliff-warn]]

**Stop hook (sync)** — emits a `systemMessage` banner once `HANDOFF.md` is ready, ~2 minutes before cliff.

- Checks for the ready-sentinel (`/tmp/claude-cliff-handoff-ready-$session_id`) left by `cache-cliff-handoff.sh`
- Fires only when `0 < rem ≤ 120s` and sentinel exists; deletes sentinel after firing
- Banner tells the user the cache expires in 2m, HANDOFF.md is in the local directory, and suggests `/clear` or `/quit`
- Does not inject into model context; does not instruct `/compact`
- Wired into `~/.claude/settings.json` → `hooks.Stop`

**Handoff flow**: banner appears → `/clear` or `/quit` → start fresh session → `read HANDOFF.md and continue`.
