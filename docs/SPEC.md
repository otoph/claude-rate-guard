# rate-guard requirements specification

| Item | Content |
| -------- | ---------------------------------------------------------------------- |
| Document ID | SPEC-RATEGUARD-001 |
| Intended readers | Architects / implementing agents / adopters in each repository |
| Scope | **Repository-agnostic** (designed to be ported widely). Portable to any repository that runs under Claude Code. Written on the assumption that it can also be **newly introduced into an environment that has no status line configured yet**. |
| Prerequisites | Claude Code (a build that has the status-line mechanism **and** the Workflow tool). `bash` / `jq` / `awk` / `date` available. **Fetching `rate_limits` requires a Claude.ai Pro/Max subscription** (§2.4). **A means of supplying the current time to the agent every turn** (e.g. injecting the time via a `UserPromptSubmit` hook), because the scheduling/announcements of FR-07/08 depend on time (§2.4 · §8). |

> 日本語の原典は [`SPEC.ja.md`](./SPEC.ja.md)。

---

## 1. Purpose of this document

This document is the requirements specification for **rate-guard**, an auxiliary component that **judges, before launch, how much of Claude Code's 5-hour session-usage window (and 7-day window) remains, and automatically defers the launch of a long-running workflow to the next window when the remaining headroom is below a threshold**. The goal is to let an adopter in a different environment — **including repositories/users that have not yet configured a status line** — build an equivalent from scratch based on this document.

This component is **advisory (non-enforcing)**. Rather than the harness mechanically blocking tool calls, it **keeps the decision material on disk at all times, and the agent consults it just before launch and defers on its own judgment**. Enforcement (blocking via hooks) is out of scope (§10 · see Appendix C).

### 1.1 Problem solved

- An agent inside Claude Code **has no API/tool that returns its own 5-hour window consumption rate or the next window's reset time**. The `Workflow` `budget` is "the output-token target for that turn", which is a different thing from the account's session window.
- On the other hand, **the status-line command's stdin is given `rate_limits` (authoritative, server-provided values)**. Capturing that lets code make the decision.
- Launching a long-running workflow with little headroom left means **the window runs out mid-flight and the workflow is interrupted / totally lost**. Rejecting it before launch avoids the fragile stop/resume operation itself.

---

## 2. Background and goals

### 2.1 Background

In an operation that runs long (tens of minutes) processing inside a single-turn workflow, exhaustion of the 5-hour window produces the worst failure: "hit mid-flight → interrupted". The post-hit message does not reach the agent's context in a form it can actively retrieve, so after-the-fact handling is unreliable. **Deciding launchability before launch (a pre-flight gate)** is the most robust approach.

### 2.2 Goals

- **Continuously keep on disk (tee)** the authoritative values that the status-line command receives. For environments with no status line configured, **newly configure** a status-line command that has this capture built in (Appendix A-1).
- Provide **a pure-code decision tool** that reads that capture and **compares the 5-hour window usage rate against a threshold (default 80%) to return launchability**.
- Define the behavioral contract by which the agent **calls the decision tool right before launching a long-running workflow, and defers to the next window on DEFER** (pre-flight · FR-06).
- For **a single workflow that exceeds one window (5h)**, define the behavioral contract of a mid-run watchdog that polls the decision tool while running and, on threshold breach, **stops at a phase boundary → resumes automatically after reset via `resumeFromRunId`** (FR-08).

### 2.3 Scope boundary (**must read**)

| Function | In / Out of scope | Rationale |
| --------------------------------------------- | --------------- | --------------------------------------------------- |
| Newly configuring the status-line command / appending the tee | In | The only route to the authoritative values. Passive · free. In unconfigured environments, new creation is the starting point of adoption |
| rate_limit capture output (tee) from the status line | In | The only route to the authoritative values. Passive · free |
| 5-hour window threshold judgment (gate · pure code) | In | Arithmetic is code (no LLM) |
| The pre-flight deferral behavioral contract (agent side) | In | The primary purpose of this component |
| Scheduling the launch into the next window on DEFER | In | The reset time is in the capture, so reservation is deterministic |
| **mid-run watchdog** (monitor while running → on threshold breach, stop → resume automatically after reset) | **In** | Essential for completing a single task that exceeds one window. Pre-flight cannot save it (FR-08 · Appendix B) |
| **Enforcement (blocking via a PreToolUse hook)** | **Out** | A foot-gun that acts indiscriminately on all workflows. Decide separately (Appendix C) |
| Gating dispatcher-managed tasks (via Slack, etc.) | **Out** | For those, checkpoint → process exit → re-dispatch is the proper path |
| A 24/7 resident daemon | **Out** | The executor of the judgment is the agent. It only works while the session is running |

### 2.4 Applicability prerequisites and coverage (**must read · verify before adoption**)

For this gate to work on authoritative values (return `OK`/`DEFER`), the **target state** in the table below must hold. Under conditions that are not met, it **degrades to permanent/temporary `UNKNOWN`, fail-open**, and the gate is silently disabled (it does not block, but it does not protect). At adoption time, always make these degradation conditions known.

| Environment condition | Gate behavior | Action at adoption |
| --- | --- | --- |
| Interactive TUI & Pro/Max & status line configured & after first API response | **Normal** (OK/DEFER) | The target state this document aims for |
| **`statusLine.command` unset** | Permanent `UNKNOWN` (the state file is never generated) | Resolved by **newly configuring** it per §11 · Appendix A-1. The primary adoption route of this document |
| **headless / non-interactive launch** (`claude -p` · SDK · non-interactive cron) | State is not updated and goes stale → `UNKNOWN` | The status line fires only on interactive UI events. **Launch long-running WFs from an interactive session.** Routine headless use is outside this gate's coverage |
| **API-key billing (non Pro/Max)** | `rate_limits` itself never arrives on stdin → permanent `UNKNOWN` | This gate is inapplicable. It passes through fail-open; the hit itself is backstopped by the harness's rate-limit error |
| Before the first API response | Temporary `UNKNOWN` | Resolved after one round trip (not permanent) |
| **The agent is not supplied the current time** (no time-injection hook, etc.) | The gate's OK/DEFER itself is normal (the gate uses the shell's `date`). However, **the reservation-timing decisions and user announcements of FR-07/08 become unreliable** | Inject the current time every turn via `UserPromptSubmit` etc. (§8) |

- All degradations are **fail-open** (never block), so "it won't break", but the state of "thinking you're protected while you aren't" is dangerous. Per NFR-07, always surface `UNKNOWN` via `REASON`.
- **Time sense is a prerequisite of agent behavior (FR-06/07/08), not of the gate judgment (gate)**: the judgment itself holds via the shell's `date`, but the timing of deferral reservations and the announcements require time awareness.
- `rate_limits` appears on stdin **only after the first API response of a Claude.ai Pro/Max subscriber**, and `five_hour` / `seven_day` can independently be absent (§8 · per the official schema).

---

## 3. Glossary

| Term | Definition |
| --- | --- |
| **scope-(i)** | A `Workflow` tool launch that the agent runs directly within a conversation. The target of this gate |
| **status-line command** | The shell registered in `statusLine.command` of `settings.json`. Claude Code passes JSON on stdin and executes it on UI events. Refers to **the command itself, not the visible on-screen bar** |
| **tee** | The processing that copies the rate_limit state to a file each time the status-line command runs |
| **gate** | The decision script that reads the capture and returns launchability (OK/DEFER/UNKNOWN) |
| **5-hour window / 7-day window** | The rolling windows of Claude's session usage caps |
| **`used_percentage`** | The consumption rate of that window (0–100, server-provided) |
| **`resets_at`** | The time that window resets (UNIX epoch seconds, server-provided) |
| **fail-open** | A safe-side design: when the decision material is missing/stale, do not block — allow launch (and surface the uncertainty) |

---

## 4. Overall structure and data flow

```
[Claude Code core]
   │  passes stdin JSON every time the status-line command runs (on UI events · interactive TUI only)
   │  (.rate_limits.five_hour.{used_percentage,resets_at} etc. = authoritative values)
   ▼
[statusline-command.sh]  ──(tee: atomic write)──▶  [rate_limit_state.json]
   │                                                      │
   │ (optionally render to terminal; tee has zero side effects and keeps rendering even on failure)  │ read-only
   ▼                                                      ▼
[terminal UI (optional · may be empty)]            [rate-guard.sh]  ──▶  VERDICT=OK|DEFER|UNKNOWN
                                                                        (exit 0 / 10 / 20)
                                                            │
                                                            ▼
                                      [agent]  runs the gate right before launch and
                                        OK→launch / DEFER→reserve for next window / UNKNOWN→launch+warn
```

The data is **one-directional**: core → tee → state file → gate → agent behavior. The state file is read-only from the gate. **The presence of a visible bar is irrelevant to this flow**: even with empty stdout the status-line command runs, and the tee side effect runs (§8).

---

## 5. Functional requirements

### FR-01 Status-line command (with capture tee built in)

- If the target environment has **no** status-line command, **newly configure the command this component provides (Appendix A-1)**. If one exists, **append** the tee block (**non-destructive**: do not change the existing rendering output or exit behavior at all).
- From the stdin JSON the status-line command receives, extract `rate_limits.five_hour.{used_percentage,resets_at}` · `rate_limits.seven_day.{...}` · `context_window.used_percentage`, **attach the current time `written_at` (epoch seconds)**, and write to the state file.
- **Atomic write required**: write to a temp file and replace with `mv -f`. Prevents partial reads by the reader.
- **A write failure must not obstruct rendering**: isolate the tee from rendering, and have the script `exit 0` at the end. However, **do not swallow failures — leave a trace**: only on failure, record one line to `~/.claude/rate-guard.tee.log` (so that the protection silently disappearing on a quiet failure is detectable · NFR-09).
- If the relevant fields are absent from stdin (non Pro/Max · before first response · version differences, etc.), set those values to **`null`** and keep the JSON itself always valid.
- **The visible bar is optional**: emptying stdout shows nothing on screen, but the tee side effect still runs. To show a bar, use / replace the display block of Appendix A-1.

### FR-02 State-file schema (interface contract · identical to §7)

Default path `~/.claude/rate_limit_state.json`.

```json
{
  "written_at": 1781753494,
  "five_hour": { "used_percentage": 17, "resets_at": 1781758200 },
  "seven_day": { "used_percentage": 42, "resets_at": 1781791200 },
  "context":   { "used_percentage": 10 }
}
```

- Numbers are the server-provided values as-is (decimals allowed). Unobtainable fields are `null`.
- `written_at` is the basis for the freshness check (FR-04).

### FR-03 gate (decision script)

- Read the state file and compare `five_hour.used_percentage` against the **threshold (default 80)**.
- **Judgment and exit codes**:
  - `used_percentage < threshold` → `VERDICT=OK`, exit **0**
  - `used_percentage >= threshold` → `VERDICT=DEFER`, exit **10** (the boundary value is on the DEFER side)
  - material missing or stale → `VERDICT=UNKNOWN`, exit **20**
- **Output is machine-readable `KEY=VALUE` lines** (stdout): `VERDICT` / `FIVE_HOUR_PCT` / `RESETS_AT` / `RESETS_AT_HUMAN` / `REASON`.
- Do floating-point comparison with `awk` etc. (do not round to bash integer comparison).
- **Use no LLM at all** (coverage and arithmetic are code).
- **Threshold sanity**: if `RATE_GUARD_THRESHOLD` falls outside the valid range `[10,95]`, **warn to stderr** (misconfiguration detection). Continue the judgment and **do not pollute the stdout KEY=VALUE contract**. This catches both setting it too high (defenseless) and too low (permanent-DEFER deadlock) early.

### FR-04 Freshness / absence = fail-open (surface and distinguish the cause)

- Return `UNKNOWN` (exit 20) when the state file **does not exist / `written_at` is missing or non-numeric / `five_hour.used_percentage` is `null` / `written_at` is older than `STALE_SECONDS` (default 900 s) from now** — any one of these.
- UNKNOWN **does not block** (fail-open). The reason: avoid wrongly stopping all workflows for first-run not-yet-generated, post-idle staleness, non Pro/Max, or non-firing under headless. The hit itself is backstopped by the harness's rate-limit error.
- **Do not stay silent — distinguish the cause via `REASON`** (the same UNKNOWN calls for different handling):
  - no state file → "`statusLine.command` unset or tee not yet run"
  - `written_at` missing/non-numeric → "suspected state corruption / tee failure (see `rate-guard.tee.log`)". Validate as integer before arithmetic and return UNKNOWN without crashing even on non-numeric
  - `used_percentage` is `null` → "**rate_limits absent = non Pro/Max or before first response**. Gate inoperative here" (possibly structural · permanent)
  - stale → "stale. **If mid-session, suspect tee failure** (see `rate-guard.tee.log`)" (temporary or failure)

### FR-05 Configuration parameters (overridable via environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `RATE_GUARD_THRESHOLD` | `80` | The lower bound of usage rate at which launch is stopped (DEFER at this value or above) |
| `RATE_GUARD_STALE_SECONDS` | `900` | A capture older than this is UNKNOWN |
| `RATE_GUARD_STATE_FILE` | `~/.claude/rate_limit_state.json` | Path of the capture (for test substitution) |

- The **valid range of `RATE_GUARD_THRESHOLD` is `[10,95]`** (outside it triggers the FR-03 warning). Even when you want a permanent change, **pass it via env at gate-call time, not in `settings.json`** — fixing a threshold below the steady-state usage rate makes it exceed the threshold again after reset, causing a **permanent-DEFER deadlock** (§12).

### FR-06 Agent behavioral contract (the core of being non-enforcing)

In scope-(i), **right before launching a long-running workflow that runs to completion in a single shot**, run the gate and follow the `VERDICT`:

| VERDICT | Behavior |
| --- | --- |
| `OK` | Launch as-is |
| `DEFER` | **Do not launch.** Reserve the launch right after `RESETS_AT`, and tell the user "deferred to the next window (`RESETS_AT_HUMAN`)" |
| `UNKNOWN` | Launch fail-open, but explicitly state "remaining budget unknown" (kindly also note which of the §2.4 degradation conditions may apply) |

- State this contract clearly in **the agent memory or operating documentation (CLAUDE.md etc.) of the porting-target repository**, so it is referenced even across context summarization (because, being non-enforcing, it depends on recall).

### FR-07 Scheduling on DEFER

- The reservation time is `RESETS_AT` (+ a small margin).
- If reset is **within 1 hour**, use a short-sleep mechanism (e.g. `ScheduleWakeup`, max 3600 s). If **further out**, use a one-shot cron (e.g. `CronCreate`) or a chain of sleeps.
- **Re-check at resume**: after the reservation fires, run the gate once more right before launching, and launch only after confirming `OK` (to prevent thrash — immediate re-hit from reset-estimate drift).
- **Time sense is a prerequisite**: the "within 1 hour or beyond" branch and the `RESETS_AT_HUMAN` user announcement depend on **the agent knowing the current time**. A means of supplying the current time every turn (e.g. time injection via a `UserPromptSubmit` hook) is an operating condition (§2.4 · §8).

### FR-08 mid-run watchdog (completing a single workflow that exceeds one window)

Pre-flight (FR-06) only "doesn't start when headroom is scarce"; it **cannot save a single task that starts from full and eats one whole window (5h)**. This is the in-flight monitoring that complements it.

- **Applicability**: a single workflow (prefer read-only) that passed pre-flight as `OK` but whose consumption may exceed one window.
- **Launch**: start the `Workflow` with `run_in_background` and keep the `runId`.
- **Polling**: the agent wakes at a coarse interval and runs `rate-guard.sh`.
  - `OK` and running → re-schedule the next poll.
  - `DEFER` (≥ threshold) and running → **`TaskStop(runId)`** (the journal is preserved) → record `RESETS_AT` and reserve resume (same scheduling as FR-07).
  - completion notification received → end the loop (collect the artifacts).
- **Resume**: reservation fires → re-check with `rate-guard.sh` → `OK` → continue with `Workflow(scriptPath, resumeFromRunId=runId)` → re-enter the poll loop. **If it spans multiple windows, repeat on every DEFER**.
- **Why actively stop at 80%**: if you wait for the 100% hit, the Workflow's `agent()` is swallowed into `null` after retries and a **degraded result is returned silently** (silent truncation). A `TaskStop` at the threshold interrupts cleanly and leaves the journal, avoiding this.
- **Safety**: because the stop is an external poll, it **cannot guarantee a phase boundary**. An interrupted agent re-runs on resume, so **read-only WFs are harmless**; side-effecting WFs are premised on idempotency keys (loose-coupling contract #4).
- Detailed procedure in Appendix B.

---

## 6. Non-functional requirements

| ID | Requirement |
| --- | --- |
| NFR-01 | **Non-destructive**: do not change the existing status line's rendering / exit behavior. A tee failure does not propagate to rendering. New configuration also does not break Claude Code's default behavior |
| NFR-02 | **Minimal added latency**: keep the tee to a single `jq` call |
| NFR-03 | **Zero model-quota cost**: the judgment is pure shell. Consumes no LLM turn |
| NFR-04 | **Durable**: the decision material is on disk and does not depend on the agent's loss of context (summarization · cache eviction) |
| NFR-05 | **Portable**: the only dependencies are `bash`/`jq`/`awk`/`date`. Reset formatting works with either GNU or BSD `date` (both syntaxes fall through) |
| NFR-06 | **Fail-open safe**: when unknown, do not block — surface the uncertainty |
| NFR-07 | **No silent truncation**: always explain DEFER/UNKNOWN via `REASON`, and announce deferrals to the user |
| NFR-08 | **Low-cost mid-run poll**: monitoring polls run at a coarse interval (mindful of cache retention), each doing only "read state + numeric compare". Near the cap, monitoring itself must not eat up the window |
| NFR-09 | **Observability of tee failure**: the tee does not swallow failures — it leaves a trace (`rate-guard.tee.log`). It does not break rendering (`exit 0` at the end). Makes it detectable when the protection silently disappears on a quiet failure |

---

## 7. Interface contract (promises that must not be broken)

1. **The state-file schema** (FR-02). Do not change key names, the epoch-seconds `written_at`, or the `null` allowance.
2. **The gate stdout contract**: `KEY=VALUE` lines · key names `VERDICT/FIVE_HOUR_PCT/RESETS_AT/RESETS_AT_HUMAN/REASON`.
3. **Exit codes**: `0=OK / 10=DEFER / 20=UNKNOWN`. Callers may branch on these codes.
4. The data flow is one-directional (§4). The gate treats the state as **read-only** and does not rewrite it.

---

## 8. Prerequisites and diffs at adoption (**must verify before adoption**)

- **The most important prerequisite (observability)**: first confirm whether the target Claude Code **actually passes** `rate_limits.five_hour.used_percentage` / `resets_at` on the status-line stdin (insert an echo debug into `statusLine.command` / inspect the generated state file). In environments where it is not passed (the §2.4 degradation conditions), this component degrades to permanent `UNKNOWN` (fail-open) and the gate does not function.
- **The status-line firing conditions (official)**: `statusLine.command` runs **after a new assistant message · when `/compact` completes · on permission-mode change · on Vim-mode toggle**, and updates are debounced by 300ms. **If unset, it never runs.** These are interactive UI events; design on the premise that they do not fire under headless/print mode (§2.4).
- **The `rate_limits` provisioning condition (official)**: `rate_limits` appears on stdin **after the first API response of a Claude.ai Pro/Max subscriber**. `five_hour` / `seven_day` can independently be absent. It does not arrive for API-key billing users.
- **Independence of the visible bar (official)**: even if the script outputs nothing to stdout, the status-line command runs and side effects such as file writes run. Therefore **the tee works even in an operation that shows no visible bar**.
- **Version dependence of field paths**: the key names above may change by Claude Code version. Confirm by inspecting the real environment's stdin JSON.
- **`date` dialects**: try both GNU (`date -d @epoch`) and BSD (`date -r epoch`) for reset formatting, falling through.
- **Path differences**: default to under `~/.claude`, but keep it overridable via environment variables.
- **Keep the state file out of git** (volatile state local to the execution environment).

---

## 9. Acceptance criteria (test cases)

The implementation must satisfy the following.

| # | Input | Expected |
| --- | --- | --- |
| 1 | Pass a normal stdin including rate_limits through the tee | A valid JSON state file is generated atomically |
| 2 | stdin not including rate_limits (non Pro/Max, etc.) | Each value is `null` · JSON is valid |
| 3 | `used_percentage=42`, threshold 80 | `VERDICT=OK` / exit 0 |
| 4 | `used_percentage=85`, threshold 80 | `VERDICT=DEFER` / exit 10 |
| 5 | `used_percentage=80` (boundary) | `VERDICT=DEFER` (`>=`) / exit 10 |
| 6 | `written_at` 1200 s ago (>900) | `VERDICT=UNKNOWN` / exit 20 · REASON makes staleness explicit |
| 7 | No state file (equivalent to status line unset) | `VERDICT=UNKNOWN` / exit 20 (fail-open) · REASON makes not-generated explicit |
| 8 | `RATE_GUARD_THRESHOLD=30`, `used_percentage=42` | `VERDICT=DEFER` |
| 9 | Run the gate against real data (after the tee fired in a real session) | OK/DEFER returns on authoritative values (smoke) |
| 10 | Newly configure Appendix A-1 in an environment with no status line, and do one round trip interactively | The state file is generated, and the gate returns authoritative values (new-adoption smoke) |
| 11 | Run the existing status line standalone after appending the tee | The existing rendering is unchanged (non-destructive check) |
| 12 | `five_hour.used_percentage=null` (equivalent to non Pro/Max) | `UNKNOWN` / exit 20 · REASON makes "rate_limits absent = gate inoperative" explicit |
| 13 | `RATE_GUARD_THRESHOLD=5` / `=99` | Misconfiguration warning to stderr · the stdout KEY=VALUE is unchanged |
| 14 | Force the tee write to fail (permissions/disk, etc.) | The status line `exit 0`s (rendering continues) · the failure is recorded to `rate-guard.tee.log` |
| 15 | `written_at` non-numeric (`"abc"`/decimal/hex, etc.) | `UNKNOWN` / exit 20 (contract-compliant without crashing) · REASON makes the non-numeric explicit |

---

## 10. Known limitations / non-goals

- **Dependence on the status-line command**: the tee parasitizes on the status-line command's execution. **If unset, permanent `UNKNOWN`.** Adoption starts with configuring the Appendix A-1 command (§2.4 · §11).
- **Interactive-session only**: the executor of the judgment/monitoring is the agent, and it works only while the session is running (`TaskStop`/`resumeFromRunId` are session-bound). **Under headless/non-interactive launch the status line does not fire and the capture goes stale**, so launch long-running WFs from an interactive session. Close the session and the monitor is gone = the mid-run watchdog (FR-08) also stops.
- **Pro/Max only**: `rate_limits` is provided only to Claude.ai Pro/Max subscribers. Under API-key billing it is permanently `UNKNOWN` (fail-open pass-through) and this gate is inapplicable.
- **A mid-run stop does not guarantee a phase boundary**: because the stop is an external poll, the interruption point is indeterminate. An interrupted agent re-runs on resume, so read-only WFs are harmless, but side-effecting WFs presuppose idempotency keys.
- **Detection only, non-enforcing**: enforcement (blocking via hooks) is a separate decision (Appendix C). This document presupposes "the agent consults it itself".
- **Targets scope-(i) only**: dispatcher-managed tasks are out of scope.
- **Staleness while idle**: when rendering stops, the capture goes stale. But the gate target is a running workflow, so the real harm is small, and the freshness check (FR-04) absorbs it via UNKNOWN.
- **Authoritative but version-dependent**: the values are server-provided (not estimates), but the stdin schema depends on the Claude Code version (§8).

---

## 11. Rollout procedure (new adoption)

Starting from an environment with no status line, adopt with minimal steps. If a status line already exists, read steps 2–3 as "appending the tee block".

1. **Verify prerequisites** (§2.4 · §8): confirm whether the target is a **Pro/Max** subscriber and **used as an interactive TUI**. If neither holds, make the adopter aware it becomes permanent `UNKNOWN` (fail-open).
2. **Place the status-line command**: put the Appendix A-1 `statusline-command.sh` under `~/.claude/` and grant execute permission (`chmod +x`).
3. **Wire up settings.json**: point `statusLine.command` at that script (see the configuration example at the end of Appendix A-1). If a status line already exists, append only the tee block to that command and do not change the wiring.
4. **Place the gate**: place the Appendix A-2 `rate-guard.sh` and grant execute permission.
5. **State the behavioral contract**: write FR-06 (pre-flight) and FR-08 (mid-run watchdog) into that repo's agent memory / operating documentation.
6. **Acceptance check**: run the §9 tests, especially #10 (new-adoption smoke), in an interactive session, and confirm state generation → the gate returns authoritative values.
7. (Optional) To fully eliminate misses, consider Appendix C (enforcement hook).

---

## 12. Operating promises (accident prevention)

Even if the gate mechanism itself is sound, mishandled operation causes accidents. Rules to keep at the adopting site.

- **Prefer read-only WFs under the watchdog**: a mid-run stop does not guarantee a phase boundary, and an interrupted agent re-runs on resume. **A WF with side effects (file writes / external posting / DB updates / uploads) requires idempotency keys (`request_hash`/`batch_id`, etc.).** Do not put a WF that cannot be made idempotent on the watchdog.
- **Make detached subprocesses self-defend**: if a WF launches an external process that does not die on `TaskStop`, **give that process itself a max run time / self-gate**. Closing the session removes the monitor (agent), so it must be able to self-terminate even with no monitor present.
- **Fix polls at a coarse interval, and back off near the reset boundary**: every wakeup consumes tokens. To avoid monitoring itself eating the window near the cap, keep the interval in minutes, and suppress reset-estimate-drift thrash with a re-check guard + backoff (NFR-08).
- **Leave slack for heavy single-shot WFs**: pre-flight only sees the usage rate at launch and does not know the WF's consumption. For a WF that could eat one window, **lower the threshold to secure slack** (e.g. 80→60) or switch to the **FR-08 watchdog premise**.
- **Pass the threshold via env**: fixing a permanent change in `settings.json` etc. with a threshold below the steady-state usage rate causes **re-exceeding the threshold after reset → permanent-DEFER deadlock**. Keep threshold changes in the env at gate-call time (one-off).

---

## Appendix A: Reference implementation

### A-1. The status-line command (`~/.claude/statusline-command.sh` · tee built in)

A self-contained script that **can be newly configured as-is** into an environment with no status line. It extracts rate_limit from stdin to write the capture (tee), and optionally renders a one-line visible bar. If you do not need the visible bar, replace the trailing "visible bar" block with `:` (a no-op) — the tee side effect keeps working.

```bash
#!/usr/bin/env bash
# Claude Code status-line command + rate-limit capture (tee).
# Reads the state JSON on stdin, persists the rate-guard state, and optionally renders one line.
input=$(cat)

# --- Extract rate_limit etc. (exists only on Pro/Max; if absent → empty → nulled downstream) ---
five_pct=$(echo   "$input" | jq -r '.rate_limits.five_hour.used_percentage  // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at         // empty')
week_pct=$(echo   "$input" | jq -r '.rate_limits.seven_day.used_percentage   // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at         // empty')
used_pct=$(echo   "$input" | jq -r '.context_window.used_percentage          // empty')

# --- tee: capture the rate-limit state atomically (isolated from rendering · failures leave a trace) ---
state_file="$HOME/.claude/rate_limit_state.json"
tee_log="$HOME/.claude/rate-guard.tee.log"
now_epoch=$(date +%s)
if ! { jq -n \
      --argjson now "$now_epoch" \
      --arg fp "${five_pct:-}" --arg fr "${five_reset:-}" \
      --arg wp "${week_pct:-}" --arg wr "${week_reset:-}" \
      --arg cp "${used_pct:-}" \
      'def tonum: if . == "" then null else (tonumber? // null) end;
       { written_at: $now,
         five_hour: { used_percentage: ($fp|tonum), resets_at: ($fr|tonum) },
         seven_day: { used_percentage: ($wp|tonum), resets_at: ($wr|tonum) },
         context:   { used_percentage: ($cp|tonum) } }' \
      > "${state_file}.tmp" 2>/dev/null && mv -f "${state_file}.tmp" "$state_file" 2>/dev/null; }; then
  printf '%s tee failed (jq or mv)\n' "$(date -Is 2>/dev/null || date)" >> "$tee_log" 2>/dev/null
fi

# --- Visible bar (optional · cosmetic). If not needed, replace the next 3 lines with `:` ---
model=$(echo "$input" | jq -r '.model.display_name // empty')
printf '%s' "${model:+$model}"
[ -n "$five_pct" ] && printf ' · 5h %s%%' "$five_pct"

exit 0   # tee failure / short-circuit of the visible bar → non-zero exit would blank the status line; avoid it
```

Wiring into `settings.json` (for an unconfigured environment):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-command.sh"
  }
}
```

> In an environment that already has a status line, do not change the wiring; append only the "tee" block above into that existing command. If the extraction (`five_pct` etc.) is undefined, append the extraction lines too.

### A-2. `rate-guard.sh` (full decision script)

```bash
#!/usr/bin/env bash
# Pure code (no LLM) that judges whether there is "headroom to run one shot" in the 5-hour session window.
# Output: KEY=VALUE lines / exit codes 0=OK 10=DEFER 20=UNKNOWN(fail-open)
set -u
THRESHOLD="${RATE_GUARD_THRESHOLD:-80}"
STALE_SECONDS="${RATE_GUARD_STALE_SECONDS:-900}"
STATE_FILE="${RATE_GUARD_STATE_FILE:-$HOME/.claude/rate_limit_state.json}"

# Threshold sanity: outside [10,95] is suspected misconfiguration → warn to stderr (judgment continues · stdout contract unchanged)
if [ "$(awk -v t="$THRESHOLD" 'BEGIN{print (t+0<10 || t+0>95) ? 1 : 0}')" = "1" ]; then
  printf 'WARN: RATE_GUARD_THRESHOLD=%s outside [10,95]; likely misconfigured\n' "$THRESHOLD" >&2
fi

emit() { printf '%s\n' "$@"; }
fmt_reset() {
  local epoch="$1"
  [ -z "$epoch" ] && { echo ""; return; }
  date -d "@${epoch}" "+%m/%d %H:%M" 2>/dev/null || date -r "${epoch}" "+%m/%d %H:%M" 2>/dev/null
}

if [ ! -f "$STATE_FILE" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=" "RESETS_AT=" "RESETS_AT_HUMAN=" \
       "REASON=state file not found ($STATE_FILE); statusLine.command unset or tee not run yet"
  exit 20
fi

now=$(date +%s)
written=$(jq -r '.written_at // empty' "$STATE_FILE" 2>/dev/null)
pct=$(jq -r '.five_hour.used_percentage // empty' "$STATE_FILE" 2>/dev/null)
reset=$(jq -r '.five_hour.resets_at // empty' "$STATE_FILE" 2>/dev/null)
reset_h=$(fmt_reset "$reset")

case "$written" in
  ''|*[!0-9]*)
    emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=${pct}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" \
         "REASON=state malformed (written_at missing or non-numeric); statusline tee may be broken (see ~/.claude/rate-guard.tee.log)"
    exit 20 ;;
esac
if [ -z "$pct" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" \
       "REASON=rate_limits absent (five_hour.used_percentage null); non Pro/Max or before first API response -- gate inoperative here"
  exit 20
fi

age=$(( now - written ))
if [ "$age" -gt "$STALE_SECONDS" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=${pct}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" \
       "REASON=state stale (${age}s > ${STALE_SECONDS}s); if mid-session the statusline tee may be broken (see ~/.claude/rate-guard.tee.log)"
  exit 20
fi

over=$(awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN{print (p+0 >= t+0) ? 1 : 0}')
if [ "$over" = "1" ]; then
  emit "VERDICT=DEFER" "FIVE_HOUR_PCT=${pct}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" \
       "REASON=5h usage ${pct}% >= threshold ${THRESHOLD}%; defer launch until reset"
  exit 10
fi

emit "VERDICT=OK" "FIVE_HOUR_PCT=${pct}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" \
     "REASON=5h usage ${pct}% < threshold ${THRESHOLD}%"
exit 0
```

---

## Appendix B: mid-run watchdog operating procedure (FR-08 details)

The procedure for completing a single workflow that exceeds one window (5h).

**Substance**: not a new program, but a monitoring loop the agent runs on top of existing primitives (`rate-guard.sh` + the Workflow tool's standard `run_in_background` / `TaskStop` / `resumeFromRunId`). Because `TaskStop`/`resumeFromRunId` are session-bound, **the monitoring subject is the agent itself** (a bare cron cannot do it).

**Loop (pseudo-procedure)**:

```
launch:  runId = Workflow(scriptPath, run_in_background=true)

poll loop (wake at a coarse interval · run rate-guard.sh each time):
  VERDICT=OK    and running  → re-schedule the next poll
  VERDICT=DEFER and running  → TaskStop(runId)              # the journal is preserved
                               record RESETS_AT and reserve resume (same scheduling as FR-07)
  completion notification    → end the loop (collect the artifacts)

resume (when the reservation fires):
  re-check rate-guard.sh → confirm OK (thrash prevention)
  continue with Workflow(scriptPath, resumeFromRunId=runId, run_in_background=true)
  re-enter the poll loop (if spanning multiple windows, repeat on every DEFER)
```

**Design points**:

- **The value of actively stopping at 80%**: waiting for the 100% hit means the Workflow's `agent()` is swallowed into `null` after retries and **a degraded result is returned silently** (silent truncation). A `TaskStop` at the threshold interrupts cleanly and leaves the journal, avoiding this.
- **The stop point is indeterminate**: because of the external poll it does not stop at a phase boundary. The agent that was running at interruption re-runs on resume. **Read-only WFs (code review, etc.) are harmless.** A WF with side effects (file writes / external posting / DB updates / uploads) is limited to the range where idempotency keys (request_hash/batch_id, etc. = loose-coupling contract #4) can absorb double-firing.
- **Resume prerequisite**: the script must be deterministic (must not depend on `Date.now()`/randomness). With the same script + same args, completed agents are 100% cache-restored.
- **Detached subprocesses**: if the WF launches an external process, it does not die on `TaskStop`. On resume, do not re-launch but **poll an existing sentinel/lock (PID liveness)** to continue (detached+poll approach).
- **Poll cost**: each poll is only "read state + numeric compare". Keep the interval coarse (mindful of cache retention). Near the cap, monitoring itself must not eat the window (NFR-08).

## Appendix C: Upgrade to enforcement (PreToolUse hook) (optional)

Only when you want to fully eliminate misses (the agent forgetting to run the gate / recall lapses).

- A PreToolUse hook on the `Workflow` tool runs `rate-guard.sh`, and on `DEFER` blocks the tool call + returns a reason.
- **Cost**: acts indiscriminately on all Workflow calls (lightweight calls included). A foot-gun that can fully block everything on a script bug. Exception handling needs a separate bypass mechanism (env flag · specific-label exclusion).
- **Limitation**: what a hook can harden is only "blocking the launch". The follow-through of deferral reservation and user announcement still remains agent behavior (FR-06/07).
- When adopting, since changing the configuration file (`hooks` in `settings.json`) = changing the behavior of all sessions, introduce it only with explicit approval.
