---
title: claude-ds — DeepSeek wrapper for Claude Code
description: Wrapper that runs the `claude` CLI against DeepSeek's Anthropic-compatible API, with pluggable secret-reference handling.
---

# `claude-ds`

Thin shell wrapper around the `claude` CLI that points it at DeepSeek's Anthropic-compatible endpoint. Lives at `wrappers/claude-ds`. Single file, no install step beyond putting it on `PATH`.

## What it does

1. Resolves a stored *reference* to a DeepSeek API key (1Password / OS keychain / Infisical / plaintext) using the [[secretref-lib]] block.
2. Exports `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, and a couple of compatibility flags that DeepSeek's endpoint needs.
3. `exec`s `claude` with all forwarded args.

The wrapper itself is small. Most of the file is the embedded [[secretref-lib]] block — that's the reusable bit, not specific to DeepSeek.

## Configuration

| | |
|---|---|
| Config file | `${XDG_CONFIG_HOME:-$HOME/.config}/claude-ds/config` (mode 0600) |
| Keys | `api_key_ref`, `model`, `base_url` |
| Defaults | `model=deepseek-v4-pro`, `base_url=https://api.deepseek.com/anthropic` |
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
| `--reset-password` | Clears the stored reference and any associated local secret (i.e. the `system://` keychain entry, if used). Logs every removal explicitly: config-file path, keychain service+account. Does **not** touch upstream stores like 1Password or Infisical — only the local reference and local-only secrets. Re-runs the first-run prompt afterwards. |
| `--help`, `-h` | Prints claude-ds-specific help (this doc, in compressed form), then appends `claude --help`. The combined output is routed through a pager: honours `$PAGER`, falls back to `less -RF`, then `more`, then `cat`. |
| _everything else_ | Forwarded to `claude` unchanged. |

## Environment variables set before exec

```
ANTHROPIC_BASE_URL                       (from base_url config; default DeepSeek endpoint)
ANTHROPIC_AUTH_TOKEN                     (resolved from api_key_ref)
ANTHROPIC_MODEL                          (from model config; default deepseek-v4-pro)
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
CLAUDE_DISABLE_NONSTREAMING_FALLBACK=1
```

The two `CLAUDE_*` flags are required because DeepSeek's Anthropic-compat layer doesn't implement experimental beta headers or non-streaming fallback semantics.

## Troubleshooting

- **"failed to resolve API key from \<ref\>"** — the resolver failed. Check the per-scheme requirements in [[secretref-lib]]; for `infisical://` specifically, walk the checklist in [[infisical-adapter]].
- **Want to switch from one secret store to another** — run `claude-ds --reset-password`. The reset is loud and explicit so you can confirm exactly what's being cleared.
- **Wrong model or base URL** — edit the config file directly; the wrapper just reads `key=value` lines.

## Related docs

- [[secretref-lib]] — the reusable secret-reference library this wrapper consumes
- [[infisical-adapter]] — deep dive on the `infisical://` adapter
- [[CHANGELOG]] — change history
