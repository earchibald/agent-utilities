---
title: secretref — reusable bash secret-reference library
description: Drop-in bash module for resolving op://, system://, infisical:// URIs and prompting users on first run.
---

# `secretref` library

A self-contained bash module that lets a wrapper script accept secrets via a small set of URI schemes, without each wrapper re-implementing 1Password / OS-keychain / Infisical handling.

Currently lives inline in [[wrappers/claude-ds]] between the `BEGIN secretref` and `END secretref` markers. The block is intentionally copy-pasteable — no `source`-able file (yet); just lift the marked region.

## What it provides

| Function | Purpose |
|---|---|
| `secretref_resolve <ref>` | Resolve a reference to its secret value on stdout. Main entry point. |
| `secretref_prompt <label>` | Interactive first-run prompt: asks the user for a reference, transparently handles `system://` keychain reuse-vs-store. Echoes the chosen ref. |
| `secretref_help_text` | Prints the supported-schemes block (suitable for embedding in a wrapper's `--help`). |
| `secretref_reset_local <old_ref>` | On `--reset-password`, deletes any local secret tied to the old ref (only `system://` has one) and logs what happened. |
| `secretref_keychain_{store,lookup,delete}` | Lower-level keychain ops, used by the higher-level functions. Exposed for wrappers that need direct access. |

All public functions write secrets / refs to stdout and prompts / diagnostics to stderr — same convention as `op read`.

## Supported schemes

| Scheme | Source | Requirements |
|---|---|---|
| `op://VAULT/ITEM/FIELD` | 1Password CLI | `op` on `PATH`, signed in via `op signin` |
| `system://<account>` | OS keychain — macOS `security`, Linux `secret-tool` | `security` (Darwin) or `libsecret-tools` (Linux); service name comes from `SECRETREF_KEYCHAIN_SERVICE` |
| `infisical://PROJECT/ENV/PATH#KEY` | Infisical CLI | `infisical` on `PATH`; either `infisical login` once or `INFISICAL_TOKEN` exported. See [[infisical-adapter]] for the adapter's full contract and troubleshooting |
| _bare key_ | plaintext fallback | none — anything unrecognised is returned verbatim |

## How to use it in a new wrapper

1. Copy the `BEGIN secretref … END secretref` block from `wrappers/claude-ds` verbatim.
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

   # Reset
   secretref_reset_local "$old_ref"

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
