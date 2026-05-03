---
description: Manually write a session-handoff directive at a clean stopping point. Use before a long break, before /clear, or after a "missed cliff" banner.
---

Write a session handoff to `${CWD}/HANDOFF-${SESSION_SHORT}.md` where:

- `${CWD}` = the current working directory (run `pwd` if unsure)
- `${SESSION_SHORT}` = the first 8 characters of your session_id

To find your session_id, list the most recently modified `*.jsonl` file under `~/.claude/projects/` matching this CWD's path-encoded directory name (`/` → `-`). The basename minus `.jsonl` is the session_id. Take the first 8 characters.

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
