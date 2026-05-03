---
title: secretref — reusable bash secret-reference library
description: Drop-in bash module for resolving op://, system://, infisical:// URIs and prompting users on first run.
---

# `secretref` library

A self-contained bash module that lets a wrapper script accept secrets via a small set of URI schemes, without each wrapper re-implementing 1Password / OS-keychain / Infisical handling.

Currently lives inline in [[wrappers/claude-ds/claude-ds]] between the `BEGIN secretref` and `END secretref` markers. The block is intentionally copy-pasteable — no `source`-able file (yet); just lift the marked region.

## What it provides

| Function | Purpose |
|---|---|
| `secretref_resolve <ref>` | Resolve a reference to its secret value on stdout. Main entry point. |
| `secretref_prompt <label>` | Interactive first-run prompt: asks the user for a reference. For `system://` (any input starting with that scheme — trailing account suffixes are ignored), unconditionally runs `secretref_select_account` and persists the result as `system://<chosen-account>`. Strips surrounding `'`/`"` quotes from input. Uses `read -e` so visible prompts support readline editing (arrow keys, ctrl-a/e, backspace, etc.). Echoes the chosen ref. |
| `secretref_reset_interactive <old_ref> [<label>]` | `--reset-password` flow. If `old_ref` is `system://<acct>`, prompts: [1] change the key for `<acct>` (overwrite the keychain entry), or [2] switch to a different account/scheme — and on (2) asks whether to delete or keep the old keychain entry before re-prompting. For non-system refs, just calls `secretref_reset_local` and re-prompts. Echoes the new ref. |
| `secretref_reset_local <old_ref>` | Lower-level non-interactive reset: deletes the local secret tied to `old_ref` (only `system://` has one) and logs. Used internally by `secretref_reset_interactive` when no interaction is needed. |
| `secretref_select_account` | Lists existing accounts under `SECRETREF_KEYCHAIN_SERVICE` and lets the user pick by number, type 'n' for a new name, or type a free-form name. Echoes the chosen account. |
| `secretref_keychain_list_accounts` | Enumerates account names already stored under `SECRETREF_KEYCHAIN_SERVICE` (one per line, sorted, unique). macOS: parses `security dump-keychain` (may trigger one keychain-access prompt). Linux: uses `secret-tool search --all`. |
| `secretref_help_text` | Prints the supported-schemes block (suitable for embedding in a wrapper's `--help`). |
| `secretref_build_infisical_ref` | Interactive walkthrough that prompts for project ID, env slug, folder path, and secret key, then constructs an `infisical://PROJECT/ENV/PATH#KEY` URI. Triggered automatically when the user enters a bare `infisical://` (or just `infisical`) at the `secretref_prompt`. |
| `_secretref_canonicalize_scheme` | Internal helper. Lets users type just `system`, `op`, or `infisical` (no `://`) and have it expanded to `system://` etc. Anything else passes through. |
| `secretref_keychain_{store,lookup,delete}` | Lower-level keychain ops, used by the higher-level functions. Exposed for wrappers that need direct access. |

All public functions write secrets / refs to stdout and prompts / diagnostics to stderr — same convention as `op read`.

## Supported schemes

| Scheme | Source | Requirements |
|---|---|---|
| `op://VAULT/ITEM/FIELD` | 1Password CLI | `op` on `PATH`, signed in via `op signin` |
| `system://` | OS keychain — macOS `security`, Linux `secret-tool` | `security` (Darwin) or `libsecret-tools` (Linux); service name comes from `SECRETREF_KEYCHAIN_SERVICE`. Always entered as just `system://` — `secretref_prompt` runs `secretref_select_account` to pick an existing entry or create a new one. The persisted form (in the consumer's config) is `system://<account>`. |
| `infisical://PROJECT/ENV/PATH#KEY` | Infisical CLI | `infisical` on `PATH`; either `infisical login` once or `INFISICAL_TOKEN` exported. Type just `infisical://` (or `infisical`) to get an interactive walkthrough. See [[infisical-adapter]] for the adapter's full contract and troubleshooting |
| _bare key_ | plaintext fallback | none — anything unrecognised is returned verbatim |

**Shorthand:** for `system`, `op`, and `infisical` you may omit the `://` — the lib expands `system` → `system://`, etc. So typing just `infisical` is equivalent to `infisical://` and triggers the interactive builder.

## How to use it in a new wrapper

1. Copy the `BEGIN secretref … END secretref` block from `wrappers/claude-ds/claude-ds` verbatim.
2. **Before** the block, set:
   ```bash
   SECRETREF_KEYCHAIN_SERVICE="my-wrapper"   # required for system://
   SECRETREF_LOG_PREFIX="my-wrapper"         # optional; defaults to "secretref"
   ```
3. Use the functions:
   ```bash
   # First run / config
   ref=$(secretref_prompt "API key for my-wrapper")
   echo "api_key_ref=$ref" > "$CONFIG_FILE"

   # Resolve at runtime
   token=$(secretref_resolve "$ref")

   # --reset-password (interactive change-or-switch flow)
   new_ref=$(secretref_reset_interactive "$old_ref" "API key for my-wrapper")

   # In your --help text, embed:
   secretref_help_text
   ```

That's it. The lib does not allocate config files or dictate where the chosen reference is persisted — that's the wrapper's job.

## Adding a new scheme

1. Add a `case "$ref" in <newscheme>://*) … ;;` branch inside `secretref_resolve`.
2. Mirror the entry in `secretref_help_text` so consumers' `--help` output stays accurate.
3. Update this doc and any per-scheme adapter doc (e.g. [[infisical-adapter]]) describing the URI grammar, auth requirements, and troubleshooting steps.

## Why a copy-paste block instead of a sourced file

- Wrappers should be single-file artefacts the user can `curl > ~/bin/foo && chmod +x` without worrying about a search path for a sibling library.
- The lib is small (~150 lines). Drift between copies is acceptable in exchange for zero install-time dependencies.
- If/when there are 3+ wrappers using it, promoting it to `wrappers/lib/secretref.sh` and `source`-ing it is a small refactor.

## See also

- [[claude-ds]] — the first consumer, and the canonical reference implementation
- [[infisical-adapter]] — deeper docs for the `infisical://` adapter specifically
- [[CHANGELOG]] — when each scheme landed
