# rate-guard 要件定義書

|   項目   |                                  内容                                  |
| -------- | ---------------------------------------------------------------------- |
| 文書ID   | SPEC-RATEGUARD-001                                                     |
| 想定読者 | アーキテクト / 実装担当エージェント / 各リポジトリの導入者              |
| 適用範囲 | **リポジトリ非依存**（横展開前提）。Claude Code を実行環境とする任意のリポジトリに移植可能。**statusline を未設定の環境にも新規導入できる**ことを前提に記述する |
| 前提環境 | Claude Code（statusline 機構＋Workflow ツールを持つ版）。`bash` / `jq` / `awk` / `date` が利用可能なこと。**rate_limits の取得には Claude.ai Pro/Max サブスクリプションが必要**（§2.4）。**エージェントへ現在時刻を毎ターン供給する手段**（例：`UserPromptSubmit` フックでの時刻注入）。FR-07/08 の予約・告知が時刻に依存するため（§2.4・§8） |

---

## 1. 本ドキュメントの位置づけ

本書は、Claude Code の **5 時間セッション利用枠（および 7 日枠）の残量を起動前に判定し、余力が閾値を下回る場合に長時間ワークフローの起動を次枠へ自動延期する** 補助コンポーネント「**rate-guard**」の要件定義である。本書をもとに、**statusline をまだ設定していないリポジトリ／ユーザーを含め**、別環境の導入者が同等物を一から構築できることを目的とする。

本コンポーネントは **非強制（advisory）** である。ハーネスがツール呼び出しを機械的にブロックするのではなく、**判定材料をディスクに常時用意し、エージェントが起動直前にそれを参照して自らの判断で延期する** 方式を採る。強制（フックによるブロック）は本書のスコープ外（§10・付録 C 参照）。

### 1.1 解決する問題

- Claude Code 内のエージェントには、**自身の 5 時間枠の消費率・次枠の reset 時刻を返す API/ツールが無い**。`Workflow` の `budget` は「そのターンの出力トークン目標」であって口座のセッション枠とは別物。
- 一方 **statusline コマンドの stdin には `rate_limits`（サーバ提供の権威値）が渡っている**。これを控えればコードで判定できる。
- 残量が乏しいまま長時間ワークフローを起動すると **途中で枠が尽き、ワークフローが中断・全損** する。起動前に弾けば停止/再開という壊れやすい操作そのものを回避できる。

---

## 2. 背景と目的

### 2.1 背景

長時間（数十分規模）の処理を 1 ターン内のワークフローで回す運用では、5 時間枠の枯渇が「途中被弾→中断」という最悪の失敗を生む。被弾後のメッセージはエージェントの文脈には能動的に取得できる形で届かず、事後対応は不確実。**起動可否を起動前に決める（pre-flight gate）** のが最も壊れにくい。

### 2.2 目的

- statusline コマンドが受け取る権威値を **ディスクに常時控える**（tee）。statusline 未設定の環境には、この控えを内蔵した statusline コマンドを **新規に設定** する（付録 A-1）。
- その控えを読み、**5 時間枠の使用率を閾値（既定 80%）と比較して起動可否を返す純コード判定器** を提供する。
- エージェントが **長時間ワークフロー起動直前に判定器を呼び、DEFER なら次枠へ延期** する挙動契約を定める（pre-flight・FR-06）。
- **1 枠（5h）を超える単発ワークフロー** に対し、走行中も判定器でポーリング監視し、閾値到達で **phase 境界 stop → reset 後に `resumeFromRunId` で自動再開** する mid-run watchdog の挙動契約を定める（FR-08）。

### 2.3 スコープ境界（**必読**）

|                     機能                      | スコープ内 / 外 |                        理由                         |
| --------------------------------------------- | --------------- | --------------------------------------------------- |
| statusline コマンドの新規設定／tee 追記       | 内              | 権威値の唯一の入手経路。受動・無料。未設定環境では新規作成が導入の起点 |
| statusline からの rate_limit 控え出力（tee）  | 内              | 権威値の唯一の入手経路。受動・無料                  |
| 5 時間枠の閾値判定（gate・純コード）          | 内              | 算術はコード（LLM 不使用）                          |
| pre-flight 延期の挙動契約（エージェント側）   | 内              | 本コンポーネントの主目的                            |
| DEFER 時の次枠への起動予約                     | 内              | reset 時刻が控えにあるため決定論的に予約可能        |
| **mid-run watchdog**（走行中の監視→閾値到達で stop→reset 後に自動再開） | **内** | 1 枠を超える単発タスクの完走に必須。pre-flight では救えない（FR-08・付録 B） |
| **強制（PreToolUse フックによるブロック）**   | **外**          | 全ワークフロー無差別作用の foot-gun。別途判断（付録 C） |
| dispatcher 管理タスク（Slack 経由等）のゲート | **外**          | そちらは checkpoint→プロセス終了→再ディスパッチが正道 |
| 24/7 常駐デーモン                             | **外**          | 判定の実行主体はエージェント。セッション稼働中のみ働く |

### 2.4 適用前提とカバレッジ（**必読・導入前に確認**）

本ゲートが権威値で機能する（`OK`/`DEFER` を返す）には、下表の **目標状態** を満たす必要がある。満たさない条件では **fail-open で恒久／一時 `UNKNOWN` に縮退** し、ゲートは無言で無効化される（封鎖はしないが守らない）。導入時はこの縮退条件を必ず周知すること。

| 環境条件 | gate の挙動 | 導入時の対応 |
| --- | --- | --- |
| 対話 TUI ＆ Pro/Max ＆ statusline 設定済 ＆ 初回 API 応答後 | **正常**（OK/DEFER） | 本書が目指す目標状態 |
| **statusLine.command 未設定** | 恒久 `UNKNOWN`（state ファイルが生成されない） | §11・付録 A-1 で **新規設定** すれば解消。本書の主たる導入経路 |
| **headless / 非対話起動**（`claude -p`・SDK・非対話 cron） | state が更新されず陳腐化 → `UNKNOWN` | statusline は対話 UI イベントでのみ発火する。**長時間 WF は対話セッションから起動する**こと。headless 常用は本ゲートの守備範囲外 |
| **APIキー課金（非 Pro/Max）** | `rate_limits` 自体が stdin に来ない → 恒久 `UNKNOWN` | 本ゲートは適用不可。fail-open で素通りし、被弾はハーネスの rate-limit エラーが最終バックストップ |
| 初回 API 応答前 | 一時 `UNKNOWN` | 1 往復後に解消（恒久ではない） |
| **エージェントに現在時刻が供給されない**（時刻注入 hook 等が無い） | gate の OK/DEFER 自体は正常（gate は shell の `date` を使う）。ただし **FR-07/08 の予約タイミング判断とユーザー告知が不確実化** | `UserPromptSubmit` 等で毎ターン現在時刻を注入する（§8） |

- 縮退は全て **fail-open**（封鎖しない）ため「壊れはしない」が、「守っているつもりで守っていない」状態は危険。NFR-07 のとおり `UNKNOWN` は必ず `REASON` で可視化する。
- **時刻 sense はゲート判定（gate）ではなくエージェント挙動（FR-06/07/08）の前提**：判定自体はコードの `date` で成立するが、延期予約のタイミングと告知に時刻認識が要る。
- `rate_limits` は **Claude.ai Pro/Max サブスクライバーの初回 API レスポンス後にのみ** stdin に現れ、`five_hour` / `seven_day` は独立に欠落しうる（§8・公式スキーマ準拠）。

---

## 3. 用語定義

| 用語 | 定義 |
| --- | --- |
| **scope-(i)** | エージェントが対話内で直接回す `Workflow` ツールの起動。本ゲートの対象 |
| **statusline コマンド** | `settings.json` の `statusLine.command` に登録するシェル。Claude Code が UI イベント時に stdin へ JSON を渡して実行する。**画面の可視バーそのものではなくコマンド本体**を指す |
| **tee** | statusline コマンドの実行のたびに rate_limit 状態をファイルへ写し取る処理 |
| **gate** | 控えを読み起動可否（OK/DEFER/UNKNOWN）を返す判定スクリプト |
| **5 時間枠 / 7 日枠** | Claude のセッション利用上限のローリング窓 |
| **`used_percentage`** | 当該枠の消費率（0〜100、サーバ提供値） |
| **`resets_at`** | 当該枠がリセットされる時刻（UNIX epoch 秒、サーバ提供値） |
| **fail-open** | 判定材料が無い/古いとき、封鎖せず起動を許す（不明を明示）安全側設計 |

---

## 4. 全体構成とデータフロー

```
[Claude Code 本体]
   │  statusline コマンド実行ごとに stdin JSON を渡す（UI イベント時・対話TUIのみ）
   │  （.rate_limits.five_hour.{used_percentage,resets_at} 等＝権威値）
   ▼
[statusline-command.sh]  ──(tee: atomic write)──▶  [rate_limit_state.json]
   │                                                      │
   │（任意で端末へ描画。tee は副作用ゼロ・失敗しても描画継続）     │ 読み取り専用
   ▼                                                      ▼
[端末 UI（任意・空でも可）]                          [rate-guard.sh]  ──▶  VERDICT=OK|DEFER|UNKNOWN
                                                                        （exit 0 / 10 / 20）
                                                            │
                                                            ▼
                                      [エージェント]  起動直前に gate を実行し
                                        OK→起動 / DEFER→次枠へ予約 / UNKNOWN→起動+警告
```

データは **一方向**：本体 → tee → state ファイル → gate → エージェント挙動。state ファイルは gate からは読み取り専用。**可視バーの有無は本フローに無関係**：stdout が空でも statusline コマンドは実行され、tee の副作用は走る（§8）。

---

## 5. 機能要件

### FR-01 statusline コマンド（控え出力 tee を内蔵）

- 対象環境に statusline コマンドが **無ければ、本コンポーネントが提供するコマンド（付録 A-1）を新規に設定** する。既にあれば tee ブロックを **追記** する（**非破壊**：従来の描画出力・終了挙動を一切変えない）。
- statusline コマンドが受け取った stdin JSON から `rate_limits.five_hour.{used_percentage,resets_at}`・`rate_limits.seven_day.{...}`・`context_window.used_percentage` を抽出し、**現在時刻 `written_at`（epoch 秒）を付与** して state ファイルへ書く。
- **atomic write 必須**：一時ファイルへ書き `mv -f` で置換。読み手の半端読みを防ぐ。
- **書込失敗が描画を阻害してはならない**：tee は描画と隔離し、スクリプトは最後に `exit 0` する。ただし **失敗を握り潰さず痕跡を残す**——失敗時のみ `~/.claude/rate-guard.tee.log` へ 1 行記録する（沈黙故障で保護が無言で消えるのを検知するため・NFR-09）。
- 当該フィールドが stdin に無い場合（非 Pro/Max・初回応答前・版差等）は該当値を **`null`** とし、JSON 自体は常に妥当に保つ。
- **可視バーは任意**：stdout を空にすれば画面には何も出ないが、tee の副作用は走る。バーを出したい場合は付録 A-1 の表示ブロックを使う／差し替える。

### FR-02 state ファイルのスキーマ（インターフェース契約・§7 と同一）

既定パス `~/.claude/rate_limit_state.json`。

```json
{
  "written_at": 1781753494,
  "five_hour": { "used_percentage": 17, "resets_at": 1781758200 },
  "seven_day": { "used_percentage": 42, "resets_at": 1781791200 },
  "context":   { "used_percentage": 10 }
}
```

- 数値はサーバ提供値そのまま（小数可）。取得不能なフィールドは `null`。
- `written_at` は鮮度判定（FR-04）の基準。

### FR-03 gate（判定スクリプト）

- state ファイルを読み、`five_hour.used_percentage` を **閾値（既定 80）** と比較。
- **判定と終了コード**：
  - `used_percentage < 閾値` → `VERDICT=OK`、exit **0**
  - `used_percentage >= 閾値` → `VERDICT=DEFER`、exit **10**（境界値は DEFER 側）
  - 材料欠落 or 陳腐化 → `VERDICT=UNKNOWN`、exit **20**
- **出力は機械可読の `KEY=VALUE` 行**（stdout）：`VERDICT` / `FIVE_HOUR_PCT` / `RESETS_AT` / `RESETS_AT_HUMAN` / `REASON`。
- 浮動小数比較は `awk` 等で行う（bash の整数比較に丸めない）。
- **LLM を一切使わない**（網羅と算術はコード）。
- **閾値サニティ**：`RATE_GUARD_THRESHOLD` が妥当域 `[10,95]` を外れたら **stderr に警告**（誤設定検知）。判定は続行し **stdout の KEY=VALUE 契約は汚さない**。上げすぎ＝無防備・下げすぎ＝恒久 DEFER 詰みの双方を早期に気づかせる。

### FR-04 鮮度・欠落＝fail-open（原因を区別して可視化）

- state ファイルが **存在しない / `written_at` 欠落・非数値 / `five_hour.used_percentage` が `null` / `written_at` が現在から `STALE_SECONDS`（既定 900 秒）より古い** いずれかで `UNKNOWN`（exit 20）を返す。
- UNKNOWN は **封鎖しない**（fail-open）。理由＝初回未生成・idle 後の陳腐化・非 Pro/Max・headless での未発火で全ワークフローを誤って止めるのを避ける。被弾そのものはハーネスの rate-limit エラーが最終バックストップ。
- **沈黙させず、原因を `REASON` で区別する**（同じ UNKNOWN でも対処が異なるため）：
  - state ファイル無し → 「`statusLine.command` 未設定 or tee 未実行」
  - `written_at` 欠落・非数値 → 「state 破損／tee 故障の疑い（`rate-guard.tee.log` 参照）」。算術前に整数検証し、非数値でもクラッシュせず UNKNOWN を返す
  - `used_percentage` が `null` → 「**rate_limits 欠落＝非 Pro/Max または初回応答前**。ここではゲート無効」（構造的・恒久の可能性）
  - 陳腐化 → 「stale。**対話中なら tee 故障の疑い**（`rate-guard.tee.log` 参照）」（一時 or 故障）

### FR-05 設定パラメータ（環境変数で上書き可）

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `RATE_GUARD_THRESHOLD` | `80` | 起動を止める使用率の下限（この値以上で DEFER） |
| `RATE_GUARD_STALE_SECONDS` | `900` | これより古い控えは UNKNOWN |
| `RATE_GUARD_STATE_FILE` | `~/.claude/rate_limit_state.json` | 控えのパス（テスト差し替え用） |

- `RATE_GUARD_THRESHOLD` の **妥当域は `[10,95]`**（外れると FR-03 の警告）。恒久的に変えたいときも **`settings.json` でなく gate 呼び出し時の env で渡す**——定常使用率より低い閾値を固定すると reset 後にまた閾値を超え、**恒久 DEFER 詰み**になる（§12）。

### FR-06 エージェント挙動契約（非強制の中核）

scope-(i) で **1 本まるごと回る長時間ワークフローを起動する直前** に gate を実行し、`VERDICT` に従う：

| VERDICT | 挙動 |
| --- | --- |
| `OK` | そのまま起動 |
| `DEFER` | **起動しない**。`RESETS_AT` 直後に起動を予約し、ユーザーへ「次枠（`RESETS_AT_HUMAN`）に延期」と告げる |
| `UNKNOWN` | fail-open で起動するが「残量不明」を明示する（§2.4 の縮退条件のどれかに該当する可能性を併記すると親切） |

- この契約は **移植先リポジトリのエージェント記憶（memory）または運用ドキュメント（CLAUDE.md 等）に明記** し、文脈要約をまたいでも参照されるようにすること（非強制ゆえ recall に依存するため）。

### FR-07 DEFER 時のスケジューリング

- 起動予約時刻は `RESETS_AT`（＋小マージン）。
- reset まで **1 時間以内**なら短期スリープ系（例：`ScheduleWakeup`、最大 3600 秒）。**それ以上**なら一回限りの cron（例：`CronCreate`）またはスリープ連鎖。
- **再開時の再確認**：予約発火後、起動の直前にもう一度 gate を実行し、`OK` を確認してから起動する（reset 推定ずれによる即再被弾＝thrash の防止）。
- **時刻 sense が前提**：「reset まで 1 時間以内か超か」の分岐と `RESETS_AT_HUMAN` のユーザー告知は、**エージェントが現在時刻を知っていること**に依存する。現在時刻を毎ターン供給する手段（例：`UserPromptSubmit` フックでの時刻注入）を動作環境条件とする（§2.4・§8）。

### FR-08 mid-run watchdog（1 枠を超える単発ワークフローの完走）

pre-flight（FR-06）は「残量が乏しい時に *始めない*」だけで、**満タンから始まって 1 枠（5h）を食い切る単発タスクは救えない**。これを補う走行中監視。

- **適用条件**：pre-flight を `OK` で通過したが、消費が 1 枠を超えうる単発ワークフロー（read-only を優先）。
- **起動**：`Workflow` を `run_in_background` で起動し `runId` を保持。
- **ポーリング**：エージェントが粗い間隔で wakeup し `rate-guard.sh` を実行する。
  - `OK` かつ 実行中 → 次 poll を再予約。
  - `DEFER`（≥閾値）かつ 実行中 → **`TaskStop(runId)`**（journal は保全される）→ `RESETS_AT` を記録し再開を予約（FR-07 と同じスケジューリング）。
  - 完了通知を受領 → ループ終了（成果物を回収）。
- **再開**：予約発火 → `rate-guard.sh` 再確認で `OK` → `Workflow(scriptPath, resumeFromRunId=runId)` で続行 → poll ループへ再投入。**複数枠を跨ぐ場合は DEFER のたびに繰り返す**。
- **80% で能動 stop する理由**：100% 被弾を待つと Workflow の `agent()` がリトライ後 `null` に握り潰され **縮退結果が黙って返る**（沈黙切り捨て）。閾値での `TaskStop` はクリーンに中断し journal を残すため、これを避けられる。
- **安全性**：stop は外部 poll ゆえ **phase 境界を保証できない**。中断 agent は resume で再走するため、**read-only WF は無害**、副作用 WF は冪等キー（疎結合契約#4）前提。
- 詳細手順は付録 B。

---

## 6. 非機能要件

| ID | 要件 |
| --- | --- |
| NFR-01 | **非破壊**：既存 statusline の描画・終了挙動を変えない。tee の失敗は描画に波及しない。新規設定時も Claude Code 既定挙動を壊さない |
| NFR-02 | **追加レイテンシ最小**：tee は 1 回の `jq` 呼び出しに収める |
| NFR-03 | **model-quota コストゼロ**：判定は純 shell。LLM ターンを消費しない |
| NFR-04 | **durable**：判断材料はディスクにあり、エージェントの文脈喪失（要約・キャッシュ消滅）に依存しない |
| NFR-05 | **可搬性**：依存は `bash`/`jq`/`awk`/`date` のみ。GNU/BSD どちらの `date` でも reset 整形が動く（両構文をフォールバック） |
| NFR-06 | **fail-open 安全**：不明時は封鎖せず、不明を可視化する |
| NFR-07 | **沈黙切り捨て禁止**：DEFER/UNKNOWN を必ず `REASON` で説明し、延期はユーザーへ告知する |
| NFR-08 | **mid-run poll の低コスト**：監視 poll は粗い間隔（cache 維持を意識）で各回「state 読取＋数値比較」のみ。上限近傍で監視自身が枠を食い潰さないこと |
| NFR-09 | **tee 故障の可観測性**：tee は失敗を握り潰さず痕跡を残す（`rate-guard.tee.log`）。描画は壊さない（最後に `exit 0`）。沈黙故障で保護が無言で消える事態を検知可能にする |

---

## 7. インターフェース契約（壊してはいけない約束）

1. **state ファイルのスキーマ**（FR-02）。キー名・`written_at` の epoch 秒・`null` 許容を変えない。
2. **gate の stdout 契約**：`KEY=VALUE` 行・キー名 `VERDICT/FIVE_HOUR_PCT/RESETS_AT/RESETS_AT_HUMAN/REASON`。
3. **終了コード**：`0=OK / 10=DEFER / 20=UNKNOWN`。呼び出し側はこのコードで分岐してよい。
4. データフローは一方向（§4）。gate は state を **読み取り専用** とし書き換えない。

---

## 8. 導入時の前提と差分（**導入前に必ず検証**）

- **最重要前提（可観測性）**：対象の Claude Code が statusline stdin に `rate_limits.five_hour.used_percentage` / `resets_at` を **実際に渡しているか** を最初に確認する（`statusLine.command` に echo デバッグを仕込む／生成された state ファイルを見る）。渡されない環境（§2.4 の縮退条件）では本コンポーネントは恒久 `UNKNOWN`（fail-open）に縮退し、ゲートは機能しない。
- **statusline 機構の発火条件（公式）**：`statusLine.command` は **新しいアシスタントメッセージ後・`/compact` 完了時・パーミッションモード変更時・Vim モード切替時** に実行され、更新は 300ms デバウンスされる。**未設定なら一切実行されない**。これらは対話 UI イベントであり、headless/print mode では発火しない前提で設計する（§2.4）。
- **`rate_limits` の提供条件（公式）**：`rate_limits` は **Claude.ai Pro/Max サブスクライバーの初回 API レスポンス後** に stdin へ現れる。`five_hour` / `seven_day` は独立に不在となりうる。APIキー課金ユーザーには来ない。
- **可視バーの独立性（公式）**：スクリプトが stdout に何も出力しなくても statusline コマンドは実行され、ファイル書き込み等の副作用は走る。よって **可視バーを出さない運用でも tee は機能する**。
- **フィールドパスのバージョン依存**：上記キー名は Claude Code 版により変わりうる。実環境の stdin JSON を実査して確定すること。
- **`date` の方言**：reset 整形は GNU（`date -d @epoch`）と BSD（`date -r epoch`）の両方をフォールスルーで試すこと。
- **パスの差異**：`~/.claude` 配下を既定とするが、環境変数で差し替え可能にしておく。
- **state ファイルは git 管理外** に置く（実行環境ローカルの揮発状態）。

---

## 9. 受け入れ基準（テストケース）

実装は以下を満たすこと。

| # | 入力 | 期待 |
| --- | --- | --- |
| 1 | rate_limits を含む正常 stdin を tee に通す | 妥当な JSON の state ファイルが atomic に生成される |
| 2 | rate_limits を含まない stdin（非 Pro/Max 等） | 各値が `null`・JSON は妥当 |
| 3 | `used_percentage=42`, 閾値80 | `VERDICT=OK` / exit 0 |
| 4 | `used_percentage=85`, 閾値80 | `VERDICT=DEFER` / exit 10 |
| 5 | `used_percentage=80`（境界） | `VERDICT=DEFER`（`>=`） / exit 10 |
| 6 | `written_at` が 1200 秒前（>900） | `VERDICT=UNKNOWN` / exit 20・REASON に陳腐化明示 |
| 7 | state ファイル無し（statusline 未設定相当） | `VERDICT=UNKNOWN` / exit 20（fail-open）・REASON に未生成明示 |
| 8 | `RATE_GUARD_THRESHOLD=30`, `used_percentage=42` | `VERDICT=DEFER` |
| 9 | 実データ（実セッションで tee 発火後）に対し gate 実行 | 権威値で OK/DEFER が返る（スモーク） |
| 10 | statusline 未設定の環境に付録 A-1 を新規設定し、対話で 1 往復 | state ファイルが生成され、gate が権威値を返す（新規導入スモーク） |
| 11 | tee 追記後の既存 statusline 単体実行 | 従来の描画が不変（非破壊確認） |
| 12 | `five_hour.used_percentage=null`（非 Pro/Max 相当） | `UNKNOWN` / exit 20・REASON に「rate_limits 欠落＝ゲート無効」明示 |
| 13 | `RATE_GUARD_THRESHOLD=5` / `=99` | stderr に誤設定警告・stdout の KEY=VALUE は不変 |
| 14 | tee の書込を失敗させる（権限/ディスク等） | statusline は `exit 0`（描画継続）・`rate-guard.tee.log` に失敗記録 |
| 15 | `written_at` が非数値（`"abc"`/小数/16進等） | `UNKNOWN` / exit 20（クラッシュせず契約準拠）・REASON に非数値を明示 |

---

## 10. 既知の限界・非目標

- **statusline コマンドへの依存**：tee は statusline コマンドの実行に寄生する。**未設定なら恒久 `UNKNOWN`**。導入はまず付録 A-1 のコマンド設定から始まる（§2.4・§11）。
- **対話セッション限定**：判定・監視の実行主体はエージェントで、セッションが稼働している間のみ働く（`TaskStop`/`resumeFromRunId` はセッション紐付き）。**headless/非対話起動では statusline が発火せず控えが陳腐化** するため、長時間 WF は対話セッションから起動する。セッションを閉じれば監視者は不在＝mid-run watchdog（FR-08）も止まる。
- **Pro/Max 限定**：`rate_limits` は Claude.ai Pro/Max サブスクライバーにのみ提供される。APIキー課金では恒久 `UNKNOWN`（fail-open 素通り）となり、本ゲートは適用できない。
- **mid-run stop は phase 境界を保証しない**：外部 poll での stop ゆえ中断位置は不定。中断 agent は resume で再走するため read-only WF は無害だが、副作用 WF は冪等キーが前提。
- **検出のみ非強制**：強制（フックでのブロック）は別判断（付録 C）。本書は「エージェントが自ら参照する」前提。
- **対象は scope-(i) のみ**：dispatcher 管理タスクは対象外。
- **idle 時の陳腐化**：描画が止まると控えが古くなる。ただしゲート対象は稼働中ワークフローなので実害は小さく、鮮度判定（FR-04）が UNKNOWN で吸収する。
- **権威値だがバージョン依存**：値はサーバ提供で推定でないが、stdin スキーマは Claude Code 版に依存（§8）。

---

## 11. ロールアウト手順（新規導入）

statusline 未設定の環境を起点に、最小手数で導入する。既に statusline がある場合は手順 2〜3 を「tee ブロックの追記」に読み替える。

1. **前提検証**（§2.4・§8）：対象が **Pro/Max サブスクか**、**対話 TUI で使うか**を確認。いずれも満たさなければ恒久 `UNKNOWN`（fail-open）になることを導入者へ周知。
2. **statusline コマンド配置**：付録 A-1 の `statusline-command.sh` を `~/.claude/` に置き、実行権限を付与（`chmod +x`）。
3. **settings.json への配線**：`statusLine.command` を当該スクリプトへ向ける（付録 A-1 末尾の設定例）。既存 statusline があるなら、そのコマンドへ tee ブロックのみ追記し配線は変更しない。
4. **gate 配置**：付録 A-2 の `rate-guard.sh` を配置し実行権限付与。
5. **挙動契約の明記**：FR-06（pre-flight）と FR-08（mid-run watchdog）をその repo のエージェント memory / 運用ドキュメントに記載。
6. **受け入れ確認**：§9 のテスト、特に #10（新規導入スモーク）を対話セッションで実行し、state 生成 → gate が権威値を返すことを確認。
7. （任意）取りこぼしを完全に潰すなら付録 C（強制フック）を検討。

---

## 12. 運用上の約束（事故予防）

ゲート機構そのものが健全でも、運用を誤れば事故になる。導入先で守るルール。

- **watchdog 配下は read-only WF を原則**：mid-run stop は phase 境界を保証せず、中断 agent は resume で再走する。**副作用（ファイル書込/外部投稿/DB 更新/アップロード）を持つ WF は冪等キー（`request_hash`/`batch_id` 等）必須**。冪等にできない WF は watchdog に載せない。
- **detached サブプロセスは自衛させる**：WF が `TaskStop` で死なない外部プロセスを起動するなら、**そのプロセス自身に最大実行時間／自己 gate を持たせる**。セッションを閉じると監視者（エージェント）は消えるため、監視者不在でも自滅できること。
- **poll は粗い間隔で固定し、reset 境界はバックオフ**：各 wakeup はトークンを消費する。上限近傍で監視自身が枠を食い潰さないよう間隔は分単位、reset 推定ずれの thrash は再確認ガード＋バックオフで抑える（NFR-08）。
- **重い単発 WF は余白を取る**：pre-flight は起動時点の使用率しか見ず WF の消費量を知らない。1 枠を食いうる WF は **閾値を下げて余白を確保**（例 80→60）するか、**FR-08 watchdog 前提**に切り替える。
- **閾値は env で渡す**：恒久変更を `settings.json` 等に固定すると、定常使用率より低い閾値で **reset 後に再び閾値超→恒久 DEFER 詰み** を起こす。閾値変更は gate 呼び出し時の env（その場限り）に留める。

---

## 付録 A：リファレンス実装

### A-1. statusline コマンド（`~/.claude/statusline-command.sh`・tee 内蔵）

statusline 未設定の環境へ **そのまま新規設定できる完結スクリプト**。stdin から rate_limit を抽出して控えを書き（tee）、任意で 1 行の可視バーを描画する。可視バーが不要なら末尾の「可視バー」ブロックを `:`（何もしない）に置き換えてよい——tee の副作用はそのまま機能する。

```bash
#!/usr/bin/env bash
# Claude Code statusline コマンド ＋ rate-limit 控え出力（tee）。
# stdin の状態 JSON を読み、rate-guard 用の state を永続化し、任意で 1 行を描画する。
input=$(cat)

# --- rate_limit 等の抽出（Pro/Max のみ存在。無ければ空＝後段で null 化） ---
five_pct=$(echo   "$input" | jq -r '.rate_limits.five_hour.used_percentage  // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at         // empty')
week_pct=$(echo   "$input" | jq -r '.rate_limits.seven_day.used_percentage   // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at         // empty')
used_pct=$(echo   "$input" | jq -r '.context_window.used_percentage          // empty')

# --- tee: rate-limit 状態を atomic に控える（描画と隔離・失敗は痕跡を残す） ---
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

# --- 可視バー（任意・cosmetic）。不要なら次の3行を `:` に置換してよい ---
model=$(echo "$input" | jq -r '.model.display_name // empty')
printf '%s' "${model:+$model}"
[ -n "$five_pct" ] && printf ' · 5h %s%%' "$five_pct"

exit 0   # tee 失敗・可視バーの短絡で非ゼロ終了 → statusline ブランク化を避ける
```

`settings.json` への配線（未設定環境の場合）：

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-command.sh"
  }
}
```

> 既存の statusline がある環境では、配線は変えず、その既存コマンド内に上記「tee」ブロックのみを追記する。抽出（`five_pct` 等）が未定義なら、抽出行も併せて追記する。

### A-2. `rate-guard.sh`（判定スクリプト全文）

```bash
#!/usr/bin/env bash
# 5時間セッション枠に「1本回す余力」があるかを判定する純コード（LLM不使用）。
# 出力: KEY=VALUE 行 / 終了コード 0=OK 10=DEFER 20=UNKNOWN(fail-open)
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
```

---

## 付録 B：mid-run watchdog の運用手順（FR-08 の詳細）

1 枠（5h）を超える単発ワークフローを完走させるための手順。

**実体**：新規プログラムではなく、エージェントが既存プリミティブ（`rate-guard.sh` ＋ Workflow ツール標準の `run_in_background` / `TaskStop` / `resumeFromRunId`）の上で回す監視ループ。`TaskStop`/`resumeFromRunId` はセッション紐付きのため **監視主体はエージェント自身**（素の cron では不可）。

**ループ（擬似手順）**：

```
launch:  runId = Workflow(scriptPath, run_in_background=true)

poll loop（粗い間隔で wakeup・各回 rate-guard.sh を実行）:
  VERDICT=OK    かつ 実行中  → 次 poll を再予約
  VERDICT=DEFER かつ 実行中  → TaskStop(runId)              # journal は保全される
                               RESETS_AT を記録し再開を予約（FR-07 と同じスケジューリング）
  完了通知を受領             → ループ終了（成果物を回収）

resume（予約発火時）:
  rate-guard.sh 再確認 → OK を確認（thrash 防止）
  Workflow(scriptPath, resumeFromRunId=runId, run_in_background=true) で続行
  poll loop へ再投入（複数枠を跨ぐなら DEFER のたびに繰り返す）
```

**設計上の要点**：

- **80% で能動 stop する価値**：100% 被弾を待つと Workflow の `agent()` がリトライ後 `null` に握り潰され **縮退結果が黙って返る**（沈黙切り捨て）。閾値での `TaskStop` はクリーンに中断し journal を残すため、これを避けられる。
- **停止位置は不定**：外部 poll ゆえ phase 境界では止まらない。中断時に走っていた agent は resume で再走する。**read-only WF（コードレビュー等）は無害**。副作用（ファイル書込/外部投稿/DB 更新/アップロード）を持つ WF は冪等キー（request_hash/batch_id 等＝疎結合契約#4）で二重発火を吸収できる範囲に限る。
- **resume の前提**：スクリプトは決定論的であること（`Date.now()`/乱数に依存しない）。同一 script ＋同一 args なら完了済み agent は 100% キャッシュ復元される。
- **detached サブプロセス**：WF が外部プロセスを起動する場合、それは `TaskStop` で死なない。再開時は再 launch でなく **既存センチネル/ロック（PID 生存）を poll** して続行する（detached+poll 方式）。
- **poll コスト**：各 poll は「state 読取＋数値比較」のみ。間隔は粗く（cache 維持を意識）。上限近傍で監視自身が枠を食わないこと（NFR-08）。

## 付録 C：強制（PreToolUse フック）への格上げ（任意）

取りこぼし（エージェントが gate 実行を忘れる/recall 漏れ）を完全に潰したい場合のみ。

- `Workflow` ツールへの PreToolUse フックで `rate-guard.sh` を実行し、`DEFER` ならツール呼び出しをブロック＋理由を返す。
- **代償**：全 Workflow 呼び出しに無差別作用（軽量な呼び出しも対象）。スクリプトのバグで全面封鎖し得る foot-gun。例外運用には bypass 機構（env フラグ・特定 label 除外）が別途必要。
- **限界**：フックが硬くできるのは「起動のブロック」まで。延期予約・ユーザー告知という follow-through は結局エージェント挙動（FR-06/07）に残る。
- 採用時は設定ファイル（`settings.json` の `hooks`）の変更＝全セッション挙動の変更となるため、導入は明示承認のうえで。
