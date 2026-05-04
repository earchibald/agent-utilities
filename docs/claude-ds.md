---
title: claude-ds — DeepSeek wrapper for Claude Code
description: Wrapper that runs the `claude` CLI against DeepSeek's Anthropic-compatible API, with pluggable secret-reference handling.
---

# `claude-ds`

Thin shell wrapper around the `claude` CLI that points it at DeepSeek's Anthropic-compatible endpoint. Lives at `wrappers/claude-ds/claude-ds`. Single file, no install step beyond putting it on `PATH`.

## What it does

1. Resolves a stored *reference* to a DeepSeek API key (1Password / OS keychain / Infisical / plaintext) using the [[secretref-lib]] block.
2. Exports `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, and a couple of compatibility flags that DeepSeek's endpoint needs.
3. `exec`s `claude` with all forwarded args.

The wrapper itself is small. Most of the file is the embedded [[secretref-lib]] block — that's the reusable bit, not specific to DeepSeek.

## Configuration

| | |
|---|---|
| Config file | `${XDG_CONFIG_HOME:-$HOME/.config}/claude-ds/config` (mode 0600) |
| Keys | `api_key_ref`, `base_url`, `model`, `model_opus`, `model_sonnet`, `model_haiku`, `model_small_fast`, `capabilities` |
| Defaults | `base_url=https://api.deepseek.com/anthropic`, `model=deepseek-v4-pro`, all `model_*` keys default to `model`, `capabilities` unset |
| Comments | Lines whose key starts with `#` are ignored. `write_config` writes the per-tier `model_*` keys and `capabilities` commented out by default — uncomment to override. |
| Keychain service | `claude-ds` (when using `system://` refs) |

## First run

On the first invocation (no config file present) the wrapper runs the [[secretref-lib]] interactive prompt:

```
Configure DeepSeek API key for claude-ds.

Enter a secret reference. Supported schemes:
  op://VAULT/ITEM/FIELD               1Password CLI ...
  system://<account>                  OS keychain ...
  infisical://PROJECT/ENV/PATH#KEY    Infisical CLI ...
  <key>                               Bare key (plaintext)
Reference:
```

For `system://<account>` references the prompt checks the OS keychain first: if an entry already exists under `service=claude-ds account=<acct>` it is reused without re-asking for the key. Otherwise the user is prompted for the key once and it is stored. Full details and reasoning live in [[secretref-lib]].

For `infisical://` references the wrapper assumes `infisical login` has been run or `INFISICAL_TOKEN` is exported in the environment. See [[infisical-adapter]] for the full adapter contract and troubleshooting.

## Flags

| Flag | Behaviour |
|---|---|
| `--reset-password` | Rotate the stored API key reference. For `system://` refs, the prompt asks: [1] change the key for the existing account (overwrite the keychain entry), or [2] switch to a different account/scheme — and on (2) asks whether to delete or keep the old keychain entry. For other schemes, forgets the local reference (upstream stores are never touched). |
| `--version`, `-V` | Prints the wrapper's version followed by `claude --version`. |
| `--help`, `-h` | Prints claude-ds-specific help (this doc, in compressed form), then appends `claude --help`. The combined output is routed through a pager: honours `$PAGER`, falls back to `less -RF`, then `more`, then `cat`. |
| _everything else_ | Forwarded to `claude` unchanged. |

### Input affordances

All visible prompts use readline editing (`read -e`) — left/right arrows, ctrl-a/e, backspace, ctrl-w all work as expected. Surrounding `'` or `"` quotes on entered references are stripped (so pasting `"system://"` from a shell-history line is fine).

**Scheme shorthand.** For the three URI schemes you may drop the `://` and type just `system`, `op`, or `infisical` — the wrapper appends `://` for you.

**`system://` is always interactive.** Any input matching `system://*` (typed suffix is ignored) drops into a numbered selector backed by the OS keychain — pick an existing entry under `service='claude-ds'` or create a new account. The chosen account is persisted as `system://<account>` in the config file. The keychain — not what the user types — is the source of truth for which accounts exist, so typos can't accidentally create new entries.

**`infisical://` has an interactive builder too.** Typing just `infisical://` (or `infisical`) drops into a walkthrough that prompts for project ID, env slug, folder path (default `/`), and secret key, and assembles a complete `infisical://PROJECT/ENV/PATH#KEY` URI. Or paste a complete URI directly — both work.

See [[secretref-lib]] (`secretref_select_account`, `secretref_build_infisical_ref`) for the underlying helpers.

### Output framing

Anything `claude-ds` writes (its `--help`, `--version`, log lines) is separated from the forwarded `claude` output by a blank line and a horizontal rule sized to the terminal width. Makes it easy to tell at a glance which tool produced which line.

## Environment variables set before exec

```
ANTHROPIC_BASE_URL                                          (from base_url; default DeepSeek endpoint)
ANTHROPIC_AUTH_TOKEN                                        (resolved from api_key_ref)
ANTHROPIC_MODEL                                             (from model; default deepseek-v4-pro)
ANTHROPIC_DEFAULT_OPUS_MODEL                                (from model_opus; defaults to model)
ANTHROPIC_DEFAULT_SONNET_MODEL                              (from model_sonnet; defaults to model)
ANTHROPIC_DEFAULT_HAIKU_MODEL                               (from model_haiku; defaults to model)
ANTHROPIC_SMALL_FAST_MODEL                                  (from model_small_fast; defaults to model)
ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES         (only when capabilities= is set)
ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES       (only when capabilities= is set)
ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES        (only when capabilities= is set)
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
CLAUDE_DISABLE_NONSTREAMING_FALLBACK=1
```

The two `CLAUDE_*` flags are required because DeepSeek's Anthropic-compat layer doesn't implement experimental beta headers or non-streaming fallback semantics.

**Why the four `*_MODEL` tier vars?** Claude Code's "auto" / `/model default` routing is what selects between Opus, Sonnet, and Haiku per task. When `ANTHROPIC_BASE_URL` points at a non-Anthropic gateway (DeepSeek, in this case), that routing is gated behind the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` env vars — without them, auto mode silently no-ops. DeepSeek is single-tier, so all four point at the same model by default; override individually via the `model_*` config keys if your gateway exposes more than one tier.

**`capabilities=`.** Comma-separated list, e.g. `effort,thinking,adaptive_thinking,interleaved_thinking`. When set, the matching `*_SUPPORTED_CAPABILITIES` env vars are exported for all three tiers so `claude` doesn't strip features it can't auto-detect on a non-canonical model ID. Leave unset for DeepSeek's vanilla compat shim — opt in only if your gateway actually implements the feature.

## Visual branding (tmux)

When `claude-ds` is launched inside tmux, it decorates the pane and window so a DeepSeek-backed claude can be told apart at a glance from a real Anthropic claude — useful when `unlock_auto_mode=1` is making the model id pretend to be `claude-opus-4-7`.

Three visible markers, in increasing reliability:

1. **Window-name 🐋 prefix** — `automatic-rename` is turned off and the window is renamed to `🐋 <original-name>`. Always shows in tmux's window list (status bar). Bypasses any terminal contrast quirks since emoji glyphs aren't color-styled by tmux. Restored on clean exit.
2. **Heavy indigo top-of-pane border** with a `🐋 DEEPSEEK · model: <real> · wire id: <spoofed>` badge. Renders only when your terminal supports tmux's `pane-border-status` (most modern terminals do).
3. **Color** is the DeepSeek brand `#4D6BFE` (electric indigo) — bold white text on a solid indigo badge for the label, indigo border lines for the rest.

Skip the entire decoration with `CLAUDE_DS_NO_BRANDING=1` (e.g. for headless `claude -p` calls where the border eats a row of pane height for nothing).

### Recommended tmux + iTerm setup for testing visual branding

If the pane-border badge looks washed-out or invisible, two things to check:

**1. Truecolor passthrough.** Without it, the indigo `#4D6BFE` falls back to whatever the nearest 256-color palette entry is and may collide with your border default. Add to `~/.tmux.conf`:

```tmux
set -g default-terminal "tmux-256color"
set -ga terminal-features ",xterm-256color:RGB"
set -ga terminal-features ",iTerm.app:RGB"
```

(Adjust the second matcher to whatever `$TERM` your terminal sets — `tmux display-message -p '#{client_termtype}'` shows the upstream terminal type.)

**2. iTerm2 minimum-contrast.** iTerm has a per-profile *Minimum Contrast* slider (Profiles → Colors). At anything above 0 it silently nudges fg/bg pairs apart for legibility, which can drift the indigo badge background toward your terminal background until it disappears. Drop it to 0 (or close to it) for the testing profile.

**3. Forward the tmux pane title to your terminal-window title bar** so the 🐋 marker is visible in the window list of macOS / your tab bar even when tmux is full-screen:

```tmux
# Allow tmux to set the terminal title
set-option -g set-titles on

# Set the window/tab title format
# #T = standard pane title
# #W = tmux window name (if you prefer what you set with `prefix + ,`)
# #S = tmux session name
set-option -g set-titles-string '#T'
```

Use `#W` instead of `#T` if you want claude-ds's `🐋` window-name prefix to land in the terminal's title bar (which is usually what you want for a "tag the whole window" effect — `#T` shows the pane's program-set title, which claude doesn't customize).

## Troubleshooting

- **"failed to resolve API key from \<ref\>"** — the resolver failed. Check the per-scheme requirements in [[secretref-lib]]; for `infisical://` specifically, walk the checklist in [[infisical-adapter]].
- **Want to switch from one secret store to another** — run `claude-ds --reset-password`. The reset is loud and explicit so you can confirm exactly what's being cleared.
- **Wrong model or base URL** — edit the config file directly; the wrapper just reads `key=value` lines.

## Related docs

- [[secretref-lib]] — the reusable secret-reference library this wrapper consumes
- [[infisical-adapter]] — deep dive on the `infisical://` adapter
- [[CHANGELOG]] — change history
