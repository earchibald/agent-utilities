# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `claude/hooks/cache-cliff-warn.sh` — Stop hook that schedules a background timer 60 seconds before the session's active 1h prompt-cache cliff. When the timer trips it writes `~/.claude/HANDOFF.md` with continuation instructions. After the cliff passes, each Stop event emits a `systemMessage` banner in the Claude Code UI (not injected into model context).

### Fixed

- Redirect background subshell to `/dev/null` before `&` so Claude Code's hook runner does not wait on inherited stdout/stderr (caused Stop hooks to hang for the full sleep duration).

### Removed

- macOS `osascript` notification and terminal bell on cache cliff — UI banner via `systemMessage` is sufficient.

[Unreleased]: https://github.com/earchibald/agent-utilities/compare/HEAD...HEAD
