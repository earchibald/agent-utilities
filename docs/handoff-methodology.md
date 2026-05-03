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

1. Every Stop event fires `cache-cliff-handoff.sh` (async). It kills the previous instance, registers itself, and sleeps.
2. At **cliff − 120 seconds**, the hook wakes, checks it has not been superseded, snapshots cumulative input/output tokens, writes a ready-sentinel, then exits with code 2.
3. Claude Code injects the hook's stdout as a `system-reminder` — not a user message, not a context token — and wakes the model.
4. The model writes `HANDOFF.md` into the project's CWD and, if requested, adds missing `Write(...)` permissions to settings.
5. On the next Stop, `cache-cliff-warn.sh` (sync) reads the ready-sentinel + a fresh transcript snapshot, computes the generation token-delta, and emits a `systemMessage` banner: cliff time, tokens expiring, generation cost, permission status.

## Why 120 seconds before the cliff?

The cache is still fully warm at T−120. The model can read the transcript and reason about next steps without paying rehydration cost. Writing HANDOFF.md costs one extra response turn; the cache pays for it.

We use 120 s rather than 60 s because empirically the model takes 20–60 s to write a multi-section directive document, and we want the resulting `systemMessage` banner to fire **before** the cliff, leaving the user a real window to act. With T−60, slow generations would land past the cliff and the banner would be useless.

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

## Tuning History

The asyncRewake handoff was tuned over a series of test cycles using the harness in `docs/testing-protocol.md`. Each cycle armed `/tmp/claude-cliff-test-cliff` with a future epoch, then a `/loop` cron polled `HANDOFF-stats.json` for the captured token delta. `cost_in` is the input-token delta, `cost_out` is the output-token delta over the window from handoff.sh fire to warn.sh fire.

### Token cost across cycles

| # | Date | Rewake-prompt change | Other notable work this cycle | `cost_in` | `cost_out` | Notes |
|---|------|----------------------|-------------------------------|-----------|------------|-------|
| 1 | 2026-05-03 | none (baseline) | — | ~0 | 4142 | Verbose HANDOFF; no constraint |
| 2 | 2026-05-03 | none | — | ~0 | 783 | Coincidentally tight |
| 3 | 2026-05-03 | none | first perm-add Edit (HANDOFF.md) | ~0 | 3552 | High variance motivated #2 |
| 4 | 2026-05-03 | `Be concise. Target under 800 words.` | second perm-add Edit (HANDOFF-stats.json) | 15 | 2366 | HANDOFF body alone: 459 words ≈ 596 tokens |

**Read carefully.** `cost_out` bundles the HANDOFF.md body **and** every other output token between the two Stops — perm-add Edit calls, status checks, tool-call JSON wrapping. Cycles 3 and 4 each included a one-time perm-add to settings.json; cycles 1 and 2 did not. The hint in cycle 4 made the file content concise (459 words, well under 800), but the metric still reads ~2 k because of that ancillary work.

### What we learned

- **`cost_in` is effectively zero** — full conversation context is served from cache, only the rewake directive itself is novel input. This validates the cache-economics premise: handoff is cheap to generate.
- **`cost_out` is dominated by the HANDOFF body but contaminated by anything else the model does between fires.** The metric is useful for trend detection (cycle-over-cycle changes) but not for absolute targeting.
- **Variance pre-hint was 783–4142.** Post-hint we have only one data point (2366); the post-hint file itself was 459 words. We did not record `wc -w` for cycles 1–3, so we cannot quantify the hint's effect on body size — only that the post-hint body landed under the 800-word target. Treat as "addresses #2, validated by n=1; needs more cycles to claim a real reduction."
- **Don't over-tune the hint based on `cost_out` alone.** Word-count of HANDOFF.md is the cleaner metric. Future tuning must `wc -w HANDOFF.md` immediately after each cycle and compare against the 800-word target rather than chasing the noisy token delta. Also avoid pairing prompt changes with simultaneous perm-add Edits — cycles 3 and 4 both included perm-add work, confounding the hint's effect.

### Structural fixes during tuning

These were caught during the tuning runs and shipped before the final cycle:

| Bug | Symptom | Fix | Commit |
|---|---|---|---|
| Invalid JSON in `systemMessage` | Banner silently never appeared | `printf` with literal `\n` produced unparseable JSON; switched to `jq -n --arg m "$msg" '{"systemMessage": $m}'` | (early) |
| Tight re-fire loop | Hook re-armed and re-fired immediately when `delay≤0` | Bail when `delay≤0` and ready-sentinel exists | 469284f |
| Perm-check double-escape | Banner reported "could not add" for permissions that were in fact added | Switched jq filter from `test($p)` (regex, with `${pattern//./\\\\.}` escaping) to `contains($f)` (plain substring match) | 237e541 |
| Perm-check too liberal (after first fix) | `contains("HANDOFF.md")` would falsely satisfy from `Read(HANDOFF.md)`, `Bash(echo HANDOFF.md)`, etc. — wrong-tool permissions reported as "already present" | Anchored to exact `Write(<f>)` plus `endswith("/<f>)")` for absolute-path entries | (post-review) |
| Supersession sentinel cosmetic | When consecutive Stops produced the same `cliff_time` (typical mid-session), the supersession check passed for both predecessor and successor — duplicate suppression silently depended only on the `kill $old_pid` step | Sentinel now encodes `${cliff_time}_${$$}`; predecessor sees mismatch and bails | (post-review) |
| Timestamp parser brittle | Only `.fffZ` fractional-with-`Z` was normalised; `+00:00`/`-07:00` offsets caused `fromdateiso8601` to error and the whole pipeline to silently no-op | `try (… sub("\\.[0-9]+"; "") \| fromdateiso8601) catch 0` per-row | (post-review) |

## Operational properties

- **Per-session artifact naming** — each Claude session writes its handoff to `HANDOFF-${session_id:0:8}.md` in the agent's CWD. The banner prints the absolute path so users always know which file goes with which session. In test mode the stats file follows the same convention: `HANDOFF-stats-${session_id:0:8}.json`. This means multiple Claude sessions can run concurrently in the same project without clobbering each other's handoff.
- **Permissions** — declare wildcards once: `Write(HANDOFF-*.md)` and (for test runs) `Write(HANDOFF-stats-*.json)` in `permissions.allow`. The hook accepts the wildcard form, the exact session-suffixed form, or absolute-path variants of either.
- **Test mode** is gated on `/tmp/claude-cliff-test-cliff`. Real production fires never write `HANDOFF-stats-*.json` and never touch a banner-fired sentinel — those are harness-only artifacts.
- **Sentinels** under `/tmp/claude-cliff-{pid,sentinel,ready,stats,perm-requested,banner-fired}-${session_id}` are namespaced by session. `pid_file` and `sentinel_file` are written via tmp + `mv` for atomic replacement; on TERM/INT the trap removes them only if the sentinel still encodes our `${cliff_time}_${$$}` token (avoids racing a successor). Supersession is detected on PID-keyed token mismatch, which works even when consecutive Stops produce identical `cliff_time` (the common mid-session case).
- **Threshold gate** (`CACHE_CLIFF_MIN_TOKENS`, default 20 000) is bypassed in test mode by setting `total_m1h=999999` so the harness can run without a fully-loaded cache.
