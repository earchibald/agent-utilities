---
title: agent-utilities
description: Claude Code hooks and utilities for session management
---

# agent-utilities

Hooks and a slash command that fire around the 1-hour prompt-cache cliff in Claude Code, so a long session can hand itself off cleanly to a fresh one without paying the full re-hydration cost.

See [[docs/handoff-methodology|the methodology doc]] for the design rationale; [[docs/testing-protocol|the testing protocol]] for the harness; [[CHANGELOG]] for what shipped when.

## Quick setup

1. **Wire the three hooks** in `~/.claude/settings.json`:
   - `Stop` → `claude/hooks/cache-cliff-handoff.sh` (with `"asyncRewake": true`)
   - `Stop` → `claude/hooks/cache-cliff-warn.sh` (sync)
   - `UserPromptSubmit` → `claude/hooks/cache-cliff-busy-mark.sh`
2. **Add wildcard write permissions** to `~/.claude/settings.json` `permissions.allow`:
   ```
   "Write(HANDOFF-*.md)",
   "Write(HANDOFF-stats-*.json)"
   ```
   Wildcards cover every session — declare once, all current and future sessions can write their own per-session handoff. Anchored match in the hooks prevents substring false-positives (e.g. `Read(HANDOFF.md)` will never satisfy a `Write` check).
3. **Install the slash command** for manual handoff at any time:
   ```bash
   cp claude/commands/handoff.md ~/.claude/commands/handoff.md
   ```

## Components

### [[claude/hooks/cache-cliff-handoff|cache-cliff-handoff]]

**Stop hook (asyncRewake)** — sleeps until 2 minutes before the active 1h cliff, then exits 2 to inject a HANDOFF directive into the model's context.

- Per-session artifact: writes to `HANDOFF-${session_id:0:8}.md` in the agent's CWD
- Gated by `CACHE_CLIFF_MIN_TOKENS` (env, default 20000)
- **Bails on busy** — checks `/tmp/claude-cliff-busy-${session_id}` after wake; if set (UserPromptSubmit fired during sleep, agent in mid-turn), exits without injecting
- **Rate-limited** — if last successful fire was within 10 minutes, skip
- **User-activity gated** — if no new user message has arrived since last fire, skip (the only intervening event was our own HANDOFF write)
- **Atomic supersession** — pid_file and sentinel writes go through tmp + `mv`; sentinel encodes `${cliff_time}_${$$}` so duplicate suppression is robust to identical cliff_times across consecutive Stops
- **Trap cleanup** — TERM/INT removes pid_file and sentinel_file when we still own the token

### [[claude/hooks/cache-cliff-warn|cache-cliff-warn]]

**Stop hook (sync)** — emits a `systemMessage` banner.

- Two banner kinds:
  1. *Handoff ready* — fires when `0 < rem ≤ 120s` and a ready-sentinel exists; reports cliff time, expiring tokens, generation cost, permission status, full HANDOFF path
  2. *Missed cliff* — fires after handoff.sh bailed because the agent was busy; reports the burned-cache token count and prompts the user to run `/handoff`
- Test mode (`/tmp/claude-cliff-test-cliff` exists) writes a per-session `HANDOFF-stats-${session_short}.json` for harness consumption
- Cleans up orphaned ready/stats/perm-request sentinels when the cliff has already passed

### [[claude/hooks/cache-cliff-busy-mark|cache-cliff-busy-mark]]

**UserPromptSubmit hook** — touches `/tmp/claude-cliff-busy-${session_id}` at the start of every user turn. Both Stop hooks `rm` it at the top of execution, so the flag exists exactly during an active turn.

### [[claude/commands/handoff|/handoff slash command]]

Manual escape hatch — invoke at any clean stopping point and the agent writes the same per-session handoff file using the same template as the auto rewake directive. Useful before `/clear`, before a long break, or in response to a missed-cliff banner.

## Handoff flow

**Auto path:** banner appears → `/clear` or `/quit` → start fresh session → `read HANDOFF-{session_short}.md and continue`.

**Manual path:** at any quiet moment, type `/handoff` → handoff written → continue or hand off as you choose.
