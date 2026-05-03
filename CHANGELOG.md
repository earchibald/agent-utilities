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

### Fixed

- Redirect background subshell to `/dev/null` before `&` so Claude Code's hook runner does not wait on inherited stdout/stderr (caused Stop hooks to hang for the full sleep duration).
- `kill $old_pid` only killed the bash wrapper, leaving the `sleep` child orphaned and accumulating across Stop events. Now uses `pkill -P $old_pid` to kill the sleep child before killing the wrapper.
- Added a sentinel file (`/tmp/claude-cliff-sentinel-$session_id`) keyed to `cliff_time`: stale timers that survive the kill check the sentinel on wake and exit harmlessly if it no longer matches.
- Permission check in both hooks now uses `jq … contains($f)` with plain filenames instead of `test($p)` with regex-escaped patterns — eliminates a double-escape bug that caused false "could not add" reports and spurious re-add instructions for already-present permissions.
- Tight re-fire loop guard in `cache-cliff-handoff.sh`: when `delay≤0` and the ready-sentinel exists, exit immediately to prevent a re-fire spiral on Stop events past `warn_time`.
- `systemMessage` JSON construction switched from `printf` (which embedded literal `\n` characters into JSON string values, producing invalid JSON that Claude Code silently discarded) to `jq -n --arg m "$msg" '{"systemMessage": $m}'`.

### Removed

- macOS `osascript` notification and terminal bell on cache cliff — UI banner via `systemMessage` is sufficient.
- Post-cliff "💀 session is dead" banner — replaced with pre-cliff warning so the user can act before losing the cache.

[Unreleased]: https://github.com/earchibald/agent-utilities/compare/HEAD...HEAD
