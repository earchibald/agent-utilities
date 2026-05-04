#!/usr/bin/env python3
# claude-ds-proxy — request-rewriting proxy that translates Anthropic
# `thinking.budget_tokens` into the DeepSeek-shaped reasoning regime on
# outgoing /v1/messages bodies.
#
# Spawned by the `claude-ds` shell wrapper. Stdlib-only (Python 3.8+).
#
# DeepSeek's compat shim recognises three reasoning regimes:
#   "none"   — `thinking` block ABSENT, no `reasoning_effort`. No reasoning.
#   "high"   — `thinking: {"type": "enabled"}` PRESENT, `reasoning_effort`
#              absent (or =high — same wire effect). DeepSeek's default
#              reasoning depth.
#   "max"    — `thinking` PRESENT *and* `reasoning_effort=max`. Maximum
#              reasoning depth. (Other Anthropic levels — `low`, `medium`,
#              `minimal`, `xhigh` — are not real DeepSeek regimes; this
#              proxy collapses them onto the three above.)
#
# So the proxy applies a *transformation* (not just an injection):
#   level=none → strip `thinking`, strip `reasoning_effort`
#   level=high → ensure `thinking: {type: enabled}` (with the original
#                budget_tokens preserved if present), strip `reasoning_effort`
#   level=max  → ensure `thinking: {type: enabled}`, set `reasoning_effort=max`
#
# Claude → DeepSeek mapping (proxy_effort=auto):
#   Claude off (no thinking)     → none (no reasoning tokens)
#   Claude low/medium/high       → high (DeepSeek default reasoning)
#   Claude extra-high / max      → max  (DeepSeek maximum reasoning)
#   small_fast tier (always)     → none (strip thinking — saves tokens)
#
# Configuration via environment variables (set by the wrapper):
#   UPSTREAM_BASE_URL   required. e.g. https://api.deepseek.com/anthropic
#   PROXY_BIND          default 127.0.0.1
#   PROXY_PORT          default 0 (kernel-assigned; actual port printed to
#                       stdout as the first line so the parent can read it)
#   EFFORT_DEFAULT      spec applied to any model not named in EFFORT_MAP.
#                       see "Spec language" below. empty = passthrough.
#   EFFORT_MAP          per-wire-model overrides. semicolon-separated
#                       `<model>=<spec>` pairs.
#                       e.g. "claude-opus-4-7=auto;claude-sonnet-4-6=high"
#   PROXY_DEBUG         "1" to log rewrites/requests to stderr.
#
# Spec language (the value side of EFFORT_MAP / EFFORT_DEFAULT):
#   off            no transformation — pass the body through unchanged.
#                  (empty string is treated the same.)
#   none           force the "no reasoning" regime (strip thinking block).
#   high           force the "default reasoning" regime (thinking enabled,
#                  no reasoning_effort).
#   max            force the "maximum reasoning" regime (thinking enabled
#                  + reasoning_effort=max).
#   auto           derive the regime from claude's `thinking` block:
#                    no/disabled thinking          → "none"
#                    thinking enabled, budget <31k → "high"
#                    thinking enabled, budget ≥31k → "max"
#                  (Thresholds align with Claude Code's canned levels:
#                  `think` ≈ 4k, `think hard` ≈ 10k, `think harder` ≈ 20k,
#                  `ultrathink` ≈ 31999. ultrathink → max; everything else
#                  with thinking → high.)
#   auto:<level>   like auto, but use <level> as the fallback when claude
#                  sends no thinking block. e.g. `auto:high` ensures
#                  thinking is always on; `auto:none` is identical to bare
#                  `auto`.
#   none=<v>|high=<v>|max=<v>
#                  full per-source-bucket matrix. each clause is optional;
#                  unlisted source buckets pass through unchanged.
#                  e.g. `none=high|high=high|max=max` ≡ `auto:high`.
#
# Resolution order on every POST /v1/messages:
#   1. spec = EFFORT_MAP[model] if present, else EFFORT_DEFAULT
#   2. if spec is empty/`off` → forward unchanged
#   3. otherwise resolve spec against the source bucket → target regime
#   4. apply the regime's transformation to the body
#
# Note: the proxy intentionally OVERRIDES any caller-supplied
# `reasoning_effort`, because Claude Code's `/effort low` / `/effort medium`
# / `/effort xhigh` send levels DeepSeek doesn't recognise — passing them
# through unchanged would cause silent 400s or quiet downgrades. To opt
# out of the override, set the spec to `off` for that model.

import http.client
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


# ---------- spec parsing ----------------------------------------------------

# DeepSeek-recognised reasoning regimes. These are the only values a
# spec can resolve to (plus the implicit "passthrough" for `off`).
_LEVELS = {"none", "high", "max"}
# Source-bucket keys (rows of the auto-mapping matrix). The auto-bucket
# function emits one of these for each request based on claude's
# `thinking` block.
_BUCKETS = ("none", "high", "max")


def _parse_spec(raw: str):
    """Parse a spec string into a callable: bucket -> effort_or_none.

    Returns None when the spec disables injection unconditionally."""
    s = (raw or "").strip()
    if not s or s.lower() == "off":
        return None
    s_low = s.lower()
    if s_low in _LEVELS:
        # Constant — same level for every source bucket.
        def _const(bucket, _s=s_low):
            _ = bucket
            return _s
        return _const
    if s_low == "auto":
        # bare `auto` mirrors the source bucket directly: 'none' → strip,
        # 'high' → enable thinking, 'max' → enable thinking + max effort.
        return lambda bucket: bucket if bucket in _LEVELS else None
    if s_low.startswith("auto:"):
        # `auto:<level>` upgrades the no-thinking case ('none' bucket) to
        # the named level, while leaving high/max buckets at their bucket
        # value. Useful for "always at least thinking" (`auto:high`) or
        # "always full reasoning" (`auto:max`).
        fallback = s_low.split(":", 1)[1].strip()
        if fallback not in _LEVELS:
            raise ValueError(f"auto: fallback must be one of {sorted(_LEVELS)} (got {fallback!r})")
        def _auto_with_fallback(bucket, _f=fallback):
            if bucket == "none":
                return _f
            return bucket if bucket in _LEVELS else None
        return _auto_with_fallback
    # Otherwise, expect a `key=val|key=val|...` matrix.
    matrix = {}
    for clause in s.split("|"):
        clause = clause.strip()
        if not clause:
            continue
        if "=" not in clause:
            raise ValueError(f"matrix clause missing '=': {clause!r}")
        k, v = clause.split("=", 1)
        k, v = k.strip().lower(), v.strip().lower()
        if k not in _BUCKETS:
            raise ValueError(f"matrix bucket must be one of {list(_BUCKETS)} (got {k!r})")
        if v not in _LEVELS and v != "off":
            raise ValueError(f"matrix value must be a level or 'off' (got {v!r})")
        if v != "off":
            matrix[k] = v
    if not matrix:
        return None
    return lambda bucket, _m=matrix: _m.get(bucket)


def _parse_map(spec: str) -> dict:
    """Parse `model=spec;model=spec;...` into {model: resolver}."""
    out = {}
    if not spec:
        return out
    for pair in spec.split(";"):
        pair = pair.strip()
        if not pair or "=" not in pair:
            continue
        model, raw_spec = pair.split("=", 1)
        model = model.strip()
        if not model:
            continue
        out[model] = _parse_spec(raw_spec)
    return out


# ---------- environment / config -------------------------------------------

UPSTREAM = os.environ.get("UPSTREAM_BASE_URL", "")
if not UPSTREAM:
    print("claude-ds-proxy: UPSTREAM_BASE_URL is required", file=sys.stderr)
    sys.exit(2)

try:
    EFFORT_RESOLVERS = _parse_map(os.environ.get("EFFORT_MAP", ""))
    DEFAULT_RESOLVER = _parse_spec(os.environ.get("EFFORT_DEFAULT", ""))
except ValueError as e:
    print(f"claude-ds-proxy: bad effort spec: {e}", file=sys.stderr)
    sys.exit(2)

DEBUG = os.environ.get("PROXY_DEBUG", "") == "1"

_up = urlsplit(UPSTREAM)
UP_SCHEME = _up.scheme
UP_HOST = _up.hostname or ""
UP_PORT = _up.port or (443 if UP_SCHEME == "https" else 80)
UP_PATH_PREFIX = (_up.path or "").rstrip("/")


def _log(*args):
    if DEBUG:
        print("[claude-ds-proxy]", *args, file=sys.stderr, flush=True)


# ---------- request rewriting ----------------------------------------------

_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def _should_inject(method: str, path: str) -> bool:
    if method != "POST":
        return False
    bare = path.split("?", 1)[0].rstrip("/")
    return bare.endswith("/v1/messages")


def _bucket_from_thinking(thinking) -> str:
    """Return one of 'none' | 'high' | 'max' for a thinking block.

    DeepSeek only distinguishes three reasoning regimes, so the bucket
    space matches: no thinking → 'none'; thinking enabled with any
    sub-ultrathink budget → 'high'; thinking enabled with ultrathink-tier
    budget → 'max'."""
    if not isinstance(thinking, dict) or thinking.get("type") != "enabled":
        return "none"
    try:
        n = int(thinking.get("budget_tokens", 0) or 0)
    except (TypeError, ValueError):
        return "high"
    return "max" if n >= 31000 else "high"


def _apply_regime(obj: dict, regime: str) -> None:
    """Mutate `obj` in place to match the target DeepSeek regime.

    none — strip both `thinking` and `reasoning_effort` so DeepSeek
           returns a plain non-reasoning response.
    high — ensure `thinking: {type: enabled}` (preserving any
           caller-supplied budget_tokens), strip `reasoning_effort`
           since DeepSeek treats omission and `=high` as the same wire
           effect and Anthropic-style values like `low`/`medium` would
           otherwise be rejected.
    max  — ensure `thinking: {type: enabled}`, set `reasoning_effort=max`."""
    if regime == "none":
        obj.pop("thinking", None)
        obj.pop("reasoning_effort", None)
        return
    # Both `high` and `max` need thinking enabled. Preserve an existing
    # budget_tokens if present; otherwise omit (DeepSeek handles unbounded).
    existing = obj.get("thinking")
    new_thinking: dict = {"type": "enabled"}
    if isinstance(existing, dict) and "budget_tokens" in existing:
        new_thinking["budget_tokens"] = existing["budget_tokens"]
    obj["thinking"] = new_thinking
    if regime == "high":
        obj.pop("reasoning_effort", None)
    elif regime == "max":
        obj["reasoning_effort"] = "max"


def _rewrite_body(body: bytes) -> bytes:
    try:
        obj = json.loads(body)
    except Exception as e:
        _log(f"body not JSON, passing through ({e})")
        return body
    if not isinstance(obj, dict):
        return body

    model = obj.get("model", "") or ""
    resolver = EFFORT_RESOLVERS.get(model, DEFAULT_RESOLVER)
    if resolver is None:
        _log(f"no effort spec applies to model={model!r}; passing through")
        return body

    bucket = _bucket_from_thinking(obj.get("thinking"))
    regime = resolver(bucket)
    if not regime:
        _log(f"spec yielded no regime for model={model!r} bucket={bucket!r}; passing through")
        return body

    incoming_re = obj.get("reasoning_effort", "<absent>")
    _apply_regime(obj, regime)
    _log(
        f"applied regime={regime!r} model={model!r} source-bucket={bucket!r} "
        f"(was reasoning_effort={incoming_re!r})"
    )
    return json.dumps(obj, ensure_ascii=False).encode("utf-8")


# ---------- HTTP server -----------------------------------------------------


class Proxy(BaseHTTPRequestHandler):
    # HTTP/1.1 + Connection: close on responses gives us length-by-EOF
    # framing — the simplest way to forward streaming SSE bodies without
    # re-encoding chunked transfer.
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 — match base sig
        if DEBUG:
            super().log_message(format, *args)

    def _handle(self):
        clen = self.headers.get("Content-Length")
        body = b""
        if clen:
            try:
                body = self.rfile.read(int(clen))
            except Exception as e:
                self.send_error(400, f"failed to read request body: {e}")
                return

        if _should_inject(self.command, self.path) and body:
            ctype = (self.headers.get("Content-Type") or "").lower()
            if "json" in ctype:
                body = _rewrite_body(body)

        fwd_headers = []
        for h, v in self.headers.items():
            if h.lower() in _HOP_BY_HOP:
                continue
            if h.lower() in ("host", "content-length"):
                continue
            fwd_headers.append((h, v))
        fwd_headers.append(("Host", UP_HOST))
        if body:
            fwd_headers.append(("Content-Length", str(len(body))))

        target_path = UP_PATH_PREFIX + self.path

        if UP_SCHEME == "https":
            conn = http.client.HTTPSConnection(UP_HOST, UP_PORT, timeout=600)
        else:
            conn = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=600)

        try:
            conn.putrequest(self.command, target_path, skip_host=True, skip_accept_encoding=True)
            for h, v in fwd_headers:
                conn.putheader(h, v)
            conn.endheaders()
            if body:
                conn.send(body)
            resp = conn.getresponse()
        except Exception as e:
            _log(f"upstream request failed: {e}")
            try:
                self.send_error(502, f"upstream error: {e}")
            except Exception:
                pass
            conn.close()
            return

        try:
            self.send_response(resp.status, resp.reason)
            for h, v in resp.getheaders():
                hl = h.lower()
                if hl in _HOP_BY_HOP:
                    continue
                if hl == "content-length":
                    continue
                self.send_header(h, v)
            self.send_header("Connection", "close")
            self.end_headers()

            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    _log("client closed connection mid-stream")
                    break
        finally:
            try:
                conn.close()
            except Exception:
                pass

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_PATCH = _handle
    do_OPTIONS = _handle
    do_HEAD = _handle


def _watch_orphan():
    """Background watchdog: exit when the parent process dies. The wrapper
    `exec`s claude after spawning us, so our parent stays alive for the
    duration of the claude session. When claude exits, we get reparented
    to PID 1 (init/launchd) — that's our cue to shut down."""
    initial_ppid = os.getppid()
    while True:
        time.sleep(2)
        ppid = os.getppid()
        if ppid != initial_ppid and ppid == 1:
            _log("parent died (reparented to init); exiting")
            os._exit(0)


def main():
    threading.Thread(target=_watch_orphan, daemon=True).start()
    bind = os.environ.get("PROXY_BIND", "127.0.0.1")
    port = int(os.environ.get("PROXY_PORT", "0") or "0")
    server = ThreadingHTTPServer((bind, port), Proxy)
    actual_port = server.server_address[1]
    # First line of stdout is the bound port — the parent wrapper reads
    # it synchronously to know we're ready and which port to point
    # ANTHROPIC_BASE_URL at.
    print(actual_port, flush=True)
    _log(f"listening on {bind}:{actual_port}, upstream={UPSTREAM}")
    _log(f"per-model resolvers: {sorted(EFFORT_RESOLVERS)}, default-set={DEFAULT_RESOLVER is not None}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
