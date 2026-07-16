#!/usr/bin/env bash
# 5時間セッション枠に「1本回す余力」があるかを判定する純コード（LLM不使用）。
# 出力: KEY=VALUE 行 / 終了コード 0=OK 10=DEFER 20=UNKNOWN(fail-open)
# 仕様: docs/SPEC.md（SPEC-RATEGUARD-001）付録A-2
set -u
export LC_ALL=C   # awk の数値出力・解釈をロケール非依存に（小数点は常にピリオド）
THRESHOLD="${RATE_GUARD_THRESHOLD:-80}"
STALE_SECONDS="${RATE_GUARD_STALE_SECONDS:-900}"
STATE_FILE="${RATE_GUARD_STATE_FILE:-$HOME/.claude/rate_limit_state.json}"

# 閾値サニティ：[10,95] 外は誤設定の疑いとして stderr に警告（判定は続行・stdout 契約は不変）
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
# リセットまでの残り秒（reset が整数のときのみ算出。負値＝リセット時刻は既に過去）。
# エージェントはこの値で再開の遅延を直接予約でき、自前の現在時刻を持たずに済む。
secs_to_reset() {
  case "$1" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$(( $1 - now ))" ;;
  esac
}
# 数値の整形（%g・6有効桁）：サーバ値の浮動小数アーティファクト（例 14.000000000000002 → 14）だけを
# 除去し、実質の精度は保つ（前後差分による計測バッチを壊さない）。判定は生値で行い、
# 表示と食い違う極端な境界では VERDICT が正。
fmt_num() {
  case "$1" in
    ''|*[!0-9.]*|*.*.*|.) printf '%s\n' "$1" ;;
    *) awk -v x="$1" 'BEGIN{printf "%g\n", x}' ;;
  esac
}

if [ ! -f "$STATE_FILE" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=" "HEADROOM_PCT=" "RESETS_AT=" "RESETS_AT_HUMAN=" "SECONDS_TO_RESET=" "STATE_AGE_SECONDS=" \
       "REASON=state file not found ($STATE_FILE); statusLine.command unset or tee not run yet"
  exit 20
fi

written=$(jq -r '.written_at // empty' "$STATE_FILE" 2>/dev/null)
pct=$(jq -r '.five_hour.used_percentage // empty' "$STATE_FILE" 2>/dev/null)
reset=$(jq -r '.five_hour.resets_at // empty' "$STATE_FILE" 2>/dev/null)
reset_h=$(fmt_reset "$reset")
secs=$(secs_to_reset "$reset")
pct_disp=$(fmt_num "$pct")

case "$written" in
  ''|*[!0-9]*)
    emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=${pct_disp}" "HEADROOM_PCT=" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" "STATE_AGE_SECONDS=" \
         "REASON=state malformed (written_at missing or non-numeric); statusline tee may be broken (see ~/.claude/rate-guard.tee.log)"
    exit 20 ;;
esac
# 控えの経過秒。呼び出し側はこの値と FIVE_HOUR_PCT の履歴からバーンレートを実測できる
# （written_at が異なる 2 点で差分を取る。FR-08 の UNKNOWN 分岐・先読み DEFER の材料）。
age=$(( now - written ))
if [ -z "$pct" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=" "HEADROOM_PCT=" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" "STATE_AGE_SECONDS=${age}" \
       "REASON=rate_limits absent (five_hour.used_percentage null); non Pro/Max or before first API response -- gate inoperative here"
  exit 20
fi
# 非数値の used_percentage は 0 と誤読して OK を返さず、破損として UNKNOWN に倒す
case "$pct" in
  *[!0-9.]*|*.*.*|.)
    emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=${pct_disp}" "HEADROOM_PCT=" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" "STATE_AGE_SECONDS=${age}" \
         "REASON=state malformed (used_percentage non-numeric); statusline tee may be broken (see ~/.claude/rate-guard.tee.log)"
    exit 20 ;;
esac

if [ "$age" -gt "$STALE_SECONDS" ]; then
  emit "VERDICT=UNKNOWN" "FIVE_HOUR_PCT=${pct_disp}" "HEADROOM_PCT=" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" "STATE_AGE_SECONDS=${age}" \
       "REASON=state stale (${age}s > ${STALE_SECONDS}s); statusline had no UI event (happens while waiting on background work -- see statusLine.refreshInterval) or tee broken (see ~/.claude/rate-guard.tee.log)"
  exit 20
fi

# 閾値までの余裕（= しきい値 − 使用率、負なら 0）。予算比較（推定消費×1.3 ≦ HEADROOM_PCT）の右辺に使う。
headroom=$(awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN{h=t-p; if(h<0)h=0; printf "%g\n", h}')

over=$(awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN{print (p+0 >= t+0) ? 1 : 0}')
if [ "$over" = "1" ]; then
  emit "VERDICT=DEFER" "FIVE_HOUR_PCT=${pct_disp}" "HEADROOM_PCT=${headroom}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" "STATE_AGE_SECONDS=${age}" \
       "REASON=5h usage ${pct_disp}% >= threshold ${THRESHOLD}%; defer launch until reset"
  exit 10
fi

emit "VERDICT=OK" "FIVE_HOUR_PCT=${pct_disp}" "HEADROOM_PCT=${headroom}" "RESETS_AT=${reset}" "RESETS_AT_HUMAN=${reset_h}" "SECONDS_TO_RESET=${secs}" "STATE_AGE_SECONDS=${age}" \
     "REASON=5h usage ${pct_disp}% < threshold ${THRESHOLD}%"
exit 0
