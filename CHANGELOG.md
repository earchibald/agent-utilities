# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Permission auto-detection in `cache-cliff-handoff.sh`: when `Write(HANDOFF.md)` or `Write(HANDOFF-stats.json)` is missing from `~/.claude/settings.json` (global) or `.claude/settings.json` (project), the rewake prompt instructs the model to add it. `cache-cliff-warn.sh` reads a perm-request sentinel and reports add/fail status in the banner.
- Token-delta tracking: handoff.sh snapshots cumulative input/output tokens before exit; warn.sh diffs against the post-generation transcript and reports `HANDOFF.md generation cost: X in / Y out` in the banner.
- Test mode via `/tmp/claude-cliff-test-cliff` (epoch file) — both hooks use it to bypass transcript parsing and the 20000-token threshold gate. Test mode also writes `HANDOFF-stats.json` to CWD and touches a banner-fired sentinel for harness consumption.
- Word-budget hint in rewake prompt: "Be concise. Target under 800 words." (closes #2).
- `docs/testing-protocol.md` — documents the test flag, loop harness, `HANDOFF-stats.json` schema, and tuning guidance.
- `claude/hooks/cache-cliff-handoff.sh` — asyncRewake Stop hook that sleeps until 2 minutes before the 1h cache cliff, then exits 2 to wake the model and instruct it to write a directive `HANDOFF.md` in the agent CWD. Gated by `CACHE_CLIFF_MIN_TOKENS` (default 20000). Touches a ready-sentinel (`/tmp/claude-cliff-handoff-ready-$session_id`) before `exit 2` so the warn hook knows generation is complete.
- `docs/handoff-methodology.md` — describes the asyncRewake pattern, two-hook architecture, and sentinel bridge used by the cache-cliff system.

### Changed

- `claude/hooks/cache-cliff-warn.sh` — rewritten to use the two-hook architecture. Now fires a pre-cliff `systemMessage` banner (2 minutes before expiry) instead of a post-cliff "session is dead" message. Checks for the ready-sentinel before showing the banner; deletes it after firing to prevent re-triggering.
- Warn timer changed from 60 s to 120 s before cliff (`cliff_time - 120`).
- Banner text updated: no longer says "session is dead" or instructs `/compact`; instead informs the user that `HANDOFF.md` is ready and suggests `/clear` or `/quit`.
- HANDOFF.md is now written to the agent's CWD (`cwd` from Stop hook stdin) rather than `~/.claude/`.
- **Per-session handoff artifacts**: `HANDOFF.md` → `HANDOFF-${session_id:0:8}.md`; in test mode, `HANDOFF-stats.json` → `HANDOFF-stats-${session_id:0:8}.json`. Multiple Claude sessions on the same project no longer overwrite each other's handoff. Permission patterns are now wildcards (`Write(HANDOFF-*.md)` and `Write(HANDOFF-stats-*.json)`) — add once, covers every session. The banner already prints the absolute path, so users always know which file goes with which session. Closes the two-session CWD race (issue #3, B#5).
- Atomic pid_file/sentinel replacement via tmp + `mv` so concurrent Stops cannot observe a half-written or rm'd state. Predecessor's PID is read before the swap; kill happens after our registration is committed (issue #3, A#2).
- TERM/INT trap now removes pid_file and sentinel_file (only if the sentinel still encodes our token, to avoid racing a successor) so Claude Code timeout / session exit doesn't leak `/tmp` files (issue #3, B#9).

### Fixed

- Migrated from a manually-backgrounded subshell to Claude Code's `asyncRewake: true` Stop-hook flag: the hook runs in the foreground of an async-spawned process, eliminating the need for `&` + `disown` and removing a class of inherited-fd hang bugs.
- Supersession sentinel now encodes both `cliff_time` and the owning PID (`${cliff_time}_${$$}`). Previously, when consecutive Stops produced the same `cliff_time` (the common case mid-session) the supersession check was a no-op and duplicate suppression silently relied on the `kill` of the predecessor — making the redundancy in the design illusory. PID-keyed tokens make the check load-bearing.
- Permission check in both hooks anchors to `Write(<file>)` exactly (`. == "Write(" + $f + ")"` plus an `endswith("/" + $f + ")")` clause for absolute-path forms) instead of plain substring `contains($f)`. The previous regex `test($p)` with `${pattern//./\\\\.}` escaping caused false "could not add" reports (double-escape); a plain `contains()` fix replaced it but matched too liberally — `Read(HANDOFF.md)` or `Bash(echo HANDOFF.md)` would falsely satisfy the check. Now anchored.
- Permission auto-add prompt softened: primary instruction is to tell the user to add manually; the model only attempts the edit if it already has Edit permission for the settings file, since asking at cliff−120 would stall the cache window.
- Timestamp parser in both hooks now handles non-`Z` timezone offsets: switched from `sub("\\.[0-9]+Z$"; "Z")` (only matched fractional + literal `Z`) to `try (… sub("\\.[0-9]+"; "") | fromdateiso8601) catch 0`. A single malformed entry no longer takes down the whole jq pipeline.
- 1h-window filter changed from `ts > ($now - 3600)` to `ts >= ($now - 3600)` — the cliff edge itself is now correctly included.
- `cache-cliff-warn.sh` now defaults `snap_in`/`snap_out`/`cur_in`/`cur_out` to 0 before arithmetic — protects the banner against an empty stats snapshot file produced by a failed jq.
- `cache-cliff-warn.sh` cleans up an orphaned `ready-sentinel` (and its companion `stats` / `perm-requested` sentinels) when the cliff has already passed — prevents a stale token count or perm-request from a prior cycle from feeding a future banner.
- `session_id` is sanitized (`tr -cd 'A-Za-z0-9._-' | head -c 64`) before interpolation into `/tmp` paths in both hooks.
- Tight re-fire loop guard in `cache-cliff-handoff.sh`: when `delay≤0` and the ready-sentinel exists, exit immediately to prevent a re-fire spiral on Stop events past `warn_time`.
- `systemMessage` JSON construction switched from `printf` (which embedded literal `\n` characters into JSON string values, producing invalid JSON that Claude Code silently discarded) to `jq -n --arg m "$msg" '{"systemMessage": $m}'`.

### Removed

- macOS `osascript` notification and terminal bell on cache cliff — UI banner via `systemMessage` is sufficient.
- Post-cliff "💀 session is dead" banner — replaced with pre-cliff warning so the user can act before losing the cache.

[Unreleased]: https://github.com/earchibald/agent-utilities/compare/HEAD...HEAD
