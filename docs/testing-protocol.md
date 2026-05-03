# Cache-Cliff Hook Testing Protocol

## Overview

The cache-cliff system has a built-in test mode that bypasses the need for a real 1h prompt-cache entry. A flag file on disk overrides transcript parsing in both hooks so the full warn flow can be exercised in a controlled ~5-minute cycle.

## Mechanism

**Test flag**: `/tmp/claude-cliff-test-cliff`

Contents: a future Unix epoch representing the fake cliff time.

When present:
- `cache-cliff-handoff.sh` uses this epoch instead of parsing the transcript; sets `total_m1h=999999` to bypass the threshold gate.
- `cache-cliff-warn.sh` uses this epoch instead of parsing the transcript.
- `cache-cliff-warn.sh` writes `HANDOFF-stats-${session_short}.json` to the agent CWD and touches a `banner-fired` sentinel — **test mode only**.

## Arming a Test Cycle

```bash
# Cliff in 300s = handoff fires in 180s, banner fires ~210s from now
echo $(( $(date +%s) + 300 )) > /tmp/claude-cliff-test-cliff
```

Then trigger a Stop event (send any message to Claude) so `cache-cliff-handoff.sh` starts its background timer.

## Expected Timeline

| T + | Event |
|-----|-------|
| 0s | Test flag written, Stop fires, handoff.sh starts sleeping |
| 180s | handoff.sh wakes, writes ready-sentinel + stats snapshot, exits 2 |
| ~200s | Model finishes writing HANDOFF-${session_short}.md, Stop fires |
| ~200s | warn.sh fires: checks sentinel, emits systemMessage banner, writes HANDOFF-stats-${session_short}.json |

## Loop Harness

Use `/loop 15s` with the standard cache-cliff test harness prompt to automate detection. The loop polls every minute (cron minimum) and stops itself when any `HANDOFF-stats-*.json` appears in CWD, removing the test flag automatically.

```
/loop 15s

Cache-cliff test harness. CWD: /path/to/agent-utilities

Each tick:
1. If any HANDOFF-stats-*.json exists in CWD: read the most recent, remove test flag, report stats, stop loop.
2. Else if any HANDOFF-*.md modified in last 10 minutes: "Handoff written at HH:MM — waiting for banner". Continue.
3. Else if test flag absent and no stats: "Test epoch expired with no banner". Stop loop.
4. Otherwise: report elapsed seconds. Continue.
```

## HANDOFF-stats-${session_short}.json Schema

Written by `cache-cliff-warn.sh` in test mode only:

```json
{
  "cliff_epoch":      1234567890,
  "cliff_hhmm":       "01:25",
  "tokens_expiring":  999999,
  "handoff_cost_in":  3,
  "handoff_cost_out": 783,
  "banner_fired_at":  1234567800
}
```

| Field | Meaning |
|-------|---------|
| `cliff_epoch` | Unix epoch of the fake cliff |
| `cliff_hhmm` | Human-readable cliff time |
| `tokens_expiring` | 1h cache tokens at risk (999999 in test mode) |
| `handoff_cost_in` | Input tokens consumed generating HANDOFF-${session_short}.md |
| `handoff_cost_out` | Output tokens consumed generating HANDOFF-${session_short}.md |
| `banner_fired_at` | Unix epoch when warn.sh fired the banner |

`banner_fired_at` should satisfy `cliff_epoch - banner_fired_at` between 0 and 120 (rem window).

## Interpreting Results

**Healthy cycle:**
- `rem` at banner fire: 0 < rem ≤ 120
- `handoff_cost_in`: near-zero (full context served from cache, only rewake directive is new input)
- `handoff_cost_out`: target < 800 tokens (see [issue #2](https://github.com/earchibald/agent-utilities/issues/2))

**Tuning lever**: `handoff_cost_out` is the primary efficiency metric. A verbose HANDOFF-${session_short}.md costs more output tokens. The rewake prompt's section template and any word-budget hint directly control this.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| No banner, test flag expired | `rem` was ≤ 0 when warn.sh ran (model generation took too long) | Increase test window: use 400–500s instead of 300s |
| Tight re-fire loop | `delay ≤ 0` and ready-sentinel exists | Tight-loop guard should prevent this (bail if `delay≤0 && sentinel exists`) |
| Banner fires but no HANDOFF-stats-${session_short}.json | Test flag was removed before warn.sh ran | Keep test flag in place until loop detects stats |
| `systemMessage` not appearing | Invalid JSON from warn.sh | Confirm warn.sh uses `jq -n --arg m` to build output, not `printf` with literal `\n` |

## Disarming

The loop harness removes the test flag automatically on success. Manual disarm:

```bash
rm /tmp/claude-cliff-test-cliff
```

Clean up any leftover sentinels:

```bash
rm -f /tmp/claude-cliff-handoff-{pid,sentinel,ready,stats}-*
rm -f /tmp/claude-cliff-perm-requested-*
rm -f /tmp/claude-cliff-banner-fired-*
```
