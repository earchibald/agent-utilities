# agent-utilities

Claude Code hooks and utilities for session management.

## Project layout

```
claude/hooks/   Shell scripts wired into ~/.claude/settings.json as Stop/other hooks
index.md        Obsidian-friendly index with wikilinks to each hook
CHANGELOG.md    Per-release changelog (Keep a Changelog format)
```

## Changelog maintenance

**Update `CHANGELOG.md` whenever you add, change, or remove a hook or utility.**

- Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) conventions exactly:
  - New entries go under `## [Unreleased]`
  - Use `### Added`, `### Changed`, `### Fixed`, `### Removed` subsections
  - One bullet per logical change; be specific about file path and behaviour
- When tagging a release: rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD` and add a fresh empty `[Unreleased]` section above it
- The compare link at the bottom should point to the real GitHub diff once a remote is set

## Hook development notes

- Hooks receive JSON on stdin; parse with `jq -r '.field // empty'`
- A `systemMessage` key in stdout JSON shows a banner to the user without touching model context
- `disown $!` after a background subshell detaches it from the hook's process group so it survives the hook exiting
- Test with: `echo '{"session_id":"test","transcript_path":"<path>"}' | ./claude/hooks/<hook>.sh`
- Wiring lives in `~/.claude/settings.json` (global user settings), not checked into this repo
