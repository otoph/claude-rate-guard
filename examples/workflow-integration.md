# Integrating claude-rate-guard into a long-running workflow

`rate-guard.sh` is a plain command. Anything that can run a shell command and read
its exit code can gate on it: a wrapper script, a CI step, or an agent.

## 1. Pre-flight gate (shell)

```sh
#!/usr/bin/env bash
# Launch a long job only if the 5-hour window has room.
eval "$(rate-guard.sh | sed 's/^/RG_/')"   # RG_VERDICT, RG_FIVE_HOUR_PCT, RG_RESETS_AT, ...
case "$RG_VERDICT" in
  OK)      echo "launching (5h usage ${RG_FIVE_HOUR_PCT}%)"; exec ./run-long-job.sh ;;
  DEFER)   echo "deferring until $RG_RESETS_AT_HUMAN (usage ${RG_FIVE_HOUR_PCT}%)"; exit 10 ;;
  UNKNOWN) echo "budget unknown, proceeding fail-open"; exec ./run-long-job.sh ;;
esac
```

Exit codes also work directly:

```sh
rate-guard.sh >/dev/null; case $? in
  0) ./run-long-job.sh ;;          # OK
  10) echo "deferred" ;;           # DEFER
  20) ./run-long-job.sh ;;         # UNKNOWN (fail-open)
esac
```

## 2. Budget sizing with `HEADROOM_PCT` (large fleets)

An `OK` verdict alone cannot protect a highly parallel run: a fleet burning
several points per minute can eat the whole window minutes after a green light.
Before a large launch, compare the **estimated consumption** against the
headroom the gate reports:

```sh
# Launch only if the estimated cost (in points of the 5h window) fits.
# Branch on VERDICT first: UNKNOWN stays fail-open (the budget check needs a
# working gate; without one the contract says proceed and flag it).
est_points=13            # measured, not guessed - see below
eval "$(rate-guard.sh | sed 's/^/RG_/')"
case "$RG_VERDICT" in
  UNKNOWN) echo "budget unknown, proceeding fail-open"; ./run-long-job.sh ;;
  DEFER)   echo "deferring until $RG_RESETS_AT_HUMAN" ;;   # schedule per section 3
  OK)
    if awk -v e="$est_points" -v h="$RG_HEADROOM_PCT" 'BEGIN{exit !(e*1.3 <= h)}'; then
      ./run-long-job.sh
    else
      echo "does not fit (need $est_points x1.3, have $RG_HEADROOM_PCT): split into batches"
      # If even the smallest batch does not fit (headroom ~0 just under the
      # threshold), treat it like DEFER: schedule just after RESETS_AT
      # (section 3). Do not silently keep holding at OK.
    fi ;;
esac
```

Measure the unit cost instead of assuming it — it varies severalfold with the
model configuration:

1. Read `FIVE_HOUR_PCT`, run a **small measurement batch** (a few units), read
   `FIVE_HOUR_PCT` again. Points-per-unit = delta ÷ units.
   (The state updates only when the status line runs, so read it from a fresh
   gate call after the batch's results are in.)
2. **A zero delta means "not yet measured", never "free"** — the state may
   simply not have refreshed since the batch. Re-read after the next
   status-line update or use a larger measurement batch; never size batches
   with a unit cost of 0 (`0 × anything ≤ headroom` always passes and the
   batch becomes unbounded).
3. Size every following batch so `batch_units × points_per_unit × 1.3 ≤ HEADROOM_PCT`.
4. Re-run the gate **before each batch**, commit results per batch, and on
   `DEFER` schedule the next batch after the reset (section 3). Crossing a
   window then loses nothing: the run stops at a boundary, not mid-flight.

## 3. Scheduling a resume after `DEFER`

`SECONDS_TO_RESET` is the wait the gate already computed, so you do not need the
local clock. To resume right after the window resets:

```sh
secs="$(rate-guard.sh | awk -F= '/^SECONDS_TO_RESET=/{print $2}')"
sleep $(( secs + 120 ))   # 2-minute cushion
rate-guard.sh >/dev/null && ./run-long-job.sh   # re-check, then launch
```

In an agent loop, prefer the agent's own scheduler (a wakeup within the hour, a
one-shot cron beyond it) over a blocking `sleep`, so the session stays responsive.

## 4. Mid-run watchdog (multi-window runs)

For a job that can exceed one 5-hour window:

1. Start the job in the background; keep a handle or checkpoint mechanism.
2. At a fixed interval, run `rate-guard.sh`. **Derive the interval from a
   formula, not a fixed "N minutes"**:

   > interval < (100 − threshold) ÷ maximum burn rate (points/minute)

   Example: threshold 80 and a 16-parallel fleet burning 7 points/minute cap
   the interval at ~2.8 minutes; a 20-minute interval can lose everything
   before its first tick. The state is also only as fresh as the last
   status-line run, so the effective lag is interval + staleness.
3. **Predictive stop (recommended)**: keep the previous `FIVE_HOUR_PCT`, derive
   the burn rate from the last two readings, and if the threshold will be
   reached before the next tick, stop now even below the threshold.
4. On `DEFER`, stop the job at its next checkpoint (so no work is lost), then
   schedule a resume just after `RESETS_AT`.
5. When the resume fires, run the guard again; on `OK`, continue from the
   checkpoint.

Make the job's steps idempotent (or read-only) so an approximate stop point is
safe to resume from. Treat the watchdog as **insurance**: the first line of
defense is budget sizing and batching (section 2), which stops at boundaries
instead of mid-flight.

## 5. Fail-fast inside a Workflow script

When the window does run out mid-flight, orchestrators that map agent errors to
`null` keep launching doomed agents (a field test wasted 113 launches this
way). Guard the launches; abort after **consecutive** failures — a single
`null` can also be an unrelated agent death or a user skip, so do not abort on
the first:

```js
let consecutiveNulls = 0
let aborted = false
const guarded = async (fn) => {
  if (aborted) return null
  const r = await fn()
  if (r === null) {
    consecutiveNulls += 1
    if (consecutiveNulls >= 3) {
      aborted = true
      log('3 consecutive agent failures - stopping new launches (likely window exhaustion)')
    }
  } else {
    consecutiveNulls = 0
  }
  return r
}

// usage: wrap every launch
const results = await parallel(items.map(x => () => guarded(() => agent(promptFor(x)))))
```

Notes: agents already in flight cannot be stopped this way — only queued
launches short-circuit. Report the aborted count in the workflow's return value
so a partial result is never mistaken for a complete one.

## 6. Recovering after a crash

Session-scoped resume handles (`resumeFromRunId`, scheduled wakeups,
session-scoped cron) die with the session. To survive a crash:

- At launch and at each batch boundary, persist what recovery needs to a
  **persistent file** (for example `~/.claude/rate-guard/resume.json`):
  the script path, run id, batch progress, scheduled resume time, and where the
  journal/transcript lives.
- After a crash, a transparent resume is not possible (`resumeFromRunId` is
  same-session only). Instead, use that file to find the journal, read what
  completed, and write a continuation script for the remaining work.
- Keep workflow scripts and intermediate artifacts out of `/tmp` — it does not
  survive a crash or reboot.
- An OS cron / systemd timer can trigger recovery, but it starts headless,
  where the status line does not run (gate `UNKNOWN`). Do the recovery itself
  in an interactive session.

## Tuning

- Lower `RATE_GUARD_THRESHOLD` (for example `70`) to leave a bigger safety margin
  for very long runs; raise it (for example `90`) for short ones.
- `RATE_GUARD_STALE_SECONDS` controls how old the status-line state may be before
  the guard returns `UNKNOWN` instead of trusting it.
