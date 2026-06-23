# rate-guard requirements specification

| Item | Content |
| -------- | ---------------------------------------------------------------------- |
| Document ID | SPEC-RATEGUARD-001 |
| Intended readers | Designers / implementing agents / adopters in each repository |
| Scope | **Not tied to a specific repository** (meant to be rolled out to other repositories too). It can be moved to any repository that runs under Claude Code. Written on the assumption that it can also be **newly installed in an environment that has no status line set up yet**. |
| Prerequisites | Claude Code (a version that has the status-line mechanism and the Workflow tool). `bash` / `jq` / `awk` / `date` must be available. **Reading `rate_limits` requires a Claude.ai Pro/Max plan** (§2.4). Giving the agent the current time each turn (for example, through a `UserPromptSubmit` hook) is **recommended** for the FR-07/08 wall-clock notifications; the gate's `SECONDS_TO_RESET` covers the scheduling itself (§2.4, §8). |

> 日本語の原典は [`SPEC.ja.md`](./SPEC.ja.md)。

---

## 1. What this document is

"**rate-guard**" is a helper tool that **checks how much of Claude Code's 5-hour usage window (and 7-day window) is left before launch, and automatically defers the launch of a long-running workflow to the next window when little is left**. This document is its requirements specification. The goal is that an adopter in another environment, including one that has not set up a status line yet, can read it and build the same thing from scratch.

The tool **only detects; it does not enforce**. Instead of the harness mechanically blocking tool calls, it **keeps the decision material on disk at all times, and the agent reads it just before launch and defers on its own judgment**. Enforcement (blocking through a hook) is out of scope for this document (see §10 and Appendix C).

### 1.1 The problem it solves

- An agent in Claude Code **has no API or tool that returns its own 5-hour usage rate or the next window's reset time**. The `Workflow` `budget` is "the output-token target for that turn", which is separate from the account's usage window.
- On the other hand, **the status-line command's standard input is given `rate_limits` (the authoritative values the server returns)**. If you save those, you can decide in code.
- If you launch a long-running workflow with little left, **the window runs out partway through, the workflow is interrupted, and the whole run is wasted**. Stopping it before launch avoids the fragile stop-and-resume operation itself.

---

## 2. Background and goals

### 2.1 Background

When you run a long (tens of minutes) process as a single-turn workflow, running out of the 5-hour window leads to the worst failure: "window runs out partway, then interrupted". The message after the window runs out does not reach the agent's context in a usable form, so handling it after the fact is unreliable. **Deciding whether to launch before launch (a pre-flight gate)** is the most robust approach.

### 2.2 Goals

- **Always save to disk (tee)** the authoritative values the status-line command receives. For an environment with no status line, **newly set up** a status-line command with this saving built in (Appendix A-1).
- Provide a **code-only decision tool** that reads that copy and **compares the 5-hour usage rate against a threshold (default 80%) to return whether launch is allowed**.
- Define the behavior rule by which the agent **calls the decision tool right before launching a long-running workflow and, on DEFER, defers to the next window** (pre-flight, FR-06).
- For a **single workflow that exceeds one window (5 hours)**, define the mid-run watchdog rule: monitor with the decision tool while it runs and, when the threshold is reached, **stop at a boundary and resume automatically after the reset with `resumeFromRunId`** (FR-08).

### 2.3 Scope boundary (**must read**)

| Function | In / Out of scope | Reason |
| --------------------------------------------- | --------------- | --------------------------------------------------- |
| Newly setting up the status-line command / appending the tee | In | The only route to the authoritative values. Passive and free. In an unset environment, creating it is where adoption starts |
| Saving the rate_limit copy (tee) from the status line | In | The only route to the authoritative values. Passive and free |
| The 5-hour threshold decision (gate, code only) | In | The calculation is done in code (no LLM) |
| The pre-flight deferral behavior rule (agent side) | In | The main purpose of this tool |
| Scheduling the launch into the next window on DEFER | In | The reset time is in the copy, so it can be scheduled with a fixed procedure |
| **mid-run watchdog** (monitor while running, stop on threshold, resume automatically after reset) | **In** | Needed to finish a single task that exceeds one window. Pre-flight cannot save it (FR-08, Appendix B) |
| **Enforcement (blocking with a PreToolUse hook)** | **Out** | A risk that acts on every workflow uniformly. Decide separately (Appendix C) |
| Gating dispatcher-managed tasks (through Slack, etc.) | **Out** | For those, "stop at a boundary, exit the process, re-dispatch" is the right path |
| A program that stays resident 24 hours | **Out** | The agent runs the decision. It works only while the session is running |

### 2.4 Prerequisites and coverage (**must read, check before adoption**)

For this gate to work on authoritative values (return `OK`/`DEFER`), the **target state** in the table below must hold. When it does not, the gate **falls back to the safe side, switching to a permanent or temporary `UNKNOWN`**, and is silently disabled (it does not block, but it does not protect either). At adoption time, always make these fallback conditions known.

| Environment condition | Gate behavior | Action at adoption |
| --- | --- | --- |
| Interactive TUI and Pro/Max and status line set up and after the first API response | **Normal** (OK/DEFER) | The state this document aims for |
| **`statusLine.command` not set** | Permanent `UNKNOWN` (the state file is never created) | Fixed by **newly setting it up** per §11 and Appendix A-1. The main adoption route in this document |
| **headless / non-interactive launch** (`claude -p`, SDK, non-interactive cron) | The state is not updated and goes stale, so `UNKNOWN` | The status line runs only on interactive UI actions. **Launch long-running workflows from an interactive session.** Routine headless use is out of scope |
| **API-key billing (non Pro/Max)** | `rate_limits` itself never reaches standard input, so permanent `UNKNOWN` | This gate cannot be used. It passes through on the safe side, and the harness's rate-limit error is the last stop for the window running out |
| Before the first API response | Temporary `UNKNOWN` | Fixed after one round trip (not permanent) |
| **The agent is not given the current time** (no time-passing hook, etc.) | OK/DEFER is normal, and DEFER/resume scheduling still works: the agent uses the gate's `SECONDS_TO_RESET` for the wait. Only wall-clock statements in the agent's own words are affected | **Recommended, not required.** Pass the current time with `UserPromptSubmit`, etc. for nicer notifications and a sanity check (§8) |

- Every fallback is on the **safe side (does not block)**, so "it will not break", but "thinking you are protected when you are not" is dangerous. As in NFR-07, always make `UNKNOWN` visible through `REASON`.
- **Knowing the time helps the agent's behavior (FR-06/07/08) but is not required for the gate flow.** The gate provides both the decision (shell `date`) and the wait (`SECONDS_TO_RESET`), so the agent can schedule without its own clock. Current-time injection stays recommended for wall-clock notifications and a sanity check.
- `rate_limits` appears on standard input **only after the first API response of a Claude.ai Pro/Max subscriber**, and `five_hour` / `seven_day` can each be missing (§8, per the official schema).

---

## 3. Glossary

| Term | Definition |
| --- | --- |
| **scope-(i)** | A `Workflow` tool launch that the agent runs directly within a conversation. The target of this gate |
| **status-line command** | The shell registered in `statusLine.command` of `settings.json`. Claude Code passes JSON on standard input and runs it on UI actions. It means **the command itself, not the bar visible on screen** |
| **tee** | The processing that copies the rate_limit state to a file each time the status-line command runs |
| **gate** | The decision script that reads the copy and returns whether launch is allowed (OK/DEFER/UNKNOWN) |
| **5-hour window / 7-day window** | The windows that count Claude's usage limit while moving over a fixed time span |
| **`used_percentage`** | The usage rate of that window (0–100, a value the server returns) |
| **`resets_at`** | The time that window resets (UNIX epoch seconds, a value the server returns) |
| **fail-open** | A safe-side design: when the decision material is missing or stale, do not block; allow launch (but state that it is unknown) |

---

## 4. Overall structure and data flow

```
[Claude Code core]
   │  passes standard-input JSON each time the status-line command runs (on UI actions, interactive TUI only)
   │  (.rate_limits.five_hour.{used_percentage,resets_at}, etc. = authoritative values)
   ▼
[statusline-command.sh]  ──(tee: atomic write)──▶  [rate_limit_state.json]
   │                                                      │
   │ (optionally render to screen; tee has no side effect on it and keeps drawing even on failure)  │ read-only
   ▼                                                      ▼
[terminal UI (optional, may be empty)]             [rate-guard.sh]  ──▶  VERDICT=OK|DEFER|UNKNOWN
                                                                        (exit 0 / 10 / 20)
                                                            │
                                                            ▼
                                      [agent]  runs the gate right before launch and
                                        OK→launch / DEFER→schedule for next window / UNKNOWN→launch + warn
```

The data flows in **one direction**: core → tee → state file → gate → agent behavior. The state file is read-only from the gate. **Whether a visible bar exists does not matter to this flow.** Even with empty standard output, the status-line command runs and the tee side effect runs (§8).

---

## 5. Functional requirements

### FR-01 Status-line command (with the tee built in)

- If the target environment has **no** status-line command, **newly set up the command this tool provides (Appendix A-1)**. If one exists, **append** the tee block (**non-destructive**: do not change the existing rendering output or exit behavior at all).
- From the standard-input JSON the status-line command receives, take `rate_limits.five_hour.{used_percentage,resets_at}`, `rate_limits.seven_day.{...}`, and `context_window.used_percentage`, **add the current time `written_at` (epoch seconds)**, and write to the state file.
- **An atomic write is required**: write to a temp file and replace it with `mv -f`. This stops the reader from reading a half-written state.
- **A write failure must not block rendering**: keep the tee separate from rendering, and have the script `exit 0` at the end. But **do not swallow failures; leave a trace**. Only on failure, record one line to `~/.claude/rate-guard.tee.log` (so a silent failure that removes the protection can be detected, NFR-09).
- If the relevant fields are missing from standard input (non Pro/Max, before the first response, version differences, etc.), set those values to **`null`** and keep the JSON itself always valid.
- **The visible bar is optional**: if you empty standard output, nothing shows on screen, but the tee side effect still runs. To show a bar, use or replace the display block in Appendix A-1.

### FR-02 State-file format (the interface agreement, same as §7)

Default path: `~/.claude/rate_limit_state.json`.

```json
{
  "written_at": 1781753494,
  "five_hour": { "used_percentage": 17, "resets_at": 1781758200 },
  "seven_day": { "used_percentage": 42, "resets_at": 1781791200 },
  "context":   { "used_percentage": 10 }
}
```

- Numbers are the values the server returns, as is (decimals allowed). Fields that cannot be obtained are `null`.
- `written_at` is the basis for the freshness check (FR-04).

### FR-03 gate (decision script)

- Read the state file and compare `five_hour.used_percentage` against the **threshold (default 80)**.
- **Decision and exit codes**:
  - `used_percentage < threshold` → `VERDICT=OK`, exit **0**
  - `used_percentage >= threshold` → `VERDICT=DEFER`, exit **10** (an equal value is on the DEFER side)
  - material missing or stale → `VERDICT=UNKNOWN`, exit **20**
- **The output is machine-readable `KEY=VALUE` lines** (standard output): `VERDICT` / `FIVE_HOUR_PCT` / `RESETS_AT` / `RESETS_AT_HUMAN` / `SECONDS_TO_RESET` / `REASON`. `SECONDS_TO_RESET` is `RESETS_AT - now` computed by the gate at run time (empty if the reset time is unknown, negative if it has already passed); an agent can schedule a resume from it without its own clock.
- Compare decimals with `awk`, etc. (do not round to a bash integer comparison).
- **Use no LLM at all** (decision and calculation are done in code).
- **Threshold validity check**: if `RATE_GUARD_THRESHOLD` is outside the valid range `[10,95]`, **warn to standard error** (to catch a misconfiguration). Continue the decision and **do not pollute the standard-output KEY=VALUE**. This makes both "set too high (defenseless)" and "set too low (stuck in permanent DEFER)" noticeable early.

### FR-04 Freshness and absence = safe side (show the cause, distinguished)

- Return `UNKNOWN` (exit 20) if any of these hold: the state file **does not exist / `written_at` is missing or not a number / `five_hour.used_percentage` is `null` / `written_at` is older than `STALE_SECONDS` (default 900 seconds) from now**.
- UNKNOWN **does not block** (fail-open). The reason is to avoid wrongly stopping every workflow because of a first-run not-yet-created file, going stale after idle time, non Pro/Max, or not firing under headless. The window running out itself is backstopped by the harness's rate-limit error.
- **Do not stay silent; distinguish the cause through `REASON`** (the same UNKNOWN calls for different handling):
  - no state file → "`statusLine.command` not set or tee not run yet"
  - `written_at` missing or not a number → "suspected state corruption / tee failure (see `rate-guard.tee.log`)". Check that it is an integer before calculating, and return UNKNOWN without crashing even when it is not a number
  - `used_percentage` is `null` → "**rate_limits absent = non Pro/Max or before the first response**. The gate does not work here" (possibly structural and permanent)
  - stale → "stale. **If mid-session, suspect a tee failure** (see `rate-guard.tee.log`)" (temporary or a failure)

### FR-05 Configuration parameters (overridable with environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `RATE_GUARD_THRESHOLD` | `80` | The lower bound of the usage rate that stops launch (DEFER at this value or above) |
| `RATE_GUARD_STALE_SECONDS` | `900` | A copy older than this is UNKNOWN |
| `RATE_GUARD_STATE_FILE` | `~/.claude/rate_limit_state.json` | The path of the copy (for swapping in tests) |

- The **valid range of `RATE_GUARD_THRESHOLD` is `[10,95]`** (outside it triggers the FR-03 warning). Even for a permanent change, **pass it through an environment variable at the gate call, not in `settings.json`**. Fixing a threshold below your usual usage rate means it exceeds the threshold again after the reset, leaving you **stuck in permanent DEFER** (§12).

### FR-06 Agent behavior rule (the core of the detect-only design)

In scope-(i), run the gate **right before launching a long-running workflow that runs to completion in one shot** and follow the `VERDICT`:

| VERDICT | Behavior |
| --- | --- |
| `OK` | Launch as is |
| `DEFER` | **Do not launch.** Schedule the launch right after `RESETS_AT`, and tell the user "deferred to the next window (`RESETS_AT_HUMAN`)" |
| `UNKNOWN` | Launch on the safe side, but state clearly that "the remaining amount is unknown" (it is helpful to also note which of the §2.4 fallback conditions may apply) |

- Write this rule clearly in the **agent memory or operating documentation (such as CLAUDE.md) of the adopting repository**, so it is referenced even across a context summary (because, being detect-only, it depends on whether it is recalled).

### FR-07 Scheduling on DEFER

- The scheduled launch time is `RESETS_AT` (plus a small margin).
- If the reset is **within 1 hour**, use a short sleep mechanism (for example `ScheduleWakeup`, up to 3600 seconds). If it is **further out**, use a one-shot cron (for example `CronCreate`) or a chain of sleeps.
- **Re-check at resume**: after the schedule fires, run the gate once more right before launch and confirm `OK` before launching (this prevents an immediate re-hit from drift in the reset estimate, which is thrash).
- **Use `SECONDS_TO_RESET`; the current time is recommended, not required**: the gate prints `SECONDS_TO_RESET` (the wait, computed as `RESETS_AT - now` at gate run time), so the agent can schedule the resume from it directly and decide the "within 1 hour or beyond" branch (`< 3600` or not) without its own clock. Schedule promptly after running the gate, because the value ages. Injecting the current time each turn (for example, through a `UserPromptSubmit` hook) is still recommended for stating wall-clock times in the agent's own words and as a sanity check, but it is no longer needed to schedule, which removes the fabricated-`now` risk (§2.4, §8).

### FR-08 mid-run watchdog (finishing a single workflow that exceeds one window)

Pre-flight (FR-06) only "does not start when little is left"; it **cannot save a single task that starts from full and eats one whole window (5 hours)**. This is the in-run monitoring that fills that gap.

- **When it applies**: a single workflow that passed pre-flight with `OK` but whose use may exceed one window (prefer read-only).
- **Launch**: start the `Workflow` with `run_in_background` and keep the `runId`.
- **Monitoring (polling)**: the agent wakes at a coarse interval and runs `rate-guard.sh`.
  - `OK` and running → schedule the next check.
  - `DEFER` (≥ threshold) and running → **`TaskStop(runId)`** (the journal is kept) → record `RESETS_AT` and schedule the resume (same procedure as FR-07).
  - completion notice received → end the loop (collect the results).
- **Resume**: the schedule fires → re-check with `rate-guard.sh` → `OK` → continue with `Workflow(scriptPath, resumeFromRunId=runId)` → return to the monitoring loop. **If it spans several windows, repeat on each DEFER.**
- **Why stop on purpose at 80%**: if you wait for the 100% hit, the Workflow's `agent()` is swallowed into `null` after retries, and **a degraded result is returned silently** (a silent cutoff). A `TaskStop` at the threshold stops cleanly and keeps the journal, which avoids this.
- **Safety**: because you stop from outside, **it does not stop at a boundary (the phase boundary)**. The interrupted agent re-runs on resume, so a **read-only workflow is harmless**. One with writes presupposes an idempotency key (loose-coupling agreement #4).
- See Appendix B for the detailed procedure.

---

## 6. Non-functional requirements

| ID | Requirement |
| --- | --- |
| NFR-01 | **Non-destructive**: do not change the existing status line's rendering or exit behavior. A tee failure does not reach rendering. New setup also does not break Claude Code's default behavior |
| NFR-02 | **Minimal added delay**: keep the tee to a single `jq` call |
| NFR-03 | **Zero usage-window cost**: the decision is code only. It uses no LLM turn |
| NFR-04 | **Hard to lose**: the decision material is on disk and does not depend on the agent losing context (summary, cache eviction) |
| NFR-05 | **Easy to port**: the only dependencies are `bash`/`jq`/`awk`/`date`. Reset-time formatting works with GNU or BSD `date` (it tries both forms in order) |
| NFR-06 | **Safe on the safe side**: when unknown, do not block; show that it is unknown |
| NFR-07 | **No silent cutoff**: always explain DEFER/UNKNOWN through `REASON`, and notify the user of a deferral |
| NFR-08 | **Keep monitoring cheap**: monitoring runs at a coarse interval (mindful of keeping the cache) and each time only "reads the state and compares numbers". Near the limit, monitoring itself must not eat up the window |
| NFR-09 | **Make tee failures visible**: the tee does not swallow failures; it leaves a trace (`rate-guard.tee.log`). It does not break rendering (`exit 0` at the end). This makes it possible to detect when a silent failure removes the protection |

---

## 7. The interface agreement (promises you must not break)

1. **The state-file format** (FR-02). Do not change the key names, the epoch seconds of `written_at`, or the allowance of `null`.
2. **The gate's standard-output agreement**: `KEY=VALUE` lines, key names `VERDICT/FIVE_HOUR_PCT/RESETS_AT/RESETS_AT_HUMAN/SECONDS_TO_RESET/REASON`. New keys may be added (additive), but existing key names must not change.
3. **Exit codes**: `0=OK / 10=DEFER / 20=UNKNOWN`. The caller may branch on these codes.
4. The data flow is one-directional (§4). The gate treats the state as **read-only** and does not rewrite it.

---

## 8. Prerequisites and differences at adoption (**always check before adoption**)

- **The most important prerequisite (being able to see it)**: first confirm whether the target Claude Code **actually passes** `rate_limits.five_hour.used_percentage` / `resets_at` on the status-line standard input (put an echo debug into `statusLine.command`, or look at the created state file). In an environment where it is not passed (the §2.4 fallback conditions), this tool falls back to permanent `UNKNOWN` (fail-open) and the gate does not work.
- **When the status line runs (official)**: `statusLine.command` runs **after a new assistant message, when `/compact` completes, on a permission-mode change, and on a Vim-mode toggle**, and updates are batched over 300ms. **If not set, it never runs.** These are interactive UI actions; design on the assumption that they do not run under headless/print mode (§2.4).
- **When `rate_limits` arrives (official)**: `rate_limits` appears on standard input **after the first API response of a Claude.ai Pro/Max subscriber**. `five_hour` / `seven_day` can each be missing. It does not arrive for API-key billing users.
- **The visible bar is independent (official)**: even if the script outputs nothing to standard output, the status-line command runs and side effects such as file writes run. So **the tee works even in a setup with no visible bar**.
- **Field locations depend on the version**: the key names above can change with the Claude Code version. Confirm by actually looking at the real environment's standard-input JSON.
- **`date` dialects**: try both GNU (`date -d @epoch`) and BSD (`date -r epoch`) in order for reset-time formatting.
- **Path differences**: default to under `~/.claude`, but keep it swappable with an environment variable.
- **Keep the state file out of git** (volatile state local to the running environment).

---

## 9. Acceptance criteria (test cases)

The implementation must satisfy the following.

| # | Input | Expected |
| --- | --- | --- |
| 1 | Pass a normal standard input that includes rate_limits through the tee | A valid JSON state file is created in one write |
| 2 | Standard input without rate_limits (non Pro/Max, etc.) | Each value is `null`; the JSON is valid |
| 3 | `used_percentage=42`, threshold 80 | `VERDICT=OK` / exit 0 |
| 4 | `used_percentage=85`, threshold 80 | `VERDICT=DEFER` / exit 10 |
| 5 | `used_percentage=80` (equal value) | `VERDICT=DEFER` (`>=`) / exit 10 |
| 6 | `written_at` is 1200 seconds ago (>900) | `VERDICT=UNKNOWN` / exit 20, REASON states "stale" |
| 7 | No state file (equivalent to status line not set) | `VERDICT=UNKNOWN` / exit 20 (fail-open), REASON states "not created" |
| 8 | `RATE_GUARD_THRESHOLD=30`, `used_percentage=42` | `VERDICT=DEFER` |
| 9 | Run the gate against real data (after the tee fired in a real session) | OK/DEFER returns on authoritative values (smoke) |
| 10 | Newly set up Appendix A-1 in an environment with no status line and do one round trip interactively | The state file is created and the gate returns authoritative values (new-adoption smoke) |
| 11 | Run the existing status line on its own after appending the tee | The existing rendering is unchanged (non-destructive check) |
| 12 | `five_hour.used_percentage=null` (equivalent to non Pro/Max) | `UNKNOWN` / exit 20, REASON states "rate_limits absent = gate disabled" |
| 13 | `RATE_GUARD_THRESHOLD=5` / `=99` | A misconfiguration warning to standard error; the standard-output KEY=VALUE is unchanged |
| 14 | Make the tee write fail (permissions/disk, etc.) | The status line `exit 0`s (rendering continues); the failure is recorded to `rate-guard.tee.log` |
| 15 | `written_at` is not a number (`"abc"`/decimal/hex, etc.) | `UNKNOWN` / exit 20 (per the agreement without crashing), REASON states "not a number" |
| 16 | Real state with a future `resets_at` | `SECONDS_TO_RESET` is printed and equals `RESETS_AT - now` (empty when the reset time is absent, negative when it has already passed) |

---

## 10. Known limits and non-goals

- **Depends on the status-line command**: the tee rides on the status-line command's execution. **If not set, permanent `UNKNOWN`.** Adoption starts with setting up the Appendix A-1 command (§2.4, §11).
- **Interactive session only**: the agent runs the decision and monitoring, and they work only while the session is running (`TaskStop`/`resumeFromRunId` are tied to the session). **Under headless/non-interactive launch, the status line does not run and the copy goes stale**, so launch long-running workflows from an interactive session. Close the session and the monitor is gone, so the mid-run watchdog (FR-08) also stops.
- **Pro/Max only**: `rate_limits` is given only to Claude.ai Pro/Max subscribers. Under API-key billing it is permanently `UNKNOWN` (passes through fail-open), and this gate cannot be used.
- **A mid-run stop does not guarantee a boundary**: because you stop from outside, the stop point is not fixed. The interrupted agent re-runs on resume, so a read-only workflow is harmless, but one with writes presupposes an idempotency key.
- **Detect only, no enforcement**: enforcement (blocking with a hook) is a separate decision (Appendix C). This document assumes "the agent looks at it itself".
- **Targets scope-(i) only**: dispatcher-managed tasks are out of scope.
- **Goes stale while idle**: when rendering stops, the copy goes stale. But the gate's target is a running workflow, so the real harm is small, and the freshness check (FR-04) absorbs it with UNKNOWN.
- **Authoritative but version-dependent**: the values come from the server and are not estimates, but the standard-input format depends on the Claude Code version (§8).

---

## 11. Rollout procedure (new adoption)

Starting from an environment with no status line, adopt with the fewest steps. If a status line already exists, read steps 2–3 as "appending the tee block".

1. **Check the prerequisites** (§2.4, §8): confirm whether the target is **Pro/Max** and is **used as an interactive TUI**. If neither holds, make the adopter aware that it becomes permanent `UNKNOWN` (fail-open).
2. **Place the status-line command**: put the Appendix A-1 `statusline-command.sh` under `~/.claude/` and give it execute permission (`chmod +x`).
3. **Wire up settings.json**: point `statusLine.command` at that script (see the setup example at the end of Appendix A-1). If a status line already exists, append only the tee block to that command and do not change the wiring.
4. **Place the gate**: put the Appendix A-2 `rate-guard.sh` and give it execute permission.
5. **State the behavior rule**: write FR-06 (pre-flight) and FR-08 (mid-run watchdog) into that repository's agent memory / operating documentation.
6. **Acceptance check**: run the §9 tests, especially #10 (new-adoption smoke), in an interactive session, and confirm that the state is created and the gate returns authoritative values.
7. (Optional) To fully eliminate misses, consider Appendix C (enforcement hook).

---

## 12. Operating promises (preventing accidents)

Even if the gate mechanism itself is sound, mishandled operation leads to accidents. Rules to keep at the adopting site.

- **Under the watchdog, prefer read-only workflows**: a mid-run stop does not guarantee a boundary, and the interrupted agent re-runs on resume. **A workflow with writes (files / external posts / DB updates / uploads) must have an idempotency key (`request_hash`/`batch_id`, etc.).** Do not put a workflow that cannot be made idempotent on the watchdog.
- **Let detached subprocesses defend themselves**: if a workflow launches an external process that does not die on `TaskStop`, **give that process its own maximum run time / self-gate**. Closing the session removes the monitor (the agent), so it must be able to stop itself even with no monitor present.
- **Fix monitoring to a coarse interval, and back off at the reset boundary**: every wake-up uses tokens. So that monitoring itself does not eat the window near the limit, keep the interval in minutes, and suppress thrash from drift in the reset estimate with a re-check guard plus backoff (NFR-08).
- **Leave margin for heavy single workflows**: pre-flight sees only the usage rate at launch and does not know the workflow's use. For a workflow that could eat one window, **lower the threshold to keep margin** (for example 80→60), or switch to the **FR-08 watchdog** approach.
- **Pass the threshold through an environment variable**: fixing a permanent change in `settings.json`, etc. with a threshold below your usual usage rate means it **exceeds the threshold again after the reset and gets stuck in permanent DEFER**. Keep a threshold change in the environment variable at the gate call (one-off only).

---

## Appendix A: Reference implementation

### A-1. The status-line command (`~/.claude/statusline-command.sh`, with the tee built in)

A self-contained script that **can be newly set up as is** in an environment with no status line. It takes rate_limit from standard input and writes the copy (tee), and optionally draws a one-line visible bar. If you do not need the visible bar, replace the trailing "visible bar" block with `:` (a no-op); the tee side effect still works.

```bash
#!/usr/bin/env bash
# Claude Code status-line command + rate-limit copy (tee).
# Reads the state JSON on stdin, persists the rate-guard state, and optionally renders one line.
input=$(cat)

# --- Take rate_limit, etc. (exists only on Pro/Max; if absent, empty, then nulled downstream) ---
five_pct=$(echo   "$input" | jq -r '.rate_limits.five_hour.used_percentage  // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at         // empty')
week_pct=$(echo   "$input" | jq -r '.rate_limits.seven_day.used_percentage   // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at         // empty')
used_pct=$(echo   "$input" | jq -r '.context_window.used_percentage          // empty')

# --- tee: copy the rate-limit state atomically (separate from rendering; a failure leaves a trace) ---
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

# --- Visible bar (optional, cosmetic). If not needed, replace the next 3 lines with `:` ---
model=$(echo "$input" | jq -r '.model.display_name // empty')
printf '%s' "${model:+$model}"
[ -n "$five_pct" ] && printf ' · 5h %s%%' "$five_pct"

exit 0   # a tee failure or a short-circuit of the visible bar could exit non-zero and blank the status line; avoid it
```

Wiring into `settings.json` (for an unset environment):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-command.sh"
  }
}
```

> In an environment that already has a status line, do not change the wiring; append only the "tee" block above into that existing command. If the extraction (`five_pct`, etc.) is not defined, append the extraction lines too.

### A-2. `rate-guard.sh` (the full decision script)

```bash
#!/usr/bin/env bash
# Code only (no LLM) that decides whether there is room to run one workflow in the 5-hour session window.
# Output: KEY=VALUE lines / exit codes 0=OK 10=DEFER 20=UNKNOWN(fail-open)
set -u
THRESHOLD="${RATE_GUARD_THRESHOLD:-80}"
STALE_SECONDS="${RATE_GUARD_STALE_SECONDS:-900}"
STATE_FILE="${RATE_GUARD_STATE_FILE:-$HOME/.claude/rate_limit_state.json}"

# Threshold sanity: outside [10,95] is a likely misconfiguration, warn to stderr (the decision continues; the stdout agreement is unchanged)
if [ "$(awk -v t="$THRESHOLD" 'BEGIN{print (t+0<10 || t+0>95) ? 1 : 0}')" = "1" ]; then
  printf 'WARN: RATE_GUARD_THRESHOLD=%s outside [10,95]; likely misconfigured\n' "$THRESHOLD" >&2
fi

now=$(date +%s)
emit() { printf '%s\n' "$@"; }
fmt_reset() {
  local epoch="$1"
  [ -z "$epoch" ] && { echo ""; return; }
  date -d "@${epoch}" "+%m/%d %H:%M" 2>/dev/null || date -r "${epoch}" "+%m/%d %H:%M" 2>/dev/null
}
# Seconds until the reset (computed only when reset is an integer; negative = the reset time is already past).
# The agent can schedule the resume delay from this directly, without its own clock.
secs_to_reset() {
  case "$1" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$(( $1 - now ))" ;;
  esac
}

if [ ! -f "$STATE_FILE" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=" "RESETS_AT=" "RESETS_AT_HUMAN=" "SECONDS_TO_RESET=" \
       "REASON=state file not found ($STATE_FILE); statusLine.command unset or tee not run yet"
  exit 20
fi

written=$(jq -r '.written_at // empty' "$STATE_FILE" 2>/dev/null)
pct=$(jq -r '.five_hour.used_percentage // empty' "$STATE_FILE" 2>/dev/null)
reset=$(jq -r '.five_hour.resets_at // empty' "$STATE_FILE" 2>/dev/null)
reset_h=$(fmt_reset "$reset")
secs=$(secs_to_reset "$reset")

case "$written" in
  ''|*[!0-9]*)
    emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=${pct}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" \
         "REASON=state malformed (written_at missing or non-numeric); statusline tee may be broken (see ~/.claude/rate-guard.tee.log)"
    exit 20 ;;
esac
if [ -z "$pct" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" \
       "REASON=rate_limits absent (five_hour.used_percentage null); non Pro/Max or before first API response -- gate inoperative here"
  exit 20
fi

age=$(( now - written ))
if [ "$age" -gt "$STALE_SECONDS" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=${pct}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" \
       "REASON=state stale (${age}s > ${STALE_SECONDS}s); if mid-session the statusline tee may be broken (see ~/.claude/rate-guard.tee.log)"
  exit 20
fi

over=$(awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN{print (p+0 >= t+0) ? 1 : 0}')
if [ "$over" = "1" ]; then
  emit "VERDICT=DEFER" "FIVE_HOUR_PCT=${pct}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" \
       "REASON=5h usage ${pct}% >= threshold ${THRESHOLD}%; defer launch until reset"
  exit 10
fi

emit "VERDICT=OK" "FIVE_HOUR_PCT=${pct}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" \
     "REASON=5h usage ${pct}% < threshold ${THRESHOLD}%"
exit 0
```

---

## Appendix B: mid-run watchdog operating procedure (FR-08 details)

The procedure for finishing a single workflow that exceeds one window (5 hours).

**What it is**: not a new program, but a monitoring loop the agent runs on top of existing parts (`rate-guard.sh` plus the Workflow tool's standard `run_in_background` / `TaskStop` / `resumeFromRunId`). Because `TaskStop`/`resumeFromRunId` are tied to the session, **the agent itself does the monitoring** (a plain cron cannot).

**Loop (outline of the procedure)**:

```
launch:  runId = Workflow(scriptPath, run_in_background=true)

monitoring loop (wake at a coarse interval, run rate-guard.sh each time):
  VERDICT=OK    and running  → schedule the next check
  VERDICT=DEFER and running  → TaskStop(runId)              # the journal is kept
                               record RESETS_AT and schedule the resume (same procedure as FR-07)
  completion notice received → end the loop (collect the results)

resume (when the schedule fires):
  re-check with rate-guard.sh → confirm OK (thrash prevention)
  continue with Workflow(scriptPath, resumeFromRunId=runId, run_in_background=true)
  return to the monitoring loop (if it spans several windows, repeat on each DEFER)
```

**Design points**:

- **The value of stopping on purpose at 80%**: if you wait for the 100% hit, the Workflow's `agent()` is swallowed into `null` after retries, and **a degraded result is returned silently** (a silent cutoff). A `TaskStop` at the threshold stops cleanly and keeps the journal, which avoids this.
- **The stop point is not fixed**: because you monitor from outside, it does not stop at a boundary (the phase boundary). The agent that was running at the interruption re-runs on resume. **A read-only workflow (code review, etc.) is harmless.** One with writes (files / external posts / DB updates / uploads) is limited to the range where an idempotency key (request_hash/batch_id, etc. = loose-coupling agreement #4) can absorb a double fire.
- **Resume prerequisite**: the script must be deterministic (must not depend on `Date.now()`/randomness). With the same script and same args, completed agents are restored from the cache 100%.
- **Detached subprocesses**: if the workflow launches an external process, it does not die on `TaskStop`. On resume, do not re-launch; **monitor an existing marker/lock (the PID being alive)** to continue (the detach-plus-monitor approach).
- **Monitoring cost**: each check is only "read the state and compare numbers". Keep the interval coarse (mindful of keeping the cache). Near the limit, monitoring itself must not eat the window (NFR-08).

## Appendix C: Upgrading to enforcement (a PreToolUse hook) (optional)

Only when you want to fully eliminate misses (the agent forgetting to run the gate, or not recalling it).

- A PreToolUse hook on the `Workflow` tool runs `rate-guard.sh`, and on `DEFER` it blocks the tool call and returns the reason.
- **The cost**: it acts uniformly on every Workflow call (light calls included). A risky mechanism that a script bug could turn into a full block. Exception handling needs a separate bypass (an environment-variable flag, excluding a specific label).
- **The limit**: what a hook can harden is only "blocking the launch". The follow-through of scheduling the deferral and notifying the user still remains in the agent's behavior (FR-06/07).
- When you adopt it, changing the configuration file (`hooks` in `settings.json`) changes the behavior of all sessions, so introduce it only with explicit approval.
