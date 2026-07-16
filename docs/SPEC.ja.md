# rate-guard 要件定義書

|   項目   |                                  内容                                  |
| -------- | ---------------------------------------------------------------------- |
| 文書ID   | SPEC-RATEGUARD-001                                                     |
| 想定読者 | 設計者 / 実装するエージェント / 各リポジトリへの導入担当者              |
| 適用範囲 | **特定のリポジトリに依存しない**（他のリポジトリにも展開する前提）。Claude Code 上で動く任意のリポジトリに移せる。**statusline をまだ設定していない環境にも新しく導入できる**ことを前提に書く |
| 前提環境 | Claude Code（statusline の仕組みと Workflow ツールを持つ版）。`bash` / `jq` / `awk` / `date` が使えること。**`rate_limits` の取得には Claude.ai Pro/Max プランが必要**（§2.4）。エージェントに現在時刻を毎ターン渡す手段（例：`UserPromptSubmit` フックで時刻を渡す）は、FR-07/08 の実時刻の通知に**推奨**（予約自体はゲートの `SECONDS_TO_RESET` でまかなえる・§2.4・§8） |

---

## 1. このドキュメントの位置づけ

「**rate-guard**」は、Claude Code の **5時間の利用枠（および7日枠）の残量を起動前に確認し、残りが少なければ長時間ワークフローの起動を次の枠まで自動で先送りする** 補助ツールである。本書はその要件定義であり、statusline をまだ設定していない環境の導入担当者でも、読めば同じものを一から作れることを目指す。

このツールは **検出のみで、強制はしない**。ハーネスがツール呼び出しを機械的に止めるのではなく、**判断材料を常にディスクに用意しておき、エージェントが起動の直前にそれを見て、自分の判断で先送りする** 方式をとる。強制（フックで止める）は本書の対象外（§10・付録 C を参照）。

### 1.1 解決する問題

- Claude Code のエージェントには、**自分の5時間枠の使用率や、次の枠のリセット時刻を返す API/ツールが無い**。`Workflow` の `budget` は「そのターンの出力トークンの目標」であって、口座側の利用枠とは別物である。
- 一方で、**statusline コマンドの標準入力には `rate_limits`（サーバが返す正式な値）が渡っている**。これを控えておけば、コードで判定できる。
- 残りが少ないまま長時間ワークフローを起動すると、**途中で枠が尽きてワークフローが中断し、全体が無駄になる**。起動前に止めれば、停止・再開という壊れやすい操作そのものを避けられる。

---

## 2. 背景と目的

### 2.1 背景

長時間（数十分規模）の処理を1ターンのワークフローで回す運用では、5時間枠が尽きると「途中で枠切れ→中断」という最悪の失敗になる。枠切れ後のメッセージはエージェントの文脈に届く形では取得できず、後からの対応はあてにならない。**起動するかどうかを起動前に決める（pre-flight ゲート）** のが、いちばん壊れにくい。

### 2.2 目的

- statusline コマンドが受け取る正式な値を **常にディスクに控える**（tee）。statusline が未設定の環境には、この控えを組み込んだ statusline コマンドを **新しく設定** する（付録 A-1）。
- その控えを読み、**5時間枠の使用率をしきい値（既定 80%）と比べて起動の可否を返す、コードだけの判定ツール** を用意する。
- エージェントが **長時間ワークフローを起動する直前に判定ツールを呼び、DEFER なら次の枠へ先送りする** という動作のルールを定める（pre-flight・FR-06）。起動の判断は閾値だけでなく、**推定消費と余裕（`HEADROOM_PCT`）の予算比較** で行う。
- 多数のユニットを処理する大規模ワークについては、**1枠に収まるバッチへ分割し、バッチ境界でゲートを再実行する** 標準形を定める（バッチ分割・FR-09。これが第一防衛線）。
- **1つの枠（5時間）を超える単発のワークフロー** については、走行中も判定ツールで監視し、しきい値に達したら **区切りで止め、リセット後に `resumeFromRunId` で自動再開する** という mid-run watchdog の動作ルールを定める（FR-08。バッチ運用が破れた場合の保険）。

### 2.3 対象範囲の線引き（**必読**）

|                     機能                      | 範囲内 / 範囲外 |                        理由                         |
| --------------------------------------------- | --------------- | --------------------------------------------------- |
| statusline コマンドの新規設定／tee の追記     | 内              | 正式な値を得る唯一の経路。受け身で無料。未設定の環境では新規作成が導入の起点 |
| statusline からの rate_limit の控え出力（tee）| 内              | 正式な値を得る唯一の経路。受け身で無料              |
| 5時間枠のしきい値判定（ゲート・コードのみ）   | 内              | 計算はコードで行う（LLM 不使用）                    |
| pre-flight で先送りする動作ルール（エージェント側）| 内          | 本ツールの主目的                                    |
| DEFER のときに次の枠へ起動を予約する          | 内              | リセット時刻が控えにあるので、決まった手順で予約できる |
| バッチ分割の標準形（大規模ワークの組み方・エージェント側） | 内 | 第一防衛線。走行中停止に頼らず、境界で止まる（FR-09） |
| **mid-run watchdog**（走行中に監視→しきい値到達で止め→リセット後に自動再開） | **内** | 1つの枠を超える単発タスクを最後までやり切るのに必須。pre-flight では救えない（FR-08・付録 B）。位置づけは保険 |
| クラッシュ耐性（再開情報の永続化・復旧手順） | 内 | セッション消滅で予約メカニズムごと消える単一障害点への備え（FR-10） |
| **強制（PreToolUse フックで止める）**         | **外**          | すべてのワークフローに一律で効く危険がある。別途判断（付録 C） |
| dispatcher（Slack 経由などの外部管理）タスクの判定 | **外**     | そちらは「区切りで停止→プロセス終了→再投入」が正しい道 |
| 24時間動き続ける常駐プログラム                | **外**          | 判定を実行するのはエージェント。セッションが動いている間だけ働く |

### 2.4 適用の前提とカバー範囲（**必読・導入前に確認**）

このゲートが正式な値で機能する（`OK`/`DEFER` を返す）には、下表の **目標とする状態** を満たす必要がある。満たさない場合は **安全側に倒して、恒久または一時の `UNKNOWN` に切り替わり**、ゲートは黙って無効になる（止めはしないが、守りもしない）。導入時は、この切り替わりの条件を必ず周知すること。

| 環境の条件 | ゲートの動き | 導入時の対応 |
| --- | --- | --- |
| 対話 TUI ＆ Pro/Max ＆ statusline 設定済み ＆ 初回 API 応答後 | **正常**（OK/DEFER） | 本書が目指す状態 |
| **`statusLine.command` 未設定** | 恒久 `UNKNOWN`（state ファイルが作られない） | §11・付録 A-1 で **新しく設定** すれば解消。本書の主な導入経路 |
| **headless / 非対話起動**（`claude -p`・SDK・非対話 cron） | state が更新されず古くなる → `UNKNOWN` | statusline は対話 UI の操作でしか動かない。**長時間ワークフローは対話セッションから起動する**こと。headless の常用は対象外 |
| **API キー課金（非 Pro/Max）** | `rate_limits` 自体が標準入力に来ない → 恒久 `UNKNOWN` | このゲートは使えない。安全側に倒して素通りし、枠切れ自体はハーネスの rate-limit エラーが最後の歯止めになる |
| 初回 API 応答前 | 一時 `UNKNOWN` | 1往復すれば解消（恒久ではない） |
| **エージェントに現在時刻が渡らない**（時刻を渡すフックなどが無い） | OK/DEFER は正常で、DEFER／再開の予約も動く：エージェントはゲートの `SECONDS_TO_RESET` を待ち時間に使う。影響するのは、エージェントが自分の言葉で実時刻を述べる部分だけ | **推奨だが必須ではない。** 通知の見栄えと妥当性確認のため `UserPromptSubmit` などで現在時刻を渡す（§8） |

- 切り替わりは全て **安全側（止めない）** なので「壊れはしない」が、「守っているつもりで守っていない」状態は危険である。NFR-07 のとおり、`UNKNOWN` は必ず `REASON` で見えるようにする。
- **時刻の把握はエージェントの動作（FR-06/07/08）の助けになるが、ゲートのフローには必須でない**。ゲートが判定（shell の `date`）と待ち時間（`SECONDS_TO_RESET`）の両方を出すので、エージェントは自分の時計が無くても予約できる。現在時刻の取得は、実時刻の通知や妥当性確認のために推奨。
- `rate_limits` は **Claude.ai Pro/Max 利用者の初回 API 応答後にのみ** 標準入力に現れ、`five_hour` / `seven_day` はそれぞれ欠けることがある（§8・公式スキーマに準拠）。

---

## 3. 用語の定義

| 用語 | 定義 |
| --- | --- |
| **scope-(i)** | エージェントが対話の中で直接回す `Workflow` ツールの起動。本ゲートの対象 |
| **statusline コマンド** | `settings.json` の `statusLine.command` に登録するシェル。Claude Code が UI の操作時に標準入力へ JSON を渡して実行する。**画面に見えるバーそのものではなく、コマンド本体**を指す |
| **tee** | statusline コマンドが実行されるたびに、rate_limit の状態をファイルへ写し取る処理 |
| **ゲート（gate）** | 控えを読み、起動の可否（OK/DEFER/UNKNOWN）を返す判定スクリプト |
| **5時間枠 / 7日枠** | Claude の利用上限を、一定時間ぶん移動しながら数える枠 |
| **`used_percentage`** | その枠の使用率（0〜100、サーバが返す値） |
| **`resets_at`** | その枠がリセットされる時刻（UNIX epoch 秒、サーバが返す値） |
| **fail-open** | 判断材料が無い／古いときに、止めずに起動を許す（不明であることは明示する）という安全側の設計 |

---

## 4. 全体の構成とデータの流れ

```
[Claude Code 本体]
   │  statusline コマンドの実行ごとに標準入力 JSON を渡す（UI 操作時・対話 TUI のみ）
   │  （.rate_limits.five_hour.{used_percentage,resets_at} など＝正式な値）
   ▼
[statusline-command.sh]  ──(tee: atomic write)──▶  [rate_limit_state.json]
   │                                                      │
   │（任意で画面に描画。tee は副作用ゼロ・失敗しても描画は続く）   │ 読み取り専用
   ▼                                                      ▼
[端末 UI（任意・空でも可）]                          [rate-guard.sh]  ──▶  VERDICT=OK|DEFER|UNKNOWN
                                                                        （exit 0 / 10 / 20）
                                                            │
                                                            ▼
                                      [エージェント]  起動の直前にゲートを実行し
                                        OK→起動 / DEFER→次の枠へ予約 / UNKNOWN→起動＋警告
```

データは **一方向** に流れる：本体 → tee → state ファイル → ゲート → エージェントの動作。state ファイルはゲートからは読み取り専用である。**見えるバーの有無はこの流れに関係しない**。標準出力が空でも statusline コマンドは実行され、tee の副作用は走る（§8）。

---

## 5. 機能要件

### FR-01 statusline コマンド（控え出力 tee を内蔵）

- 対象環境に statusline コマンドが **無ければ、本ツールが提供するコマンド（付録 A-1）を新しく設定** する。すでにあれば tee のブロックを **追記** する（**非破壊**：これまでの描画出力や終了の挙動を一切変えない）。
- statusline コマンドが受け取った標準入力 JSON から `rate_limits.five_hour.{used_percentage,resets_at}`・`rate_limits.seven_day.{...}`・`context_window.used_percentage` を取り出し、**現在時刻 `written_at`（epoch 秒）を付けて** state ファイルへ書く。
- **atomic write（一括書き込み）が必須**：一時ファイルへ書き、`mv -f` で置き換える。読み手が途中の状態を読むのを防ぐ。
- **書き込みの失敗が描画を妨げてはならない**：tee は描画から切り離し、スクリプトは最後に `exit 0` する。ただし **失敗を握りつぶさず、痕跡を残す**。失敗したときだけ `~/.claude/rate-guard.tee.log` に1行記録する（黙った故障で保護が消えるのを検知するため・NFR-09）。
- 該当フィールドが標準入力に無い場合（非 Pro/Max・初回応答前・版の差など）は、その値を **`null`** とし、JSON 自体は常に正しい形に保つ。
- **見えるバーは任意**：標準出力を空にすれば画面には何も出ないが、tee の副作用は走る。バーを出したい場合は付録 A-1 の表示ブロックを使う／差し替える。

### FR-02 state ファイルの形式（インターフェースの取り決め・§7 と同じ）

既定パスは `~/.claude/rate_limit_state.json`。

```json
{
  "written_at": 1781753494,
  "five_hour": { "used_percentage": 17, "resets_at": 1781758200 },
  "seven_day": { "used_percentage": 42, "resets_at": 1781791200 },
  "context":   { "used_percentage": 10 }
}
```

- 数値はサーバが返す値そのまま（小数も可）。取得できないフィールドは `null`。
- `written_at` は新しさの判定（FR-04）の基準。

### FR-03 ゲート（判定スクリプト）

- state ファイルを読み、`five_hour.used_percentage` を **しきい値（既定 80）** と比べる。
- **判定と終了コード**：
  - `used_percentage < しきい値` → `VERDICT=OK`、exit **0**
  - `used_percentage >= しきい値` → `VERDICT=DEFER`、exit **10**（同じ値のときは DEFER 側）
  - 材料が欠ける or 古い → `VERDICT=UNKNOWN`、exit **20**
- **出力は機械が読める `KEY=VALUE` 行**（標準出力）：`VERDICT` / `FIVE_HOUR_PCT` / `HEADROOM_PCT` / `RESETS_AT` / `RESETS_AT_HUMAN` / `SECONDS_TO_RESET` / `STATE_AGE_SECONDS` / `REASON`。`SECONDS_TO_RESET` は実行時にゲートが算出する `RESETS_AT − now`（リセット時刻が不明なら空、すでに過ぎていれば負値）。エージェントは自分の時計が無くても、この値で再開を予約できる。
- **`HEADROOM_PCT` ＝ 閾値までの余裕**（`しきい値 − used_percentage`、負なら `0`）。予算比較（FR-06）の右辺に使う。`OK`/`DEFER` のときだけ値を持ち、`UNKNOWN` では空。基準は 100% でなく **しきい値** であることに注意（しきい値までの余白は対話ターン用の予約として残す設計・FR-06）。
- **`STATE_AGE_SECONDS` ＝ 控えの経過秒**（実行時に算出する `now − written_at`。`written_at` が欠ける・数値でないときは空）。読み値の鮮度を機械判定できる。`written_at` が異なる 2 回の実行の `FIVE_HOUR_PCT` 差分と合わせるとバーンレート（pt/分）を実測できる（FR-08 の先読み DEFER・UNKNOWN 分岐の材料。**同じ write の再読は差分 0 に見えるだけで消費ゼロではない**ため、必ず `written_at` の異なる 2 点で差分を取る）。
- **表示の整形**：`FIVE_HOUR_PCT` / `HEADROOM_PCT` は `%g`（6有効桁）で整形し、サーバ値の浮動小数アーティファクト（例 `14.000000000000002` → `14`）だけを除去する。実質の精度は保たれるため、**前後差分による計測（FR-06 の計測バッチ）を壊さない**。判定は整形前の生値で行い、表示と食い違う極端な境界では `VERDICT` が正。数値出力はロケールに依存しない（`LC_ALL=C`・小数点は常にピリオド）。
- 小数の比較は `awk` などで行う（bash の整数比較に丸めない）。
- **LLM を一切使わない**（判定と計算はコードで行う）。
- **しきい値の妥当性チェック**：`RATE_GUARD_THRESHOLD` が妥当な範囲 `[10,95]` を外れたら **標準エラーに警告** する（設定ミスの検知）。判定は続け、**標準出力の KEY=VALUE は汚さない**。上げすぎ＝無防備、下げすぎ＝恒久 DEFER で詰む、の両方に早く気づけるようにする。

### FR-04 新しさ・欠落＝安全側（原因を区別して見せる）

- state ファイルが **無い / `written_at` が欠ける・数値でない / `five_hour.used_percentage` が `null` または数値でない / `written_at` が現在から `STALE_SECONDS`（既定 900 秒）より古い** のいずれかなら `UNKNOWN`（exit 20）を返す。
- UNKNOWN は **止めない**（fail-open）。理由は、初回の未生成・放置後に古くなった・非 Pro/Max・headless での未発火などで、すべてのワークフローを誤って止めるのを避けるため。枠切れ自体はハーネスの rate-limit エラーが最後の歯止めになる。
- **黙らせず、原因を `REASON` で区別する**（同じ UNKNOWN でも対処が違うため）：
  - state ファイル無し → 「`statusLine.command` 未設定 or tee 未実行」
  - `written_at` が欠ける・数値でない → 「state の破損／tee の故障の疑い（`rate-guard.tee.log` を参照）」。計算の前に整数かを確認し、数値でなくてもクラッシュせず UNKNOWN を返す
  - `used_percentage` が `null` → 「**rate_limits が無い＝非 Pro/Max または初回応答前**。ここではゲートは効かない」（構造的・恒久の可能性）
  - `used_percentage` が数値でない → 「state の破損／tee の故障の疑い」。**0 と誤読して `OK`（満額の `HEADROOM_PCT`）を返してはならない**
  - 古い → 「古い。**UI イベントが無く statusline が発火していない**（放置だけでなく、メインループがバックグラウンド完了待ちで沈黙する対話セッションでも起きる。§8 の `refreshInterval` で解消可）か、tee の故障の疑い（`rate-guard.tee.log` を参照）」（一時 or 故障）

### FR-05 設定パラメータ（環境変数で上書き可）

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `RATE_GUARD_THRESHOLD` | `80` | 起動を止める使用率の下限（この値以上で DEFER） |
| `RATE_GUARD_STALE_SECONDS` | `900` | これより古い控えは UNKNOWN |
| `RATE_GUARD_STATE_FILE` | `~/.claude/rate_limit_state.json` | 控えのパス（テストで差し替える用） |

- `RATE_GUARD_THRESHOLD` の **妥当な範囲は `[10,95]`**（外れると FR-03 の警告）。恒久的に変えたいときも **`settings.json` ではなく、ゲート呼び出し時の環境変数で渡す**。ふだんの使用率より低いしきい値を固定すると、リセット後にまたしきい値を超え、**恒久的に DEFER のまま詰む**（§12）。

### FR-06 エージェントの動作ルール（検出のみ方式の中核）

scope-(i) で **1本まるごと回る長時間ワークフローを起動する直前** にゲートを実行し、`VERDICT` に従う：

| VERDICT | 動作 |
| --- | --- |
| `OK` | そのまま起動 |
| `DEFER` | **起動しない**。`RESETS_AT` の直後に起動を予約し、ユーザーへ「次の枠（`RESETS_AT_HUMAN`）に先送りした」と伝える |
| `UNKNOWN` | 安全側で起動するが「残量が不明」と明示する（§2.4 の切り替わり条件のどれかに当たる可能性も添えると親切） |

- このルールは **導入先リポジトリのエージェントの記憶（memory）または運用ドキュメント（CLAUDE.md など）に明記** し、文脈の要約をまたいでも参照されるようにすること（検出のみ方式なので、思い出してもらえるかどうかに依存するため）。

**予算比較（閾値判定の拡張・大規模ワークでは必須）**

閾値との単純比較は「起動時点の残量」しか見ず、これから起動するワークフローの消費量を知らない。高並列のフリート（バーンレートが数 pt/分に達する規模）では、`OK` 直後に枠を焼き切る事故が実測されている（使用 63% で 16 並列を一括起動 → 約 7pt/分で約 5 分後に 100%・在飛行中の呼び出しが全損）。そこで長時間ワークフローの起動判断は、`VERDICT=OK` に加えて次を標準とする：

> **推定消費（pt） × 安全係数 1.3 ≦ `HEADROOM_PCT`** を満たす場合のみ起動する。満たさなければ、収まる大きさへバッチを分割する（FR-09）。

- **推定単価は実測で適応させる**：静的な仮定ではなく、最初に小さな計測バッチを流し、前後の `FIVE_HOUR_PCT` の差から pt/ユニットを求め、以降のバッチサイズを決める。単価はモデル構成で数倍変わる（実測で約 2.7 倍差）。
- **`FIVE_HOUR_PCT` の鮮度に注意**：state の更新は statusline の実行（新しいアシスタントメッセージ等・§8）に依存する。バックグラウンド走行中は監視の起床がその契機になるため、計測値は「最後に statusline が動いた時点」の値である。
- **計測差分が 0 のときは単価 0 としない**：直前の項の遅れにより、計測バッチ直後の読み取りには消費が未反映のことがある。差分 0 は「タダ」ではなく「未計測」。state の更新後に読み直すか、計測バッチを大きくする。**単価 0 のままサイズ計算に進んではならない**（`0 × 何でも ≦ 余裕` が常に成立し、バッチが無制限になる）。
- **fan-out（総エージェント数）が不明なワークフローは見積不能として扱う**：既成・名前付き workflow の fan-out は自作の桁上になりうる（実測：検証型 code-review workflow（high・70 ファイル diff）＝ 27 エージェント・約 158 万トークン ≒ 70pt。使用 9% で `OK` を得て起動したが走行中に 100% へ到達し、in-flight の統合ステップを失った）。`VERDICT=OK` だけで起動せず、小さな計測実行で単価と fan-out を確定してから予算比較する。所見数に応じて verifier が事後に増える構成（レビュー系など）は、平均でなく**上限系（候補数 × verifier 単価）**で見積もる。
- **読み値のジッターに注意（複数セッション併用時）**：state は「最後に statusline を実行したセッションが、最後の API 応答で見た値」で上書きされる（§8）。複数セッションを併用すると鮮度の異なる値が交互に書かれ、`FIVE_HOUR_PCT` は数 pt 規模で非単調に行き来する（実測）。単価計測（前後差分）は自セッションだけが消費している状態で行い、負の差分は 0 でなく「計測不成立」として測り直す。
- **最小バッチすら収まらないときは DEFER 扱い**：`VERDICT=OK` でも `HEADROOM_PCT` が最小のバッチに満たない場合（しきい値の直下では 0 に近づく）は、DEFER と同じ手順（FR-07）で `RESETS_AT` 直後へ次の起動を予約する。OK のまま黙って保留し続けない（黙った先送りは NFR-07 違反）。
- **余白は意図的に二重**：安全係数 1.3（見積もり誤差の吸収）に加えて、しきい値（既定 80）が 100% までの 20pt を対話ターン用に予約する。重ね掛けは意図的であり、どちらか一方を外さない。

### FR-07 DEFER のときの予約

- 起動の予約時刻は `RESETS_AT` ＋ 余白。**余白の既定は 120 秒**（待ち時間は `SECONDS_TO_RESET + 120`）。リセット推定のずれを吸収する。
- リセットまで **1時間以内** なら短時間スリープ系（例：`ScheduleWakeup`、最大 3600 秒）。**それ以上** なら一回限りの cron（例：`CronCreate`）かスリープの連鎖。
- **再開時の再確認**：予約が発火したら、起動の直前にもう一度ゲートを実行し、`OK` を確認してから起動する（リセット推定のずれによる、すぐの再枠切れ＝thrash を防ぐ）。
- **`SECONDS_TO_RESET` を使う。現在時刻は推奨であって必須ではない**：ゲートが `SECONDS_TO_RESET`（実行時に `RESETS_AT − now` で算出した待ち時間）を出力するので、エージェントは自分の時計が無くても、この値で再開を予約でき、「1時間以内か超か」の分岐（`< 3600` か否か）も判断できる。値は時間とともに古くなるため、ゲート実行後すみやかに予約すること。現在時刻を毎ターン渡す手段（例：`UserPromptSubmit` フック）は、自分の言葉で実時刻を伝える場合や妥当性確認には引き続き推奨だが、予約自体には不要であり、`now` 捏造のリスクも消える（§2.4・§8）。

### FR-08 mid-run watchdog（1つの枠を超える単発ワークフローをやり切る・保険）

pre-flight（FR-06）は「残りが少ないときに *始めない*」だけで、**満タンから始まって1つの枠（5時間）を食い切る単発タスクは救えない**。これを補う、走行中の監視である。位置づけは **保険（第二防衛線）**：第一防衛線は予算比較（FR-06）とバッチ分割（FR-09）であり、走行中停止（in-flight 作業の損失を伴う）に日常的に依存しない。watchdog は見積もり外れやバッチ外の消費が起きた場合の受け皿として併用する。

- **適用条件**：pre-flight を `OK` で通ったが、消費が1つの枠を超えうる単発ワークフロー（読み取りだけを優先）。
- **起動**：`Workflow` を `run_in_background` で起動し、`runId` を保持する。
- **監視（ポーリング）**：エージェントが一定間隔で起き、`rate-guard.sh` を実行する。
  - `OK` かつ実行中 → 次の監視を再予約。
  - `DEFER`（≥しきい値）かつ実行中 → **`TaskStop(runId)`**（journal は保たれる）→ `RESETS_AT` を記録し、再開を予約（FR-07 と同じ手順）。
  - **`UNKNOWN`（古い等）かつ実行中 → OK 扱いにしない（1 読み値で楽観しない）**。最後に既知の `FIVE_HOUR_PCT` に「経過時間 × バーンレート」を足して現在値を保守的に推定し、推定がしきい値以上なら DEFER と同じ手順で停止する。バーンレートは **`written_at`（`STATE_AGE_SECONDS`）が異なる 2 点**の差分から実測する。実測 2 点がまだ無ければ、pre-flight の予算比較（FR-06）で用いた推定単価から導いた値で代用する。statusline はイベント駆動のため（§8）、メインループが完了待ちで沈黙すると tee は発火せず、**監視が必要な長い走行ほど確実に stale 化する**（実測）。恒久対処は `statusLine.refreshInterval`（§8）。
  - 完了の通知を受けた → ループ終了（成果物を回収）。
- **監視間隔は式で決める（固定の「◯分」にしない）**：しきい値到達から 100% までの余白を、バーンレートが食い切る前に必ず1回は起きる必要がある。

  > **tick 間隔 ＜ (100 − しきい値) ÷ 最大バーンレート（pt/分）**

  例：しきい値 80・バーンレート 7pt/分（16 並列フリートの実測値）なら上限は約 2.8 分。20 分間隔では最初の tick の前に全損した実測がある。さらに state は「最後に statusline が動いた時点」の値なので、**実効の遅れは tick 間隔＋state の鮮度** になる。プロンプトキャッシュの維持（270 秒以内）と両立する範囲で詰める。
- **先読み DEFER（推奨）**：監視側は前回 tick の `FIVE_HOUR_PCT` を控え、直近 2 点の差分からバーンレート（pt/分）を求める。「しきい値到達までの残り時間 ＜ tick 間隔」なら、**しきい値未達でも DEFER と同じ手順で停止**してよい（次の tick では手遅れのため）。履歴の保持は監視側（エージェント）の責務とし、ゲートはステートレスのまま（§7 の取り決め#4）。
- **再開**：予約発火 → `rate-guard.sh` で再確認 → `OK` → `Workflow(scriptPath, resumeFromRunId=runId)` で続行 → 監視ループへ戻す。**複数の枠をまたぐ場合は DEFER のたびに繰り返す**。`resumeFromRunId` は **同一セッション内でのみ有効**（セッションが消えた場合は FR-10 の復旧経路）。
- **80% で能動的に止める理由**：100% の枠切れを待つと、Workflow の `agent()` がリトライ後に `null` に握りつぶされ、**縮退した結果が黙って返る**（黙った打ち切り）。しきい値での `TaskStop` はきれいに中断し journal を残すので、これを避けられる。
- **安全性**：止めるのは外部からの監視なので、**区切り（phase 境界）では止まらない**。中断したエージェントは再開でやり直すため、**読み取りだけのワークフローは無害**。書き込みなどを伴うものは、冪等キー（疎結合の取り決め#4）を前提とする。
- 詳しい手順は付録 B。

### FR-09 バッチ分割（大規模ワークの標準形・第一防衛線）

多数のユニット（ファイル・タスクなど）を処理する大規模ワークは、走行中停止に頼らず、次の標準形で組む：

1. **計測バッチ**：小さなバッチを流し、前後の `FIVE_HOUR_PCT` の差から pt/ユニットを実測する（FR-06 の予算比較の単価）。
2. **バッチサイズの決定**：`バッチの推定消費 × 1.3 ≦ HEADROOM_PCT` を満たす大きさに切る（＝1枠に収まるバッチ）。
3. **バッチ境界でゲートを再実行**：各バッチの起動直前に FR-06 の pre-flight を行う。`DEFER` ならリセット後に次バッチ（FR-07 の予約手順）。
4. **バッチごとに成果を確定**：コミット等の冪等チェックポイントで成果を確定してから次バッチへ進む。

枠跨ぎは「境界で止まり、リセット後に次バッチ」となるため、**in-flight 作業の損失が構造的に発生しない**。mid-run watchdog（FR-08）は、この運用が破れた場合（見積もり外れ・バッチ外の消費）の保険として併用する。実測では、この標準形の導入後に 5 時間枠 4 枠連続で計画どおり完走している。

### FR-10 クラッシュ耐性（セッション消滅からの復旧）

FR-07/08 の予約（wakeup・セッション限定 cron）と `TaskStop`/`resumeFromRunId` は **セッションに紐づく**。プロセスクラッシュやセッション消滅では **再開予約のメカニズムごと消える**（実測済みの故障モード）。単一障害点にしないため、復旧材料を残す。

- **再開情報の永続化**：長時間ワークフローの起動時に、復旧に必要な情報（scriptPath・runId・バッチ進捗・再開予定時刻・journal/transcript の場所）を **永続ファイル**（例 `~/.claude/rate-guard/resume.json`）へ書き出し、バッチ境界ごとに更新する。書くのは **エージェント**（ゲートは書かない。§7 の取り決め#4 は不変）。
- **再開の2経路を区別する**：
  - **同一セッション内**：`resumeFromRunId` による透過再開（キャッシュ再利用・損失最小）。
  - **セッション横断（クラッシュ後）**：`resumeFromRunId` は同一セッション限定のため使えない。resume.json を道標に journal（`journal.jsonl`・`agent-*.jsonl`）を読み、**残作業の継続スクリプトを書き起こして新規 Workflow として実行**する（半自動復旧）。バッチ分割（FR-09）で成果を確定していれば、失うのは最後の未確定バッチだけで済む。
  - 次のセッション開始時に resume.json の未完了エントリを確認する手順を、導入先の運用ドキュメントに含める。
- **プロセス外の起床はトリガーであって透過再開ではない**：OS の cron / systemd timer による再起動は headless になり、statusline が動かずゲートは `UNKNOWN`、`resumeFromRunId` も効かない（§2.4）。プロセス外タイマーは「復旧開始の通知・きっかけ」として設計し、復旧そのものは対話セッションで行う。
- **置き場所**：ワークフロースクリプト・中間成果物は `/tmp` でなく永続ディレクトリに置く（`/tmp` はクラッシュ・再起動で失われる。実測済み）。

---

## 6. 非機能要件

| ID | 要件 |
| --- | --- |
| NFR-01 | **非破壊**：既存 statusline の描画・終了の挙動を変えない。tee の失敗は描画に波及しない。新規設定時も Claude Code の既定の挙動を壊さない |
| NFR-02 | **追加の遅延を最小に**：tee は `jq` 1回の呼び出しに収める |
| NFR-03 | **利用枠のコストはゼロ**：判定はコードだけ。LLM のターンを消費しない |
| NFR-04 | **失われにくい**：判断材料はディスクにあり、エージェントの文脈の喪失（要約・キャッシュ消滅）に依存しない |
| NFR-05 | **移植しやすい**：依存は `bash`/`jq`/`awk`/`date` のみ。GNU/BSD どちらの `date` でもリセット時刻の整形が動く（両方の書き方を順に試す） |
| NFR-06 | **安全側で安全**：不明なときは止めず、不明であることを見せる |
| NFR-07 | **黙った打ち切りの禁止**：DEFER/UNKNOWN は必ず `REASON` で説明し、先送りはユーザーへ通知する |
| NFR-08 | **監視のコストを低く**：監視は粗い間隔（キャッシュ維持を意識）で、各回「state の読み取り＋数値の比較」だけ。上限の近くで監視自体が枠を食い潰さないこと |
| NFR-09 | **tee の故障を見えるように**：tee は失敗を握りつぶさず痕跡を残す（`rate-guard.tee.log`）。描画は壊さない（最後に `exit 0`）。黙った故障で保護が消える事態を検知できるようにする |

---

## 7. インターフェースの取り決め（壊してはいけない約束）

1. **state ファイルの形式**（FR-02）。キー名・`written_at` の epoch 秒・`null` 許容を変えない。
2. **ゲートの標準出力の取り決め**：`KEY=VALUE` 行・キー名 `VERDICT/FIVE_HOUR_PCT/HEADROOM_PCT/RESETS_AT/RESETS_AT_HUMAN/SECONDS_TO_RESET/STATE_AGE_SECONDS/REASON`（`HEADROOM_PCT` は v0.2.0、`STATE_AGE_SECONDS` は 2026-07 に追加）。キーの**追加**は可（既存キー名は変えない）。
3. **終了コード**：`0=OK / 10=DEFER / 20=UNKNOWN`。呼び出し側はこのコードで分岐してよい。
4. データの流れは一方向（§4）。ゲートは state を **読み取り専用** とし、書き換えない。

---

## 8. 導入時の前提と差分（**導入前に必ず確認**）

- **いちばん大事な前提（見えること）**：対象の Claude Code が statusline の標準入力に `rate_limits.five_hour.used_percentage` / `resets_at` を **実際に渡しているか** を最初に確認する（`statusLine.command` に echo のデバッグを入れる／作られた state ファイルを見る）。渡されない環境（§2.4 の切り替わり条件）では、本ツールは恒久 `UNKNOWN`（fail-open）に切り替わり、ゲートは機能しない。
- **statusline が動く条件（公式）**：`statusLine.command` は **新しいアシスタントのメッセージ後・`/compact` 完了時・パーミッションモード変更時・Vim モード切替時** に実行され、更新は 300ms ぶんまとめられる。**未設定なら一切実行されない**。これらは対話 UI の操作であり、headless/print モードでは動かない前提で設計する（§2.4）。公式も「メインセッションがアイドルの間（バックグラウンドのサブエージェント待ちなど）はこれらのトリガーが沈黙する」と明記しており、**長い走行の監視中こそ tee が止まる**（FR-08・§10）。
- **タイマー再実行 `statusLine.refreshInterval`（公式・watchdog 運用では推奨）**：秒単位（最小 1）で、イベント駆動に加えて一定間隔でも statusline を再実行する設定。上記のアイドル空白への公式の対処であり、tee もタイマーで発火する。実測（Claude Code 2.1.211）：設定はセッション再起動なしで反映され、メインループが完全アイドルでもタイマーが発火した。watchdog（FR-08）を使う運用では 60 秒程度を推奨。
- **stdin の `rate_limits` は「そのセッションが最後の API 応答で見た値」（実測）**：タイマー再実行は control 入力を新しく取得するのではなく、セッションが保持する最新値を書く。走行中のセッションでは値も新鮮に保たれる一方、**何も実行していないセッションのタイマーは、古い値を新しい `written_at` で上書きする**。複数セッション併用時はこの混在で `FIVE_HOUR_PCT` が非単調になる（±数 pt の行き来を実測。FR-06 のジッター注意）。`written_at` の新しさは「tee が動いた時刻」であって「値の新しさ」の保証ではない、と理解して読むこと。
- **`rate_limits` が来る条件（公式）**：`rate_limits` は **Claude.ai Pro/Max 利用者の初回 API 応答後** に標準入力へ現れる。`five_hour` / `seven_day` はそれぞれ欠けることがある。API キー課金の利用者には来ない。
- **見えるバーは独立（公式）**：スクリプトが標準出力に何も出さなくても statusline コマンドは実行され、ファイル書き込みなどの副作用は走る。よって **見えるバーを出さない運用でも tee は機能する**。
- **フィールドの場所は版に依存**：上記のキー名は Claude Code の版で変わりうる。実環境の標準入力 JSON を実際に見て確定すること。
- **`date` の方言**：リセット時刻の整形は GNU（`date -d @epoch`）と BSD（`date -r epoch`）の両方を順に試すこと。
- **パスの違い**：`~/.claude` 配下を既定とするが、環境変数で差し替えられるようにしておく。
- **state ファイルは git の管理外** に置く（実行環境ローカルの揮発的な状態）。

---

## 9. 受け入れ基準（テストケース）

実装は以下を満たすこと。

| # | 入力 | 期待 |
| --- | --- | --- |
| 1 | rate_limits を含む正常な標準入力を tee に通す | 正しい JSON の state ファイルが一括で作られる |
| 2 | rate_limits を含まない標準入力（非 Pro/Max など） | 各値が `null`・JSON は正しい |
| 3 | `used_percentage=42`, しきい値 80 | `VERDICT=OK` / exit 0 |
| 4 | `used_percentage=85`, しきい値 80 | `VERDICT=DEFER` / exit 10 |
| 5 | `used_percentage=80`（同じ値） | `VERDICT=DEFER`（`>=`） / exit 10 |
| 6 | `written_at` が 1200 秒前（>900） | `VERDICT=UNKNOWN` / exit 20・REASON に「古い」を明示 |
| 7 | state ファイル無し（statusline 未設定に相当） | `VERDICT=UNKNOWN` / exit 20（fail-open）・REASON に「未生成」を明示 |
| 8 | `RATE_GUARD_THRESHOLD=30`, `used_percentage=42` | `VERDICT=DEFER` |
| 9 | 実データ（実セッションで tee 発火後）にゲートを実行 | 正式な値で OK/DEFER が返る（スモーク） |
| 10 | statusline 未設定の環境に付録 A-1 を新規設定し、対話で1往復 | state ファイルが作られ、ゲートが正式な値を返す（新規導入スモーク） |
| 11 | tee 追記後の既存 statusline を単体で実行 | これまでの描画が変わらない（非破壊の確認） |
| 12 | `five_hour.used_percentage=null`（非 Pro/Max に相当） | `UNKNOWN` / exit 20・REASON に「rate_limits が無い＝ゲート無効」を明示 |
| 13 | `RATE_GUARD_THRESHOLD=5` / `=99` | 標準エラーに設定ミスの警告・標準出力の KEY=VALUE は変わらない |
| 14 | tee の書き込みを失敗させる（権限/ディスクなど） | statusline は `exit 0`（描画は続く）・`rate-guard.tee.log` に失敗を記録 |
| 15 | `written_at` が数値でない（`"abc"`/小数/16進など） | `UNKNOWN` / exit 20（クラッシュせず取り決めどおり）・REASON に「数値でない」を明示 |
| 16 | 未来の `resets_at` を含む実 state | `SECONDS_TO_RESET` が出力され `RESETS_AT − now` に一致（リセット時刻が無ければ空、すでに過ぎていれば負値） |
| 17 | `used_percentage=42`, しきい値 80 | `HEADROOM_PCT=38`（= 80 − 42） |
| 18 | `used_percentage=85`, しきい値 80（DEFER） | `HEADROOM_PCT=0`（負は 0） |
| 19 | UNKNOWN の各系（state 無し／古い／null） | `HEADROOM_PCT=`（空） |
| 20 | `used_percentage=14.000000000000002` | `FIVE_HOUR_PCT=14`（アーティファクト除去・判定は生値のまま） |
| 21 | `used_percentage=79.96`, しきい値 80 | `VERDICT=OK`・`FIVE_HOUR_PCT=79.96`・`HEADROOM_PCT=0.04`（`%g` 整形は実質の精度を保ち、差分計測を壊さない） |
| 22 | `used_percentage` が数値でない（`"abc"` 等） | `UNKNOWN` / exit 20（0 に強制変換して `OK`・満額 `HEADROOM_PCT` を返さない） |
| 23 | 小数点がカンマのロケール（例 `LC_ALL=de_DE.UTF-8`）で実行 | 数値出力の小数点はピリオドのまま（`LC_ALL=C` 固定・FR-03） |
| 24 | `written_at` が数値の各系（OK / DEFER / 古い / `used_percentage` が null・非数値） | `STATE_AGE_SECONDS` が `now − written_at` に一致（「古い」系では REASON の経過秒と同値） |
| 25 | state ファイル無し／`written_at` が欠ける・数値でない | `STATE_AGE_SECONDS=`（空） |

---

## 10. 既知の限界・やらないこと

- **statusline コマンドへの依存**：tee は statusline コマンドの実行に相乗りする。**未設定なら恒久 `UNKNOWN`**。導入はまず付録 A-1 のコマンド設定から始まる（§2.4・§11）。
- **対話セッション限定**：判定・監視を実行するのはエージェントで、セッションが動いている間だけ働く（`TaskStop`/`resumeFromRunId` はセッションに紐づく）。**headless/非対話起動では statusline が動かず、控えが古くなる** ため、長時間ワークフローは対話セッションから起動する。セッションを閉じれば監視者はいなくなり、mid-run watchdog（FR-08）も止まる。
- **Pro/Max 限定**：`rate_limits` は Claude.ai Pro/Max 利用者にだけ渡される。API キー課金では恒久 `UNKNOWN`（fail-open で素通り）となり、本ゲートは使えない。
- **mid-run の停止は区切りを保証しない**：外部からの監視で止めるため、中断位置は決まらない。中断したエージェントは再開でやり直すので、読み取りだけのワークフローは無害だが、書き込みなどを伴うものは冪等キーが前提。
- **検出のみで強制しない**：強制（フックで止める）は別途の判断（付録 C）。本書は「エージェントが自分で見る」前提。
- **対象は scope-(i) のみ**：dispatcher 管理のタスクは対象外。
- **UI イベントが無いと控えが古くなる**：statusline はイベント駆動（§8）のため、放置中だけでなく、**メインループがバックグラウンド完了待ちで沈黙する対話セッションでも tee は発火せず、控えが古くなる**。watchdog が監視すべき長い走行ほどこの空白が確実に開く（実測：約 29 分の走行中に監視 4 tick 連続で UNKNOWN 化、その裏でも消費は進行していた）。`statusLine.refreshInterval`（§8）で解消できる。未設定の環境では新しさの判定（FR-04）が UNKNOWN で吸収し、FR-08 の UNKNOWN 分岐で保守的に扱う。
- **正式な値だが版に依存**：値はサーバが返すもので推定ではないが、標準入力の形式は Claude Code の版に依存する（§8）。

---

## 11. 導入の手順（新規導入）

statusline 未設定の環境を起点に、最小の手数で導入する。すでに statusline がある場合は、手順 2〜3 を「tee ブロックの追記」に読み替える。

1. **前提の確認**（§2.4・§8）：対象が **Pro/Max か**、**対話 TUI で使うか** を確認。どちらも満たさなければ恒久 `UNKNOWN`（fail-open）になることを導入担当者へ周知。
2. **statusline コマンドの配置**：付録 A-1 の `statusline-command.sh` を `~/.claude/` に置き、実行権限を付ける（`chmod +x`）。
3. **settings.json への配線**：`statusLine.command` をそのスクリプトへ向ける（付録 A-1 末尾の設定例）。既存 statusline があるなら、そのコマンドへ tee ブロックだけ追記し、配線は変えない。
4. **ゲートの配置**：付録 A-2 の `rate-guard.sh` を置き、実行権限を付ける。
5. **動作ルールの明記**：FR-06（pre-flight・予算比較）・FR-08（mid-run watchdog）・FR-09（バッチ分割）・FR-10（クラッシュ復旧）を、そのリポジトリのエージェントの記憶 / 運用ドキュメントに書く。
6. **受け入れ確認**：§9 のテスト、特に #10（新規導入スモーク）を対話セッションで実行し、state が作られ → ゲートが正式な値を返すことを確認。
7. （任意）取りこぼしを完全に潰すなら付録 C（強制フック）を検討。

---

## 12. 運用上の約束（事故の予防）

ゲートの仕組み自体が健全でも、運用を誤れば事故になる。導入先で守るルール。

- **大規模ワークはバッチ分割を第一防衛線に**：閾値ゲート単体は高並列フリートの防御にならない（`OK` 直後の焼き切りが実測されている）。FR-09 の標準形（計測バッチ → 予算比較 → 境界ゲート → 冪等チェックポイント）で組み、watchdog は保険に回す。
- **watchdog の下では読み取りだけのワークフローを原則に**：mid-run の停止は区切りを保証せず、中断したエージェントは再開でやり直す。**書き込み（ファイル/外部投稿/DB 更新/アップロード）を伴うワークフローは冪等キー（`request_hash`/`batch_id` など）が必須**。冪等にできないワークフローは watchdog に載せない。
- **切り離したサブプロセスには自衛させる**：ワークフローが `TaskStop` で死なない外部プロセスを起動するなら、**そのプロセス自身に最大実行時間／自己ゲートを持たせる**。セッションを閉じると監視者（エージェント）はいなくなるため、監視者がいなくても自分で止まれること。
- **監視間隔は式で決め、リセット境界はバックオフ**：各起き上がりはトークンを消費するので間隔は分単位にしつつ、上限は FR-08 の式（`(100 − しきい値) ÷ 最大バーンレート`）を超えないこと。リセット推定のずれによる thrash は再確認のガード＋バックオフで抑える（NFR-08）。
- **重い単発ワークフローは余白を取る**：pre-flight は起動時点の使用率しか見ず、ワークフローの消費量は知らない。1つの枠を食いうるワークフローは **予算比較（FR-06）とバッチ分割（FR-09）で収まる大きさに切る** のが第一。分割できない単発は、しきい値を下げて余白を確保（例 80→60）するか、**FR-08 watchdog 前提**に切り替える。
- **既成・名前付き workflow は fan-out を確かめてから起動する**：自作の消費感覚を桁違いの fan-out に外挿しない（使用 9% で起動した検証型レビュー workflow が 27 エージェントで 100% に到達した実測がある・FR-06）。
- **計測は自セッション単独で**：単価・バーンレートの計測（前後差分）は、他セッションが消費していない状態で行う。state は「最後に statusline を実行したセッションの最終 API 応答値」で上書きされ、複数セッション併用では読み値が非単調にぶれる（§8・FR-06）。
- **スクリプト・中間成果物は永続ディレクトリに**：`/tmp` はクラッシュ・再起動で失われる（FR-10）。再開情報（resume.json）はバッチ境界ごとに更新する。
- **しきい値は環境変数で渡す**：恒久的な変更を `settings.json` などに固定すると、ふだんの使用率より低いしきい値で **リセット後にまたしきい値を超え→恒久 DEFER で詰む**。しきい値の変更は、ゲート呼び出し時の環境変数（その場限り）にとどめる。

---

## 付録 A：参照実装

### A-1. statusline コマンド（`~/.claude/statusline-command.sh`・tee 内蔵）

statusline 未設定の環境へ **そのまま新規設定できる、完結したスクリプト**。標準入力から rate_limit を取り出して控えを書き（tee）、任意で1行の見えるバーを描画する。見えるバーが不要なら、末尾の「見えるバー」ブロックを `:`（何もしない）に置き換えてよい（tee の副作用はそのまま働く）。

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

# --- 見えるバー（任意・装飾）。不要なら次の3行を `:` に置換してよい ---
model=$(echo "$input" | jq -r '.model.display_name // empty')
printf '%s' "${model:+$model}"
[ -n "$five_pct" ] && printf ' · 5h %s%%' "$five_pct"

exit 0   # tee 失敗・見えるバーの短絡で非ゼロ終了 → statusline が空になるのを避ける
```

`settings.json` への配線（未設定の環境の場合）：

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-command.sh",
    "refreshInterval": 60
  }
}
```

> 既存の statusline がある環境では、配線は変えず、その既存コマンドの中に上記「tee」ブロックだけを追記する。抽出（`five_pct` など）が未定義なら、抽出行もあわせて追記する。
>
> `refreshInterval`（秒）は任意だが、**watchdog 運用（FR-08・付録 B）では設定を推奨**：メインループがバックグラウンド完了待ちで沈黙していても、タイマーで tee が発火し、控えが stale 化しない（§8）。

### A-2. `rate-guard.sh`（判定スクリプト全文）

```bash
#!/usr/bin/env bash
# 5時間セッション枠に「1本回す余力」があるかを判定する純コード（LLM不使用）。
# 出力: KEY=VALUE 行 / 終了コード 0=OK 10=DEFER 20=UNKNOWN(fail-open)
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
```

---

## 付録 B：mid-run watchdog の運用手順（FR-08 の詳細）

1つの枠（5時間）を超える単発ワークフローをやり切るための手順。

**実体**：新しいプログラムではなく、エージェントが既存の部品（`rate-guard.sh` ＋ Workflow ツール標準の `run_in_background` / `TaskStop` / `resumeFromRunId`）の上で回す監視ループ。`TaskStop`/`resumeFromRunId` はセッションに紐づくため、**監視するのはエージェント自身**（素の cron では不可）。セッションが消えた場合の復旧は FR-10（journal からの再構築）による。

**ループ（手順の概略）**：

```
launch:  runId = Workflow(scriptPath, run_in_background=true)
         再開情報を resume.json へ永続化（FR-10）

監視ループ（式で決めた間隔で起き・各回 rate-guard.sh を実行）:
  ※ 間隔の上限 = (100 − しきい値) ÷ 最大バーンレート（FR-08）
  VERDICT=OK    かつ 実行中  → バーンレートを計算（written_at が異なる 2 点の FIVE_HOUR_PCT 差分。
                               STATE_AGE_SECONDS で同じ write の再読を除外）
                               到達予測 < tick間隔 なら DEFER と同じ手順（先読み停止）
                               そうでなければ次の監視を再予約
  VERDICT=DEFER かつ 実行中  → TaskStop(runId)              # journal は保たれる
                               RESETS_AT を記録し再開を予約（FR-07 と同じ手順）
  VERDICT=UNKNOWN(古い) かつ 実行中
                             → OK 扱いにしない。最後の既知値 ＋ 経過時間 × バーンレート で保守的に推定し、
                               しきい値以上なら DEFER と同じ手順で停止（実測 2 点がまだ無ければ
                               pre-flight の見積単価から導いたバーンレートで代用・FR-08）
  完了の通知を受けた         → ループ終了（成果物を回収・resume.json を完了に更新）

resume（予約発火時）:
  rate-guard.sh で再確認 → OK を確認（thrash 防止）
  Workflow(scriptPath, resumeFromRunId=runId, run_in_background=true) で続行
  監視ループへ戻す（複数の枠をまたぐなら DEFER のたびに繰り返す）
```

**設計上の要点**：

- **80% で能動的に止める価値**：100% の枠切れを待つと、Workflow の `agent()` がリトライ後に `null` に握りつぶされ、**縮退した結果が黙って返る**（黙った打ち切り）。しきい値での `TaskStop` はきれいに中断し journal を残すので、これを避けられる。
- **間隔は式で決める**：固定の「◯分」は高並列フリートに届かないことがある（20 分間隔では最初の tick 前に全損した実測がある）。上限は `(100 − しきい値) ÷ 最大バーンレート`。state の鮮度（最後に statusline が動いた時点）のぶん実効の遅れが加わることも見込む（FR-08）。
- **先読み DEFER**：前回 tick の `FIVE_HOUR_PCT` を控え、バーンレートから「次の tick では手遅れ」と予測できるなら、しきい値未達でも停止する（FR-08）。
- **stale 空白と監視の形態**：エージェント起床型（`ScheduleWakeup` 等）の監視は、起床時のアシスタントメッセージ自体が statusline を発火させ、控えを更新する副作用を持つ（§8）。これをシェルの常駐ループなどに置き換えると、トークン消費は減るが**この暗黙の更新経路が切れて stale を自ら招く**（実測：走行監視中に 4 tick 連続 UNKNOWN）。シェルループ型を使う場合は `statusLine.refreshInterval`（§8）の設定か、UNKNOWN 分岐（FR-08）の実装を必須とする。
- **停止位置は決まらない**：外部からの監視なので区切り（phase 境界）では止まらない。中断時に走っていたエージェントは再開でやり直す。**読み取りだけのワークフロー（コードレビューなど）は無害**。書き込み（ファイル/外部投稿/DB 更新/アップロード）を伴うものは、冪等キー（request_hash/batch_id など＝疎結合の取り決め#4）で二重実行を吸収できる範囲に限る。
- **再開の前提**：スクリプトは決定的であること（`Date.now()`/乱数に依存しない）。同じ script ＋同じ args なら、完了済みのエージェントは 100% キャッシュから戻る。`resumeFromRunId` は **同一セッション限定**。クラッシュ後は FR-10 の経路（journal を読んで継続スクリプトを書き起こす）へ切り替える。
- **切り離したサブプロセス**：ワークフローが外部プロセスを起動する場合、それは `TaskStop` で死なない。再開時は再起動でなく、**既存の目印/ロック（PID の生存）を監視** して続行する（切り離し＋監視 方式）。
- **監視のコスト**：各監視は「state の読み取り＋数値の比較」だけ。キャッシュ維持（270 秒以内）を意識しつつ、上限の近くで監視自体が枠を食わないこと（NFR-08）。

## 付録 C：強制（PreToolUse フック）への格上げ（任意）

取りこぼし（エージェントがゲート実行を忘れる／思い出せない）を完全に潰したい場合のみ。

- `Workflow` ツールへの PreToolUse フックで `rate-guard.sh` を実行し、`DEFER` ならツール呼び出しを止め＋理由を返す。
- **代償**：すべての Workflow 呼び出しに一律で効く（軽い呼び出しも対象）。スクリプトのバグで全面的に止めうる、危険な仕組み。例外運用には、回避の仕組み（環境変数のフラグ・特定 label の除外）が別途必要。
- **限界**：フックで硬くできるのは「起動を止める」ところまで。先送りの予約・ユーザー通知という後続は、結局エージェントの動作（FR-06/07）に残る。
- 採用時は、設定ファイル（`settings.json` の `hooks`）の変更＝全セッションの挙動の変更となるため、導入は明示の承認のうえで。
