# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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

### Removed

- macOS `osascript` notification and terminal bell on cache cliff — UI banner via `systemMessage` is sufficient.
- Post-cliff "💀 session is dead" banner — replaced with pre-cliff warning so the user can act before losing the cache.

[Unreleased]: https://github.com/earchibald/agent-utilities/compare/HEAD...HEAD
