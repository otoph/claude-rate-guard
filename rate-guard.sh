#!/usr/bin/env bash
# 5時間セッション枠に「1本回す余力」があるかを判定する純コード（LLM不使用）。
# 出力: KEY=VALUE 行 / 終了コード 0=OK 10=DEFER 20=UNKNOWN(fail-open)
# 仕様: docs/SPEC.md（SPEC-RATEGUARD-001）付録A-2
set -u
THRESHOLD="${RATE_GUARD_THRESHOLD:-80}"
STALE_SECONDS="${RATE_GUARD_STALE_SECONDS:-900}"
STATE_FILE="${RATE_GUARD_STATE_FILE:-$HOME/.claude/rate_limit_state.json}"

# 閾値サニティ：[10,95] 外は誤設定の疑いとして stderr に警告（判定は続行・stdout 契約は不変）
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
