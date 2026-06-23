# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/otoph/claude-rate-guard/releases/tag/v0.1.0
