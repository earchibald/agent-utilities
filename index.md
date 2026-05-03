---
title: agent-utilities
description: Claude Code hooks and utilities for session management
---

# agent-utilities

Hooks and utilities that run alongside Claude Code sessions.

## Hooks

### [[claude/hooks/cache-cliff-warn|cache-cliff-warn]]

**Stop hook** — schedules a 60-second-early warning before the active 1h prompt-cache cliff expires.

- Reads the session transcript on every Stop event to find the oldest live 1h cache entry
- Spawns a background timer (`sleep` + `disown`) set to fire at `cliff_time − 60s`
- When the timer trips: writes `~/.claude/HANDOFF.md` with continuation instructions
- After the cliff passes: emits a `systemMessage` banner in the Claude Code UI (not injected into model context) reminding you the session is dead
- Wired into `~/.claude/settings.json` → `hooks.Stop`

**Handoff flow**: when the banner appears → run `/compact`, commit WIP, `/quit`, start a new session, open `~/.claude/HANDOFF.md`.
