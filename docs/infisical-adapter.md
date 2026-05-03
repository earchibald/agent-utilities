# Infisical adapter for `claude-ds`

Reference doc for the `infisical://` secret-reference scheme implemented in `wrappers/claude-ds`. If the adapter breaks, start here.

## What it does

Lets the user point `claude-ds` at an Infisical-managed secret using a single URI, e.g.:

```
infisical://abc123/prod/#API_KEY
infisical://abc123/dev/postgres#DB_PASSWORD
infisical://abc123/dev/k8s/api-keys#STRIPE
```

`resolve_ref()` parses the URI and shells out to the [Infisical CLI](https://infisical.com/docs/cli/overview) to fetch the value, which then becomes `ANTHROPIC_AUTH_TOKEN`.

## URI grammar

```
infisical://<PROJECT_ID>/<ENV>/<PATH>#<KEY>
```

| Component  | Maps to            | Notes                                              |
|------------|--------------------|----------------------------------------------------|
| PROJECT_ID | `--projectId`      | Infisical project's internal ID (not the slug).    |
| ENV        | `--env`            | Environment slug, e.g. `dev`, `staging`, `prod`.   |
| PATH       | `--path`           | Folder path. `/` for root. Leading slash added by parser; trailing slash stripped. |
| KEY        | positional `<NAME>`| URI fragment (after `#`). The secret name.        |

The parser **requires** at least three slash-separated segments (`PROJECT/ENV/PATH`) and a `#KEY` fragment. `infisical://abc/prod#FOO` (no path slash) is rejected — use `infisical://abc/prod/#FOO`.

### Parsing reference (bash)

The implementation lives in `wrappers/claude-ds` inside `resolve_ref()`'s `infisical://*)` branch. Decision flow:

1. Strip `infisical://` prefix.
2. Split off the fragment after the **last** `#` → that's `KEY`. (Uses `${rest##*#}` so a `#` inside the path would be ambiguous — don't put `#` in folder names. Infisical doesn't allow it anyway.)
3. Require the remainder to match `*/*/*` (at least two slashes).
4. First segment → `proj`. Strip it.
5. Next segment → `env`. Strip it.
6. Whatever is left → `path`, prefixed with `/`. Special-case: if env was the final segment (with or without trailing slash), `path = "/"`.

There's a unit-test snippet at the bottom of this doc you can paste into a shell to verify parsing in isolation.

## CLI invocation

```bash
infisical secrets get "$KEY" \
  --projectId="$PROJ" \
  --env="$ENV" \
  --path="$PATH" \
  --plain --silent
```

- **Positional name**, not `--name` — confirmed by the [`infisical secrets get` docs](https://infisical.com/docs/cli/commands/secrets#infisical-secrets-get).
- `--plain` outputs just the value, one per line. (We only ever request one secret.)
- `--silent` suppresses the "💡 tip:" banner that otherwise contaminates output.
- `--projectId` is **required** when authenticating via machine identity / service token. Passing it always is harmless under user login.
- Trailing newline (if any) is stripped by bash command substitution: `token=$(resolve_ref ...)`.

## Authentication

The CLI must already be authenticated by the time `claude-ds` runs. Two options:

1. **User login** — `infisical login` once, interactively. Stores creds in the OS keyring. Persists across shells.
2. **Token env var** — `export INFISICAL_TOKEN=<service-token-or-machine-identity-token>` before invoking `claude-ds`. Suitable for CI / headless boxes.

If neither is set up, `infisical secrets get` will print an auth error to stderr and exit non-zero; `claude-ds` then prints `failed to resolve API key from <ref>` and exits.

## Troubleshooting checklist

If a user reports the adapter is broken, walk this list in order. Don't skip steps — most "broken" reports are auth or shape issues, not parser bugs.

### 1. Is the CLI installed and on PATH?

```bash
command -v infisical && infisical --version
```

If missing: install per <https://infisical.com/docs/cli/overview>. The wrapper prints `claude-ds: infisical CLI not found` when this fails.

### 2. Is the user authenticated?

```bash
infisical user            # shows current user if logged in
echo "${INFISICAL_TOKEN:+token-set}"
```

If neither is true, fix auth before debugging anything else. Reproduce a known-good fetch by hand:

```bash
infisical secrets get SOME_KEY --projectId=abc --env=dev --path=/ --plain --silent
```

If that fails, the adapter can't possibly succeed. Stop debugging the wrapper.

### 3. Does the URI shape match the grammar?

Run the parser-only snippet at the bottom of this doc with the user's exact URI. Common mistakes:

- Missing trailing `/` before `#` for root-folder secrets: write `prod/#KEY`, not `prod#KEY`.
- Using the project **slug** instead of the **project ID**. Get the ID from the Infisical UI → Project Settings → "Project ID".
- Using a custom env name instead of the slug. The slug is the lowercase, hyphenated form (e.g. `staging`, not `Staging`).

### 4. Did Infisical change the CLI surface?

Less likely but possible. Things that would break us:

- **`--path` removed or renamed** for `secrets get`. There's a known [folders-get path bug (issue #3297)](https://github.com/Infisical/infisical/issues/3297), but `secrets get --path` has been stable. If they regress it, the workaround is to walk the folder tree client-side or use the [REST API](https://infisical.com/docs/api-reference/endpoints/secrets/read) directly.
- **`--plain` output format change** (e.g. adding ANSI codes). Mitigation: pipe through `tr -d '\n'` or parse stricter.
- **`--silent` removed.** Then `--plain` output may be polluted by tip lines. Mitigation: `2>/dev/null` and `head -n1` the result.
- **Positional → flag-based name.** The [docs page](https://infisical.com/docs/cli/commands/secrets) is the source of truth; check it first.

Re-fetch the docs page (via WebFetch or in a browser) before assuming anything in the table above is still current.

### 5. Is the secret actually retrievable?

Auth could be valid but the token may not have read access to the requested env/path. Reproduce by hand with the exact `--projectId`, `--env`, `--path`, and key the parser produced. If that hand-invocation works but the wrapper fails, it's a parser bug — see step 6.

### 6. Parser bug?

Add `set -x` near the top of `resolve_ref()` (or just temporarily echo the parsed values to stderr) and re-run. Compare against the test snippet's expected output. Fix the `infisical://*)` branch in `wrappers/claude-ds`. Update the test snippet in this doc if you change the contract.

## Things explicitly out of scope

- **Multi-secret retrieval.** The grammar is one URI → one secret. The wrapper only ever needs one (the API key).
- **Caching.** Every `claude-ds` invocation does a fresh `infisical secrets get`. If that becomes a latency problem, cache in `~/.cache/claude-ds/` keyed by the URI hash with a short TTL — but don't add caching speculatively.
- **Secret references / interpolation.** Infisical's internal `${env.KEY}` syntax is resolved server-side; we don't try to interpret it.
- **Self-hosted Infisical instances.** The CLI handles `INFISICAL_API_URL` itself. We don't need to plumb it.

## Parser test snippet

Paste into a shell to verify parsing without invoking the real CLI. Update the expected lines if you change the grammar.

```bash
parse() {
  ref="$1"
  rest="${ref#infisical://}"
  case "$rest" in *\#*) ;; *) echo "ERR no #"; return ;; esac
  key="${rest##*#}"; rest="${rest%#*}"
  case "$rest" in */*/*) ;; *) echo "ERR shape ($rest)"; return ;; esac
  proj="${rest%%/*}"; rest="${rest#*/}"
  env="${rest%%/*}"
  if [[ "$rest" == "$env" || "$rest" == "$env/" ]]; then
    path="/"
  else
    path="/${rest#*/}"; path="${path%/}"; [[ -n "$path" ]] || path="/"
  fi
  echo "proj=$proj env=$env path=$path key=$key"
}

# Expected:
# proj=abc123 env=prod path=/ key=API_KEY
parse "infisical://abc123/prod/#API_KEY"

# proj=abc123 env=dev path=/postgres key=DB_PASSWORD
parse "infisical://abc123/dev/postgres#DB_PASSWORD"

# proj=abc123 env=dev path=/k8s/api-keys key=STRIPE
parse "infisical://abc123/dev/k8s/api-keys#STRIPE"

# ERR shape (abc123/prod)
parse "infisical://abc123/prod#NOPATH"

# ERR no #
parse "infisical://abc123/prod/foo"
```

## Where to look

- Implementation: `wrappers/claude-ds`, function `resolve_ref()`, branch `infisical://*)`.
- Header comment block in the same file — keep usage docs there in sync with this file.
- Changelog entry in `CHANGELOG.md` under the release that introduced the scheme.
