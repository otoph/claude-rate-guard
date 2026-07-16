# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Follow-ups from a field report (a watchdog whose readings went stale mid-run)
and a window-exhaustion incident (a prebuilt 27-agent workflow launched at 9%).

### Added
- `STATE_AGE_SECONDS` in the gate output: the age of the state copy
  (`now - written_at`; empty when `written_at` is missing or not a number).
  Judge the freshness of a reading mechanically, and measure the burn rate
  from deltas between two points with different `written_at`.
- Spec: an `UNKNOWN` (stale) branch in the mid-run watchdog loop (FR-08,
  Appendix B) — never treat a stale reading as OK; estimate "last known value
  + elapsed × burn rate" conservatively and stop as DEFER at or above the
  threshold. Shell-loop watchdogs sever the implicit refresh that agent
  wake-ups provide, so they require this branch or `refreshInterval`.
- Spec: `statusLine.refreshInterval` documented and recommended for watchdog
  operation (§8, Appendix A-1, README install) — verified on Claude Code
  2.1.211: takes effect without a session restart and fires while the main
  loop is fully idle.
- Spec: treat a workflow whose fan-out is unknown as un-estimatable, and
  estimate review-type workflows with an upper bound (candidate count ×
  verifier unit cost) (FR-06, §12) — from a field incident (27 agents,
  ~1.58M tokens ≈ 70 points, 9% → 100% mid-run).
- Spec: multi-session reading jitter documented — the state carries the
  writing session's last API response values, so concurrent sessions
  interleave non-monotonic readings; measure unit costs with one session
  only (§8, FR-06, §12).

### Changed
- The stale `REASON` now names the common real cause — no UI event while the
  main loop waits on background work, pointing at `statusLine.refreshInterval`
  — instead of only suspecting a tee failure (FR-04).

## [0.2.0] - 2026-07-06

Hardening from a large-scale field test (a ~300-subagent workflow spanning four
5-hour windows). A threshold gate alone proved insufficient for highly parallel
fleets; this release makes budget comparison and batch splitting the first line
of defense.

### Added
- `HEADROOM_PCT` in the gate output: the room left up to the threshold
  (`threshold - usage`, floored at 0; empty on `UNKNOWN`). The right-hand side
  of the new budget comparison.
- Spec: budget comparison at pre-flight (estimated consumption × 1.3 ≤
  `HEADROOM_PCT`, with a measured unit cost) as the standard launch decision
  (FR-06).
- Spec: batch splitting as the standard form for large work — measurement
  batch, budget-sized batches, gate re-run at each boundary, idempotent
  checkpoints per batch (new FR-09, the first line of defense).
- Spec: crash resilience — persist resume information to a file such as
  `~/.claude/rate-guard/resume.json`; distinguish same-session resume
  (`resumeFromRunId`) from cross-session recovery (journal-based
  reconstruction); out-of-process timers are recovery triggers, not
  transparent resumes (new FR-10).
- Spec: the watchdog interval formula `interval < (100 - threshold) ÷ max burn
  rate` and predictive DEFER from the measured burn rate (FR-08).
- Examples: budget sizing with `HEADROOM_PCT`, a fail-fast guard for Workflow
  scripts (abort after consecutive failures), and crash-recovery notes in
  `examples/workflow-integration.md`.

### Changed
- `FIVE_HOUR_PCT` (and `HEADROOM_PCT`) are printed through `%g`, stripping only
  the float artifacts of the server value (e.g. `14.000000000000002` → `14`)
  while keeping effective precision, so delta-based unit-cost measurement
  still works. The verdict is computed on the raw value; `VERDICT` is
  authoritative at the boundary.
- The mid-run watchdog (FR-08) is repositioned as insurance; batch splitting
  (FR-09) is the first line of defense.
- The default resume cushion after `DEFER` is documented as 120 seconds
  (`SECONDS_TO_RESET + 120`, FR-07).

### Fixed
- A non-numeric `used_percentage` (corrupted state) now returns `UNKNOWN`
  instead of being coerced to 0 and green-lighting with the full headroom
  (latent since 0.1.0 for the verdict; the new `HEADROOM_PCT` raised the
  stakes).
- Numeric output is locale-independent (`LC_ALL=C`), so the decimal separator
  stays a period under comma-decimal locales.
- The budget-sizing example keeps `UNKNOWN` fail-open (it no longer locks out
  environments where the gate cannot see `rate_limits`), and the docs define
  what to do when even the smallest batch does not fit at `OK` (treat it as
  `DEFER` and schedule after the reset) and when a measured delta reads 0
  (re-measure; never size batches with a unit cost of 0).

## [0.1.0] - 2026-06-23

First public release.

### Added
- `rate-guard.sh`: a pure-shell gate (no LLM, zero tokens) that reads the
  status-line `rate_limits` copy and returns `VERDICT=OK|DEFER|UNKNOWN`
  (exit `0`/`10`/`20`) by comparing `five_hour.used_percentage` against a
  threshold (default 80%).
- `SECONDS_TO_RESET` in the gate output (the wait until the reset, computed as
  `RESETS_AT - now`), so an agent can schedule a resume from the gate output
  alone, without knowing the current time.
- `statusline-tee.sh`: a non-destructive tee block that persists `rate_limits`
  to a state file with an atomic write.
- Documentation: `README.md` / `README.ja.md`, the full spec `docs/SPEC.md`
  (English) and `docs/SPEC.ja.md` (Japanese), and `examples/` (an operating
  contract snippet and a workflow-integration guide).
- `.github/workflows/shellcheck.yml`: runs ShellCheck on every push and pull
  request.

[Unreleased]: https://github.com/otoph/claude-rate-guard/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/otoph/claude-rate-guard/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/otoph/claude-rate-guard/releases/tag/v0.1.0
