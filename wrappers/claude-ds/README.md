# claude-ds

> Run [Claude Code](https://docs.anthropic.com/claude/code) against
> [DeepSeek](https://www.deepseek.com)'s Anthropic-compatible API — with
> system-keychain / 1Password / Infisical secret refs, schema-versioned
> config that auto-migrates and auto-repairs, lazy-installed sidecar
> proxy, end-to-end `--doctor` diagnostics, and per-tier reasoning
> controls when you want them.

`claude-ds` is a small Bash wrapper plus an optional Python sidecar. It
exists because pointing Claude Code at a third-party Anthropic-compatible
endpoint is a tangle of environment variables, model-id gates, schema
drift, and an incompatible reasoning-depth wire format. `claude-ds`
makes that one command:

```bash
claude-ds
```

The wrapper takes care of:

- prompting for and storing your secret reference on first run
- testing your API key against DeepSeek before saving
- migrating older config files forward when the schema changes
- detecting and auto-repairing damaged configs (with a backup so nothing is lost)
- lazy-installing the optional reasoning-effort proxy if and when you opt in
- gracefully falling back when an optional dependency (python3, curl) is missing

If something does go wrong, `claude-ds --doctor` runs an end-to-end
checklist and tells you exactly what to fix.

---

## Table of contents

- [Why use this](#why-use-this)
- [Quickstart](#quickstart)
- [Installation](#installation)
- [What the wrapper does for you](#what-the-wrapper-does-for-you) — the important section if you'd rather not read the rest
- [Configuration](#configuration) — start here if you don't know what to set
- [Secret references](#secret-references)
- [Reasoning-effort proxy](#reasoning-effort-proxy)
  - [Per-tier collisions](#per-tier-collisions)
- [Auto-mode unlock](#auto-mode-unlock)
- [Per-tier model overrides](#per-tier-model-overrides)
- [Visual branding (tmux)](#visual-branding-tmux)
- [Environment variables](#environment-variables)
- [Troubleshooting](#troubleshooting)
- [Developer notes](#developer-notes)
- [License](#license)

---

## Why use this

| Problem | What `claude-ds` does |
|---|---|
| Setting `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` by hand on every shell session | Persists a single config file under `$XDG_CONFIG_HOME/claude-ds/`. |
| Hard-coding API keys in shell rc files or `.env` | Stores a *reference* (`op://`, `system://`, `infisical://`, …) and resolves it on each run. Plaintext is supported but never required. |
| Claude Code's auto-mode (`--auto` permission classifier) refuses to run on non-Anthropic models | Optional `unlock_auto_mode` flag spoofs the wire-level model id so the gate passes. |
| `/model default` and tier routing break against single-tier providers | All four tiers (opus / sonnet / haiku / small_fast) are pinned to the configured model by default; per-tier overrides are available. |
| DeepSeek doesn't honor Anthropic's `thinking.budget_tokens`; Claude Code can't send `reasoning_effort` | A local Python proxy translates between the two — `think hard` → `medium`, `ultrathink` → `high`, etc. — fully configurable, off by `proxy_effort=off`. |
| Hard to tell at a glance which terminal is talking to DeepSeek vs. real Anthropic | When run inside tmux, the active pane gets a DeepSeek-themed top border and the window name is prefixed `🐋`. |
| Config schema changes between releases | Schema-versioned (`_schema=N`); old configs are auto-migrated forward with a `.v<old>.bak` backup. |
| Hand-edited config got broken | `claude-ds` detects malformed lines on launch, backs up the original to `config.broken.<timestamp>.bak`, and rewrites a clean config preserving every parseable key. |
| "Did I install everything correctly?" | `claude-ds --doctor` checks claude on PATH, python3, proxy script presence, secret-ref resolves, API key live against upstream, and tier-collision lint — printing ✓/✗ with actionable next steps. |

---

## Quickstart

```bash
# 1. Install (see Installation below for alternatives).
mkdir -p ~/.local/bin
curl -fL https://raw.githubusercontent.com/earchibald/agent-utilities/main/wrappers/claude-ds/claude-ds         -o ~/.local/bin/claude-ds
curl -fL https://raw.githubusercontent.com/earchibald/agent-utilities/main/wrappers/claude-ds/claude-ds-proxy.py -o ~/.local/bin/claude-ds-proxy.py
chmod +x ~/.local/bin/claude-ds

# 2. First run interactively walks you through:
#    - secret reference (paste a key directly, or use `system://`,
#      `op://`, `infisical://` — see Secret references below)
#    - liveness check against DeepSeek (catches typo'd keys before you save)
#    - reasoning-effort proxy opt-in (default: off; most users don't need it)
claude-ds

# 3. That's it. Useful follow-ups:
claude-ds --doctor       # end-to-end checklist if anything seems wrong
claude-ds --rotate-key   # rotate the stored API key (alias of --reset-password)
```

> 💡 **The proxy script doesn't need `chmod +x`** — the wrapper invokes it
> as `python3 claude-ds-proxy.py`. Only `claude-ds` itself must be
> executable.
>
> 💡 **Symlinking is supported.** `claude-ds` resolves its own symlinks
> before locating the proxy script, so `ln -s ~/src/agent-utilities/wrappers/claude-ds/claude-ds ~/.local/bin/claude-ds`
> works — the proxy is found in the source tree without a second symlink.
> The two files must be siblings *on the real filesystem*, not in
> `~/.local/bin`.
>
> ⚠️ **Your API key lives in the process environment at runtime.**
> Whichever secret reference scheme you use, the resolved key is exported
> as `ANTHROPIC_AUTH_TOKEN` to `claude` and to every process `claude`
> spawns (MCP servers, shell tools, subprocesses). If your threat model
> includes untrusted MCP servers or tool output, treat the key as
> ephemeral and rotate regularly. The on-disk config is `chmod 600`, but
> at-rest protection does not extend to the running process tree.

---

## Installation

### Requirements

| | Required for |
|---|---|
| Bash 4+ | the wrapper itself (macOS ships 3.2 — install `bash` via Homebrew, or run with the `/bin/bash` your distro provides) |
| `claude` CLI on `$PATH` | obvious |
| Python 3.8+ | only when the reasoning-effort proxy is enabled (the default — set `proxy_effort=off` to skip) |
| `op` CLI | only for `op://` secret references |
| `infisical` CLI | only for `infisical://` secret references |
| `secret-tool` (Linux, libsecret) | only for `system://` references on Linux. macOS uses the built-in `security` command. |

### Manual install

```bash
mkdir -p ~/.local/bin
cp wrappers/claude-ds/claude-ds          ~/.local/bin/claude-ds
cp wrappers/claude-ds/claude-ds-proxy.py ~/.local/bin/claude-ds-proxy.py
chmod +x ~/.local/bin/claude-ds
# Both files must share a directory — the wrapper resolves
# `claude-ds-proxy.py` from the directory of its own real path.
```

Make sure `~/.local/bin` is on `$PATH`.

### From this repo (development checkout)

```bash
git clone https://github.com/earchibald/agent-utilities.git
ln -s "$PWD/agent-utilities/wrappers/claude-ds/claude-ds" ~/.local/bin/claude-ds
# The proxy does NOT need to be symlinked separately — the wrapper
# canonicalises its own path with a portable readlink loop, so
# `dirname(realpath(claude-ds))` lands in the source tree where the proxy
# already lives.
```

### Verifying

```bash
claude-ds --version    # `claude-ds X.Y.Z`, a horizontal rule, then `claude --version`.
                       # For machine parsing: `claude-ds --version | head -1`.
claude-ds --help       # full help, paged through $PAGER (falls back to less / more / cat)
claude-ds --doctor     # end-to-end checklist (claude on PATH, python3, proxy script,
                       # secret-ref resolves, API key live, tier collisions)
```

---

## What the wrapper does for you

You should rarely need to read this README beyond the Quickstart.
`claude-ds` is designed to do its own onboarding, maintenance, and
self-healing:

| Situation | What `claude-ds` does automatically |
|---|---|
| **Fresh install, no config** | Interactively prompts for a secret reference (with helpers for `system://` and `infisical://`), liveness-checks the resulting API key against DeepSeek, and offers an opt-in for the reasoning-effort proxy. |
| **Old config from a previous version** | Detects the schema version, backs up the original to `config.v<old>.bak`, and migrates forward in place. |
| **Damaged config** (typo, hand-edit gone wrong) | Detects malformed lines on launch, backs up the original to `config.broken.<timestamp>.bak`, drops the bad lines with a named warning, preserves every parseable key, and continues. Nothing is lost. |
| **Missing proxy script** | If the proxy is enabled, attempts a one-time `curl` from `raw.githubusercontent.com` next to the wrapper. On success, runs normally. On failure, soft-falls-back to proxy-disabled for the session and warns — the config is never mutated. |
| **Missing python3** | Soft-fall-back to proxy-disabled for the session, with a single warning telling you what to install. The wrapper still launches `claude` normally. |
| **Missing curl** | Same soft-fallback, with a different warning. |
| **Bad API key** | First-run prompt re-asks (up to 3 times). Subsequent launches surface the failure via `--doctor`. |
| **Symlinked install** | The wrapper resolves its own symlinks before locating the proxy script — so `ln -s ~/src/agent-utilities/wrappers/claude-ds/claude-ds ~/.local/bin/claude-ds` Just Works. |
| **Per-tier proxy specs that would silently collide** | Linted on every launch; warns the moment two tiers map to the same wire id and tells you which tier wins. |
| **API key rotation** | `claude-ds --rotate-key` (or `--reset-password`) — interactive, liveness-checked, preserves your `proxy_effort` choice across rotation. |
| **Anything else seems wrong** | `claude-ds --doctor` walks the full checklist with ✓/✗ and an actionable next step on each failure. |

The rest of this README is reference material. If you only ever read the
sections above, you should be fine.

---

## Configuration

`claude-ds` reads a single config file:

```
${XDG_CONFIG_HOME:-$HOME/.config}/claude-ds/config
```

The file is created on first run with safe defaults and `chmod 600`. It uses
`key=value` pairs, one per line. Lines beginning with `#` and blank lines are
ignored — comment a key out to fall back to its built-in default.

### Start here: pick a scenario

Most users want one of these. Copy, adjust the secret reference, save to
`~/.config/claude-ds/config`, run `claude-ds`. Done.

**A. "Just give me Claude Code on DeepSeek." (the default)**

```ini
_schema=1
api_key_ref=op://Private/DeepSeek/credential
base_url=https://api.deepseek.com/anthropic
model=deepseek-v4-pro
proxy_effort=off
```

DeepSeek's compat shim already maps claude's `/think`, `/think-hard`,
and `/ultrathink` commands to its native reasoning regime (`high`, or
`max` for ultrathink-tier budgets). The proxy is **off by default** — no
sidecar process is spawned, and claude talks to DeepSeek directly.

**B. "I want auto-mode (`--auto` permission classifier) to work."**

```ini
_schema=1
api_key_ref=op://Private/DeepSeek/credential
base_url=https://api.deepseek.com/anthropic
model=deepseek-v4-pro
unlock_auto_mode=1
capabilities=effort,thinking
proxy_effort=off
```

Spoofs Claude-canonical model ids so the auto-mode gate passes, and
advertises `effort` / `thinking` capabilities so `claude` doesn't strip
them on the way out.

**C. "I want to force a specific reasoning regime regardless of what claude asks for."**

This is when you opt into the proxy. For example, "always reason at max
on opus, default behaviour everywhere else":

```ini
_schema=1
api_key_ref=op://Private/DeepSeek/credential
unlock_auto_mode=1
proxy_effort=off            # don't change behaviour for sonnet/haiku/small_fast
proxy_effort_opus=max       # always reason at max on the opus tier
```

Or "always at least default reasoning, even on routine requests":

```ini
proxy_effort=auto:high
```

Or "save tokens by never reasoning":

```ini
proxy_effort=none
```

> ⚠️ Per-tier specs key on the *wire-level* model id, not the tier name.
> Read the [tier-collision rules](#per-tier-collisions) before mixing
> per-tier specs — collisions matter most when `unlock_auto_mode` is
> *off* (all tiers share one wire id) or when `unlock_auto_mode=1` makes
> haiku and small_fast both map to `claude-haiku-4-5`. `claude-ds` lints
> for collisions on launch and prints a warning naming the colliding
> tiers.

### Full config reference

Keys in **bold** change behaviour on every run. The rest are debugging or
advanced overrides.

| Key | Default | Purpose |
|---|---|---|
| `_schema` | `1` | Config schema version. The wrapper migrates older versions forward on launch (with a `.v<old>.bak` backup). |
| **`api_key_ref`** | *(set on first run)* | Secret reference for the DeepSeek API key. See [Secret references](#secret-references). |
| **`base_url`** | `https://api.deepseek.com/anthropic` | Upstream Anthropic-compat endpoint. Override to point at a different gateway. |
| **`model`** | `deepseek-v4-pro` | Default DeepSeek model id sent over the wire. |
| `model_opus` | *(unset → uses `model`)* | Override wire-level model for the opus tier. |
| `model_sonnet` | *(unset → uses `model`)* | Override wire-level model for the sonnet tier. |
| `model_haiku` | *(unset → uses `model`)* | Override wire-level model for the haiku tier. |
| `model_small_fast` | *(unset → uses `model`)* | Override wire-level model for the small-fast tier. |
| `capabilities` | *(unset)* | Comma-separated capability list advertised to `claude` per tier. e.g. `effort,thinking,adaptive_thinking,interleaved_thinking`. Set only when the upstream gateway actually supports them. |
| **`unlock_auto_mode`** | *(unset)* | When `1`, spoofs Claude-canonical model ids to satisfy auto-mode's regex gate. See [Auto-mode unlock](#auto-mode-unlock). |
| **`proxy_effort`** | `off` | Global default for the [reasoning-effort proxy](#reasoning-effort-proxy). Spec language documented there. The proxy is opt-in — `off` means the wrapper never spawns the Python child. |
| `proxy_effort_opus` | *(unset)* | Per-tier override for opus. **Subject to wire-id collision** — see [Per-tier collisions](#per-tier-collisions). |
| `proxy_effort_sonnet` | *(unset)* | Per-tier override for sonnet. Subject to collision. |
| `proxy_effort_haiku` | *(unset)* | Per-tier override for haiku. Subject to collision. |
| `proxy_effort_small_fast` | *(unset)* | Per-tier override for the small-fast tier. Subject to collision. |
| `proxy_bind` | `127.0.0.1` | Interface the proxy listens on. Leave at loopback unless you have a specific reason. |
| `proxy_debug` | `0` | When `1`, logs every regime application to stderr. |

> 📝 The deprecated `proxy_strip_thinking` key (v0.5) is silently
> ignored — strip/preserve behaviour is now baked into the regime model
> (`none` strips, `high`/`max` preserve).

---

## Secret references

`api_key_ref` accepts one of four schemes:

| Scheme | Resolved by | Example |
|---|---|---|
| `<bare-key>` | nothing — written to disk as plaintext | `sk-deepseek-abc123…` |
| `op://VAULT/ITEM/FIELD` | [1Password CLI](https://developer.1password.com/docs/cli) (`op read`) | `op://Private/DeepSeek/credential` |
| `system://<account>` | OS keychain — `security` on macOS, `secret-tool` on Linux. Service name is `claude-ds`. | `system://default` |
| `infisical://PROJECT/ENV/PATH#KEY` | [Infisical CLI](https://infisical.com/docs/cli) (`infisical secrets get`) | `infisical://abc123/prod/#DEEPSEEK_API_KEY` |

> ✱ **Shorthand:** for `op`, `system`, and `infisical` you may type the
> scheme name without `://` (e.g. `system`, `infisical`) and `claude-ds`
> will append it for you.

### First-run flow

When the config file doesn't exist, `claude-ds` prompts for a reference.
Two interactive helpers kick in automatically:

- **`system://`** — drops into a numbered selector listing existing keychain
  entries under service `claude-ds`. Pick by number, type a new account name,
  or hit enter to be prompted for one. If the chosen account already has a
  stored secret, it is reused silently; otherwise you are prompted (with
  asterisk-echoed input) for the key, which is then stored in the keychain.
- **`infisical://`** — walks an interactive builder asking for project ID,
  environment slug (default `dev`), folder path (default `/`), and secret key,
  then constructs the full URI for you.

### Rotating / changing the key

```bash
claude-ds --reset-password
```

For `system://<account>` references, the reset flow asks whether to
**[1]** replace the stored secret while keeping the account name, or
**[2]** switch to a different account or scheme entirely (with a follow-up
asking whether to delete the old keychain entry).

For non-system references, the local config reference is forgotten and you
are re-prompted; **upstream stores (1Password, Infisical) are never touched**.

---

## Reasoning-effort proxy

> **Off by default.** You don't need this for normal use. DeepSeek already
> maps claude's `/think`, `/think-hard`, and `/ultrathink` into its
> native reasoning regime via the `thinking` block claude already sends.
> Enable the proxy only when you want to **force** a specific regime
> regardless of what claude requests — e.g. always-max for tough work,
> always-none for token savings, or per-tier knobs.

### How DeepSeek expresses reasoning

DeepSeek's compat shim recognises three reasoning regimes:

| Regime | Wire shape | Behaviour |
|---|---|---|
| `none` | `thinking` block absent, no `reasoning_effort` | No reasoning. |
| `high` | `thinking: {type: enabled}` present, `reasoning_effort` absent (or `=high` — same wire effect) | DeepSeek's default reasoning depth. |
| `max` | `thinking: {type: enabled}` present **and** `reasoning_effort=max` | Maximum reasoning. |

Anthropic's API uses `thinking.budget_tokens` (an integer) for the same
idea. The proxy translates between them and **collapses any
caller-supplied Anthropic-style levels** (`low`, `medium`, `xhigh`,
etc.) onto these three regimes — DeepSeek would otherwise reject them.

### What the proxy does on each request

For every `POST /v1/messages` it sees:

1. Determine the **source bucket** from the incoming body's `thinking` block:
   - no thinking block → `none`
   - thinking enabled, budget `< 31000` → `high`
   - thinking enabled, budget `>= 31000` → `max` (ultrathink)
2. Resolve the per-model spec → target regime.
3. Apply the regime's **transformation** in place:
   - `none` → strip both `thinking` and `reasoning_effort`
   - `high` → ensure `thinking: {type: enabled}` (preserving any caller-supplied `budget_tokens`), strip `reasoning_effort`
   - `max` → ensure `thinking: {type: enabled}`, set `reasoning_effort=max`

### Spec language

The value of `proxy_effort` (and each per-tier `proxy_effort_*`):

| Value | Behaviour |
|---|---|
| `off` (or empty) | Pass the body through unchanged. The proxy is a no-op for this model. |
| `auto` | Mirror the source bucket: `none` → strip, `high` → ensure thinking on, `max` → ensure thinking + max. |
| `auto:<level>` | Like `auto`, but **upgrade** the no-thinking case to `<level>`. `auto:high` forces thinking on every request; `auto:max` forces full reasoning whenever claude is silent. |
| `none` | Always strip thinking and reasoning_effort (force no-reasoning). |
| `high` | Always ensure thinking enabled + drop reasoning_effort (force default reasoning). |
| `max` | Always ensure thinking + reasoning_effort=max (force maximum reasoning). |
| `none=<v>\|high=<v>\|max=<v>` | Full per-source-bucket matrix. Clauses are optional; missing buckets pass through unchanged. |

### Resolution order on every request

1. Look up the model id in the per-tier map (built from `proxy_effort_*` and
   the wire-level model id of each tier). On a hit, use that spec.
2. Otherwise, fall back to the global `proxy_effort` spec.
3. If the resolved spec is `off` (or unset), the body is forwarded unchanged.
4. Otherwise, apply the regime's transformation.

### Enabling the proxy

You can opt in three ways:

```bash
# (a) Interactive — first-run prompt offers proxy choices
claude-ds                              # prompts on first run

# (b) One-shot via env var
CLAUDE_DS_PROXY_EFFORT=auto:high claude-ds

# (c) Persistently in config
echo "proxy_effort=auto:max" >> ~/.config/claude-ds/config
```

When the proxy is enabled, `claude-ds` will **lazy-install** the
sidecar script if it's missing — fetching `claude-ds-proxy.py` from
the same source the wrapper came from. If the download fails (or
`curl` is missing, or `python3` is missing), the wrapper soft-falls-back
to running with the proxy disabled for that session and prints a
single warning. Your config is never silently mutated.

### Disabling the proxy entirely

```ini
proxy_effort=off
# (and leave every per-tier proxy_effort_* unset or off)
```

When all specs resolve to "off", `claude-ds` skips spawning the Python child
entirely; `ANTHROPIC_BASE_URL` is exported pointing straight at DeepSeek and
there is zero proxy overhead.

### One-shot env overrides

```bash
CLAUDE_DS_PROXY_EFFORT=off claude-ds              # skip the proxy this invocation
CLAUDE_DS_PROXY_EFFORT=auto:max claude-ds         # opt in for one run
CLAUDE_DS_PROXY_DEBUG=1 claude-ds                 # log every regime application to stderr
```

<a id="per-tier-collisions"></a>
### Per-tier collisions

The proxy keys its lookup table on the *wire-level* model id (the value
of `ANTHROPIC_DEFAULT_<TIER>_MODEL`), not the tier name. Whenever two
tiers share a wire id, only one per-tier spec can win for that id.

`claude-ds` writes per-tier specs into the lookup table in the order
**small_fast → haiku → sonnet → opus** — so for any given wire id, the
tier later in that order wins on collision.

In practice that means three regimes:

| Configuration | Wire ids per tier | Collisions | Effective rule |
|---|---|---|---|
| Default (no `unlock_auto_mode`, no `model_*` overrides) | All four → `deepseek-v4-pro` | All four collide | `proxy_effort_opus` wins for every tier; the others are dead config. |
| `unlock_auto_mode=1`, no `model_*` overrides | opus → `claude-opus-4-7`, sonnet → `claude-sonnet-4-6`, haiku & small_fast → `claude-haiku-4-5` | haiku ↔ small_fast | opus and sonnet behave independently. `proxy_effort_haiku` wins over `proxy_effort_small_fast` for the haiku/small_fast wire id. |
| Distinct `model_<tier>` overrides (or `unlock_auto_mode=1` with at least one tier overridden to a unique id) | Four distinct ids | None | All four per-tier specs are independent. |

If you set per-tier specs that you *expect* to be independent, double-check
which regime you're in. The simplest fix for an unwanted collision is to
add a `model_<tier>` override that gives the tier its own wire id, or to
enable `unlock_auto_mode=1` if it isn't already.

---

## Auto-mode unlock

Claude Code's *auto mode* — the permission classifier that auto-approves
routine tool calls — is gated on the model id matching one of:

```
claude-opus-4-7
claude-opus-4-6
claude-sonnet-4-6
```

(The provider is *not* checked; just the model name regex.) With the default
`model=deepseek-v4-pro`, auto mode reports "unavailable for this model".

Setting `unlock_auto_mode=1` makes `claude-ds` advertise spoofed Anthropic
model ids to claude:

```
ANTHROPIC_MODEL=claude-opus-4-7
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-7
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5
ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4-5
```

The picker labels (`ANTHROPIC_DEFAULT_*_MODEL_NAME` /
`ANTHROPIC_DEFAULT_*_MODEL_DESCRIPTION`) are also set to DeepSeek-branded
strings so `/model` still shows what's actually running over the wire.

Whether this works depends on your gateway: DeepSeek's compat shim accepts
arbitrary `model` values (it routes by URL+auth) at the time of writing, but
some gateways reject unknown model ids. If yours does, leave
`unlock_auto_mode` unset.

---

## Per-tier model overrides

By default, all four tiers (`opus`, `sonnet`, `haiku`, `small_fast`) are
pinned to the value of `model`. This keeps `/model default` and tier-routing
working against a single-tier provider.

To run different DeepSeek models per tier, set any subset of:

```ini
model=deepseek-v4-pro
model_opus=deepseek-v4-pro
model_sonnet=deepseek-v4-mid
model_haiku=deepseek-v4-fast
model_small_fast=deepseek-v4-fast
```

Per-tier `model_*` overrides also win over the auto-mode-unlock spoofed
ids, so you can have genuine claude-opus-4-7 spoofing on opus while running
real DeepSeek ids on the cheaper tiers.

---

## Visual branding (tmux)

When `claude-ds` is launched inside tmux, the active pane gets a DeepSeek
indigo top border with a 🐋 badge:

```
─🐋 DEEPSEEK ─ model: deepseek-v4-pro · wire id: claude-opus-4-7 (spoofed for auto-mode) ────
```

The window name in tmux's status bar is also prefixed `🐋 ` so the marker
is visible from anywhere.

To skip branding (e.g. for headless `claude -p` runs), set:

```bash
CLAUDE_DS_NO_BRANDING=1 claude-ds -p "summarise this file"
```

If the indigo (`#4D6BFE`) looks washed-out in iTerm2, lower the
**Minimum Contrast** slider in `Profiles → Colors`. Also confirm your
tmux config has `terminal-features` with `RGB` set for your `$TERM` so
24-bit color passes through.

---

## Environment variables

Variables `claude-ds` **reads** (one-shot overrides):

| Variable | Effect |
|---|---|
| `CLAUDE_DS_PROXY_EFFORT` | Overrides `proxy_effort` for this invocation. `off` skips the proxy. |
| `CLAUDE_DS_PROXY_DEBUG` | When `1`, the proxy logs each injection decision to stderr. |
| `CLAUDE_DS_NO_BRANDING` | When set, suppresses tmux branding. |
| `INFISICAL_TOKEN` | Used by the Infisical CLI when resolving `infisical://` refs without an interactive login. |
| `XDG_CONFIG_HOME` | Where the config file lives (`$XDG_CONFIG_HOME/claude-ds/config`). |
| `PAGER` | Used by `--help` (falls back to `less -RF`, then `more`, then `cat`). |
| `TMUX`, `TMUX_PANE` | Auto-detected for the visual-branding block. |

Variables `claude-ds` **exports** to `claude`:

| Variable | Set when |
|---|---|
| `ANTHROPIC_BASE_URL` | always (points at the proxy when enabled, DeepSeek directly otherwise) |
| `ANTHROPIC_AUTH_TOKEN` | always (the resolved API key) |
| `ANTHROPIC_MODEL` | always |
| `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` | always |
| `ANTHROPIC_SMALL_FAST_MODEL` | always |
| `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL_NAME` / `_DESCRIPTION` | when `unlock_auto_mode=1` (DeepSeek-labelled picker text) |
| `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL_SUPPORTED_CAPABILITIES` | when `capabilities=` is set |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` | always |
| `CLAUDE_DISABLE_NONSTREAMING_FALLBACK=1` | always |
| `CLAUDE_DS=1` | always (marker — useful for hooks / statusline scripts; e.g. `if [[ -n "$CLAUDE_DS" ]]; then echo "DeepSeek session"; fi`) |

---

## Troubleshooting

**`claude-ds: python3 not found`**
The reasoning-effort proxy needs Python 3.8+. Install it, or set
`proxy_effort=off` (and clear all per-tier `proxy_effort_*`) to bypass.

**`claude-ds: reasoning-effort proxy failed to start`**
Re-run with the env override `CLAUDE_DS_PROXY_DEBUG=1 claude-ds` — the
proxy's startup error will print to stderr. (`proxy_debug=1` is the
config-file equivalent and requires editing the file before re-running.)
Common causes: a malformed spec in `proxy_effort_*` (the parser names the
offending clause), or `proxy_bind` pointing at an interface you don't have.

**Auto mode says "unavailable for this model"**
Set `unlock_auto_mode=1`. If your gateway rejects spoofed claude-* ids,
auto mode is genuinely unavailable on that provider.

**`/model default` shows the same DeepSeek model for every tier**
That's expected on a single-tier provider. Set distinct `model_<tier>`
overrides if your DeepSeek plan has tiered models.

**My API key didn't get persisted**
You probably entered it as a bare plaintext key. Plaintext is stored
verbatim in the config (`chmod 600`); to use the OS keychain instead, run
`claude-ds --reset-password` and enter `system://`.

**The tmux border is invisible / washed out**
Lower iTerm2's **Minimum Contrast** slider (`Profiles → Colors`). For
non-iTerm terminals, ensure your `tmux.conf` has `terminal-features` with
`RGB` for your `$TERM`.

**The proxy keeps running after I quit claude**
The proxy has an orphan watchdog (in `claude-ds-proxy.py`) that polls
`os.getppid()` every 2 seconds and exits when reparented to PID 1
(init/launchd). On macOS and on Linux without user-level subreapers
this is reliable.

> ⚠️ **Linux + `systemd --user` caveat.** When `systemd --user` is the
> session leader, orphans may be reparented to the user-systemd PID
> instead of PID 1, and the watchdog won't trigger. Check with:
> ```
> ps -o ppid= -p "$(pgrep -f claude-ds-proxy.py)"
> ```
> If that prints anything other than `1`, kill manually with
> `pkill -f claude-ds-proxy.py`. (We're tracking a fix using
> `prctl(PR_SET_PDEATHSIG)` on Linux — PRs welcome.)

---

## Developer notes

> **Status:** `claude-ds` currently lives inside the
> [`earchibald/agent-utilities`](https://github.com/earchibald/agent-utilities)
> monorepo as a single-purpose wrapper. It is expected to graduate to its
> own repository in the near future; when that happens, this directory
> will be reduced to a stub pointing at the new location, and the canonical
> source will move. Until then, **PRs and issues should target
> `earchibald/agent-utilities`**.

### Repository layout

```
wrappers/claude-ds/
├── claude-ds              # Bash wrapper (entry point)
├── claude-ds-proxy.py     # Python 3 stdlib HTTP proxy (request rewriter)
└── README.md              # this file
```

### Internal architecture

```
                                     ┌───────────────────────┐
   user ─► claude-ds (bash)          │   secretref library   │
            │                        │   (op:// system://    │
            │ resolve ref ───────────►   infisical://)       │
            │                        └───────────────────────┘
            │ build effort map from per-tier configs
            │ spawn proxy if needed
            │
            ▼
   ANTHROPIC_BASE_URL=http://127.0.0.1:PORT
            │
            ▼
   exec claude  ──HTTP──► claude-ds-proxy.py ──HTTPS──► DeepSeek /anthropic
                          ├─ inject reasoning_effort
                          ├─ strip thinking block
                          └─ stream response back
```

The Bash script is structured as four blocks: (1) arg parsing and `--help`,
(2) the embedded reusable `secretref` library, (3) config load + spawn
logic, (4) `exec claude`. The proxy is only spawned when at least one
effort spec is non-empty/non-off; otherwise the wrapper points
`ANTHROPIC_BASE_URL` straight at DeepSeek and skips the Python child.

### `secretref` library

The reusable secret-reference resolver lives between `# BEGIN secretref`
and `# END secretref` markers in `claude-ds`. It is intentionally
copy-paste-friendly: drop the block into another wrapper, set
`SECRETREF_KEYCHAIN_SERVICE` and `SECRETREF_LOG_PREFIX`, and you have the
same `op:// / system:// / infisical://` plumbing for free.

### Testing the proxy in isolation

```bash
# Spawn against a fake upstream and probe with curl
python3 -c "
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(*a, **k): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length','0'))
        body = self.rfile.read(n)
        self.send_response(200); self.end_headers(); self.wfile.write(body)
import sys; s = ThreadingHTTPServer(('127.0.0.1', 0), H)
print(s.server_address[1], flush=True); s.serve_forever()
" &
UP=$!
sleep 0.2
UPORT=$(lsof -p $UP -a -iTCP -sTCP:LISTEN -P -n | awk 'NR==2{split($9,a,":"); print a[2]}')

UPSTREAM_BASE_URL="http://127.0.0.1:$UPORT" \
EFFORT_DEFAULT=auto \
EFFORT_MAP="claude-opus-4-7=high" \
PROXY_DEBUG=1 \
  python3 claude-ds-proxy.py
```

### Running against a development checkout

```bash
git clone https://github.com/earchibald/agent-utilities.git
cd agent-utilities
./wrappers/claude-ds/claude-ds --version
```

The wrapper resolves the proxy script via `dirname` of `BASH_SOURCE[0]`
(after symlink resolution), so running it directly from the source tree
works without installation.

### Contributing

PRs welcome against [`earchibald/agent-utilities`](https://github.com/earchibald/agent-utilities).
Please:

- Update [`CHANGELOG.md`](../../CHANGELOG.md) under `[Unreleased]` for any
  user-visible behaviour change.
- For Bash changes: keep `set -euo pipefail` semantics intact; keep the
  `secretref` block self-contained (no external function calls); if you
  touch the `tmux` branding block, verify cleanup still runs in both
  single-pane and multi-pane windows.
- For Python changes: stdlib only. The proxy must remain a single file
  with no install step.

### Versioning

`claude-ds` uses [SemVer](https://semver.org). The version is the
`VERSION="X.Y.Z"` constant near the top of the wrapper; bump it when you
release. The CHANGELOG follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## License

Same as the parent `agent-utilities` repository. See the repository root
for license information.
