# --- rate-guard: Persist rate-limit state for autonomous gating (scope-(i) workflows) ---
# 既存 statusline コマンド（statusLine.command が指す shell）の末尾へ「追記」する非破壊ブロック。
# 前提: statusline 側が以下の変数を抽出済みであること（無ければ先に下の抽出を足す）。
#   five_pct/five_reset/week_pct/week_reset/used_pct
# 仕様: docs/SPEC.md（SPEC-RATEGUARD-001 v2）付録A-1
# 実稼働の追記先: ~/.claude/statusline-command.sh

# （statusline 側に rate_limits 抽出が無い場合に足す）
# five_pct=$(echo   "$input" | jq -r '.rate_limits.five_hour.used_percentage  // empty')
# five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at         // empty')
# week_pct=$(echo   "$input" | jq -r '.rate_limits.seven_day.used_percentage   // empty')
# week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at         // empty')
# used_pct=$(echo   "$input" | jq -r '.context_window.used_percentage          // empty')

state_file="$HOME/.claude/rate_limit_state.json"
now_epoch=$(date +%s)
jq -n \
  --argjson now "$now_epoch" \
  --arg fp "${five_pct:-}" --arg fr "${five_reset:-}" \
  --arg wp "${week_pct:-}" --arg wr "${week_reset:-}" \
  --arg cp "${used_pct:-}" \
  'def tonum: if . == "" then null else (tonumber? // null) end;
   { written_at: $now,
     five_hour: { used_percentage: ($fp|tonum), resets_at: ($fr|tonum) },
     seven_day: { used_percentage: ($wp|tonum), resets_at: ($wr|tonum) },
     context:   { used_percentage: ($cp|tonum) } }' \
  > "${state_file}.tmp" 2>/dev/null && mv -f "${state_file}.tmp" "$state_file" 2>/dev/null || true
