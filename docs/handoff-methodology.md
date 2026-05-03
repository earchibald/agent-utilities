# HANDOFF.md Methodology

## Intent

A HANDOFF.md is a **directive document written by the outgoing agent** — not a history dump, not a compact summary. Its purpose is to let a replacement agent pick up work immediately with minimal data-gathering churn.

The outgoing agent has full session context loaded. That is the moment it is best-positioned to make active decisions about direction, surface the reasoning behind choices made, and specify exactly what the next agent should do. We capture that moment intentionally, before it expires.

## What HANDOFF.md contains

| Section | Purpose |
|---|---|
| **Objective** | The goal, stated as a forward-looking intention — not a description of work done |
| **Decisions Made** | Key choices this session and their reasoning, so the next agent does not re-litigate them |
| **Current State** | Precise in-progress state: which files are modified, what works, what is broken, what is half-done |
| **Next Actions** | Specific ordered steps the next agent should execute immediately on reading this — directive, not suggestive |
| **Must-Know Context** | Non-obvious constraints, conventions, gotchas, or background knowledge that was hard-won this session |

## Why not just `/compact`?

`/compact` summarises history for the *same* agent to continue. HANDOFF.md briefs a *new* agent to continue *independently*. The difference is perspective: compact optimises for continuity within a session; HANDOFF optimises for a clean handover across a session boundary.

## Triggering mechanism

The `cache-cliff-handoff.sh` hook uses `asyncRewake` — a Claude Code feature that lets a background process re-inject a system-level directive into the model at a scheduled time. The flow:

1. Every Stop event fires the hook (async). It kills the previous instance, registers itself, and sleeps.
2. At **cliff − 60 seconds**, the hook wakes, checks that it has not been superseded, then exits with code 2.
3. Claude Code injects the hook's stdout as a `system-reminder` — not a user message, not a context token — and wakes the model.
4. The model writes `HANDOFF.md` into the project's CWD.
5. The user receives the post-cliff `systemMessage` banner ("Prompt: read HANDOFF.md and continue") if they miss the window.

## Why 60 seconds before the cliff?

The cache is still fully warm at T−60. The model can read the transcript and reason about next steps without paying rehydration cost. Writing HANDOFF.md costs one extra response turn; the cache pays for it.

## Threshold gating

Generation is skipped if `total_m1h_tokens < CACHE_CLIFF_MIN_TOKENS` (default: 20 000).

**Rationale:** The cost of generating HANDOFF.md (reading the full context, producing ~1 k output tokens) is roughly constant. The value of avoiding rehydration scales with cache size. Below ~20 k tokens the session is small enough that starting fresh is cheaper and easier than a formal handoff.

**Configurable:** Set `CACHE_CLIFF_MIN_TOKENS=N` in the environment to tune this threshold per project or workflow.

## Properties of a good HANDOFF.md

- **Opinionated** — the outgoing agent makes calls. "Continue with approach X" not "you could try X or Y."
- **Precise** — file paths, function names, exact error messages, not vague descriptions.
- **Forward-looking** — what to do next, not what was done.
- **Minimal** — one agent turn of reading, not a transcript. If it takes more than 2 minutes to read, it is too long.
- **Local** — written to the project's CWD so the next agent finds it immediately on start.
