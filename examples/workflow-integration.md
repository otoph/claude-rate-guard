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

## 2. Scheduling a resume after `DEFER`

`SECONDS_TO_RESET` is the wait the gate already computed, so you do not need the
local clock. To resume right after the window resets:

```sh
secs="$(rate-guard.sh | awk -F= '/^SECONDS_TO_RESET=/{print $2}')"
sleep $(( secs + 120 ))   # 2-minute cushion
rate-guard.sh >/dev/null && ./run-long-job.sh   # re-check, then launch
```

In an agent loop, prefer the agent's own scheduler (a wakeup within the hour, a
one-shot cron beyond it) over a blocking `sleep`, so the session stays responsive.

## 3. Mid-run watchdog (multi-window runs)

For a job that can exceed one 5-hour window:

1. Start the job in the background; keep a handle or checkpoint mechanism.
2. At a coarse interval, run `rate-guard.sh`.
3. On `DEFER`, stop the job at its next checkpoint (so no work is lost), then
   schedule a resume just after `RESETS_AT`.
4. When the resume fires, run the guard again; on `OK`, continue from the
   checkpoint.

Make the job's steps idempotent (or read-only) so an approximate stop point is
safe to resume from.

## Tuning

- Lower `RATE_GUARD_THRESHOLD` (for example `70`) to leave a bigger safety margin
  for very long runs; raise it (for example `90`) for short ones.
- `RATE_GUARD_STALE_SECONDS` controls how old the status-line state may be before
  the guard returns `UNKNOWN` instead of trusting it.
