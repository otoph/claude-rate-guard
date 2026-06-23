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
- エージェントが **長時間ワークフローを起動する直前に判定ツールを呼び、DEFER なら次の枠へ先送りする** という動作のルールを定める（pre-flight・FR-06）。
- **1つの枠（5時間）を超える単発のワークフロー** については、走行中も判定ツールで監視し、しきい値に達したら **区切りで止め、リセット後に `resumeFromRunId` で自動再開する** という mid-run watchdog の動作ルールを定める（FR-08）。

### 2.3 対象範囲の線引き（**必読**）

|                     機能                      | 範囲内 / 範囲外 |                        理由                         |
| --------------------------------------------- | --------------- | --------------------------------------------------- |
| statusline コマンドの新規設定／tee の追記     | 内              | 正式な値を得る唯一の経路。受け身で無料。未設定の環境では新規作成が導入の起点 |
| statusline からの rate_limit の控え出力（tee）| 内              | 正式な値を得る唯一の経路。受け身で無料              |
| 5時間枠のしきい値判定（ゲート・コードのみ）   | 内              | 計算はコードで行う（LLM 不使用）                    |
| pre-flight で先送りする動作ルール（エージェント側）| 内          | 本ツールの主目的                                    |
| DEFER のときに次の枠へ起動を予約する          | 内              | リセット時刻が控えにあるので、決まった手順で予約できる |
| **mid-run watchdog**（走行中に監視→しきい値到達で止め→リセット後に自動再開） | **内** | 1つの枠を超える単発タスクを最後までやり切るのに必須。pre-flight では救えない（FR-08・付録 B） |
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
- **出力は機械が読める `KEY=VALUE` 行**（標準出力）：`VERDICT` / `FIVE_HOUR_PCT` / `RESETS_AT` / `RESETS_AT_HUMAN` / `SECONDS_TO_RESET` / `REASON`。`SECONDS_TO_RESET` は実行時にゲートが算出する `RESETS_AT − now`（リセット時刻が不明なら空、すでに過ぎていれば負値）。エージェントは自分の時計が無くても、この値で再開を予約できる。
- 小数の比較は `awk` などで行う（bash の整数比較に丸めない）。
- **LLM を一切使わない**（判定と計算はコードで行う）。
- **しきい値の妥当性チェック**：`RATE_GUARD_THRESHOLD` が妥当な範囲 `[10,95]` を外れたら **標準エラーに警告** する（設定ミスの検知）。判定は続け、**標準出力の KEY=VALUE は汚さない**。上げすぎ＝無防備、下げすぎ＝恒久 DEFER で詰む、の両方に早く気づけるようにする。

### FR-04 新しさ・欠落＝安全側（原因を区別して見せる）

- state ファイルが **無い / `written_at` が欠ける・数値でない / `five_hour.used_percentage` が `null` / `written_at` が現在から `STALE_SECONDS`（既定 900 秒）より古い** のいずれかなら `UNKNOWN`（exit 20）を返す。
- UNKNOWN は **止めない**（fail-open）。理由は、初回の未生成・放置後に古くなった・非 Pro/Max・headless での未発火などで、すべてのワークフローを誤って止めるのを避けるため。枠切れ自体はハーネスの rate-limit エラーが最後の歯止めになる。
- **黙らせず、原因を `REASON` で区別する**（同じ UNKNOWN でも対処が違うため）：
  - state ファイル無し → 「`statusLine.command` 未設定 or tee 未実行」
  - `written_at` が欠ける・数値でない → 「state の破損／tee の故障の疑い（`rate-guard.tee.log` を参照）」。計算の前に整数かを確認し、数値でなくてもクラッシュせず UNKNOWN を返す
  - `used_percentage` が `null` → 「**rate_limits が無い＝非 Pro/Max または初回応答前**。ここではゲートは効かない」（構造的・恒久の可能性）
  - 古い → 「古い。**対話中なら tee の故障の疑い**（`rate-guard.tee.log` を参照）」（一時 or 故障）

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

### FR-07 DEFER のときの予約

- 起動の予約時刻は `RESETS_AT`（＋少しの余白）。
- リセットまで **1時間以内** なら短時間スリープ系（例：`ScheduleWakeup`、最大 3600 秒）。**それ以上** なら一回限りの cron（例：`CronCreate`）かスリープの連鎖。
- **再開時の再確認**：予約が発火したら、起動の直前にもう一度ゲートを実行し、`OK` を確認してから起動する（リセット推定のずれによる、すぐの再枠切れ＝thrash を防ぐ）。
- **`SECONDS_TO_RESET` を使う。現在時刻は推奨であって必須ではない**：ゲートが `SECONDS_TO_RESET`（実行時に `RESETS_AT − now` で算出した待ち時間）を出力するので、エージェントは自分の時計が無くても、この値で再開を予約でき、「1時間以内か超か」の分岐（`< 3600` か否か）も判断できる。値は時間とともに古くなるため、ゲート実行後すみやかに予約すること。現在時刻を毎ターン渡す手段（例：`UserPromptSubmit` フック）は、自分の言葉で実時刻を伝える場合や妥当性確認には引き続き推奨だが、予約自体には不要であり、`now` 捏造のリスクも消える（§2.4・§8）。

### FR-08 mid-run watchdog（1つの枠を超える単発ワークフローをやり切る）

pre-flight（FR-06）は「残りが少ないときに *始めない*」だけで、**満タンから始まって1つの枠（5時間）を食い切る単発タスクは救えない**。これを補う、走行中の監視である。

- **適用条件**：pre-flight を `OK` で通ったが、消費が1つの枠を超えうる単発ワークフロー（読み取りだけを優先）。
- **起動**：`Workflow` を `run_in_background` で起動し、`runId` を保持する。
- **監視（ポーリング）**：エージェントが粗い間隔で起き、`rate-guard.sh` を実行する。
  - `OK` かつ実行中 → 次の監視を再予約。
  - `DEFER`（≥しきい値）かつ実行中 → **`TaskStop(runId)`**（journal は保たれる）→ `RESETS_AT` を記録し、再開を予約（FR-07 と同じ手順）。
  - 完了の通知を受けた → ループ終了（成果物を回収）。
- **再開**：予約発火 → `rate-guard.sh` で再確認 → `OK` → `Workflow(scriptPath, resumeFromRunId=runId)` で続行 → 監視ループへ戻す。**複数の枠をまたぐ場合は DEFER のたびに繰り返す**。
- **80% で能動的に止める理由**：100% の枠切れを待つと、Workflow の `agent()` がリトライ後に `null` に握りつぶされ、**縮退した結果が黙って返る**（黙った打ち切り）。しきい値での `TaskStop` はきれいに中断し journal を残すので、これを避けられる。
- **安全性**：止めるのは外部からの監視なので、**区切り（phase 境界）では止まらない**。中断したエージェントは再開でやり直すため、**読み取りだけのワークフローは無害**。書き込みなどを伴うものは、冪等キー（疎結合の取り決め#4）を前提とする。
- 詳しい手順は付録 B。

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
2. **ゲートの標準出力の取り決め**：`KEY=VALUE` 行・キー名 `VERDICT/FIVE_HOUR_PCT/RESETS_AT/RESETS_AT_HUMAN/SECONDS_TO_RESET/REASON`。キーの**追加**は可（既存キー名は変えない）。
3. **終了コード**：`0=OK / 10=DEFER / 20=UNKNOWN`。呼び出し側はこのコードで分岐してよい。
4. データの流れは一方向（§4）。ゲートは state を **読み取り専用** とし、書き換えない。

---

## 8. 導入時の前提と差分（**導入前に必ず確認**）

- **いちばん大事な前提（見えること）**：対象の Claude Code が statusline の標準入力に `rate_limits.five_hour.used_percentage` / `resets_at` を **実際に渡しているか** を最初に確認する（`statusLine.command` に echo のデバッグを入れる／作られた state ファイルを見る）。渡されない環境（§2.4 の切り替わり条件）では、本ツールは恒久 `UNKNOWN`（fail-open）に切り替わり、ゲートは機能しない。
- **statusline が動く条件（公式）**：`statusLine.command` は **新しいアシスタントのメッセージ後・`/compact` 完了時・パーミッションモード変更時・Vim モード切替時** に実行され、更新は 300ms ぶんまとめられる。**未設定なら一切実行されない**。これらは対話 UI の操作であり、headless/print モードでは動かない前提で設計する（§2.4）。
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

---

## 10. 既知の限界・やらないこと

- **statusline コマンドへの依存**：tee は statusline コマンドの実行に相乗りする。**未設定なら恒久 `UNKNOWN`**。導入はまず付録 A-1 のコマンド設定から始まる（§2.4・§11）。
- **対話セッション限定**：判定・監視を実行するのはエージェントで、セッションが動いている間だけ働く（`TaskStop`/`resumeFromRunId` はセッションに紐づく）。**headless/非対話起動では statusline が動かず、控えが古くなる** ため、長時間ワークフローは対話セッションから起動する。セッションを閉じれば監視者はいなくなり、mid-run watchdog（FR-08）も止まる。
- **Pro/Max 限定**：`rate_limits` は Claude.ai Pro/Max 利用者にだけ渡される。API キー課金では恒久 `UNKNOWN`（fail-open で素通り）となり、本ゲートは使えない。
- **mid-run の停止は区切りを保証しない**：外部からの監視で止めるため、中断位置は決まらない。中断したエージェントは再開でやり直すので、読み取りだけのワークフローは無害だが、書き込みなどを伴うものは冪等キーが前提。
- **検出のみで強制しない**：強制（フックで止める）は別途の判断（付録 C）。本書は「エージェントが自分で見る」前提。
- **対象は scope-(i) のみ**：dispatcher 管理のタスクは対象外。
- **放置中に古くなる**：描画が止まると控えが古くなる。ただしゲートの対象は動いているワークフローなので実害は小さく、新しさの判定（FR-04）が UNKNOWN で吸収する。
- **正式な値だが版に依存**：値はサーバが返すもので推定ではないが、標準入力の形式は Claude Code の版に依存する（§8）。

---

## 11. 導入の手順（新規導入）

statusline 未設定の環境を起点に、最小の手数で導入する。すでに statusline がある場合は、手順 2〜3 を「tee ブロックの追記」に読み替える。

1. **前提の確認**（§2.4・§8）：対象が **Pro/Max か**、**対話 TUI で使うか** を確認。どちらも満たさなければ恒久 `UNKNOWN`（fail-open）になることを導入担当者へ周知。
2. **statusline コマンドの配置**：付録 A-1 の `statusline-command.sh` を `~/.claude/` に置き、実行権限を付ける（`chmod +x`）。
3. **settings.json への配線**：`statusLine.command` をそのスクリプトへ向ける（付録 A-1 末尾の設定例）。既存 statusline があるなら、そのコマンドへ tee ブロックだけ追記し、配線は変えない。
4. **ゲートの配置**：付録 A-2 の `rate-guard.sh` を置き、実行権限を付ける。
5. **動作ルールの明記**：FR-06（pre-flight）と FR-08（mid-run watchdog）を、そのリポジトリのエージェントの記憶 / 運用ドキュメントに書く。
6. **受け入れ確認**：§9 のテスト、特に #10（新規導入スモーク）を対話セッションで実行し、state が作られ → ゲートが正式な値を返すことを確認。
7. （任意）取りこぼしを完全に潰すなら付録 C（強制フック）を検討。

---

## 12. 運用上の約束（事故の予防）

ゲートの仕組み自体が健全でも、運用を誤れば事故になる。導入先で守るルール。

- **watchdog の下では読み取りだけのワークフローを原則に**：mid-run の停止は区切りを保証せず、中断したエージェントは再開でやり直す。**書き込み（ファイル/外部投稿/DB 更新/アップロード）を伴うワークフローは冪等キー（`request_hash`/`batch_id` など）が必須**。冪等にできないワークフローは watchdog に載せない。
- **切り離したサブプロセスには自衛させる**：ワークフローが `TaskStop` で死なない外部プロセスを起動するなら、**そのプロセス自身に最大実行時間／自己ゲートを持たせる**。セッションを閉じると監視者（エージェント）はいなくなるため、監視者がいなくても自分で止まれること。
- **監視は粗い間隔で固定し、リセット境界はバックオフ**：各起き上がりはトークンを消費する。上限の近くで監視自体が枠を食い潰さないよう、間隔は分単位にし、リセット推定のずれによる thrash は再確認のガード＋バックオフで抑える（NFR-08）。
- **重い単発ワークフローは余白を取る**：pre-flight は起動時点の使用率しか見ず、ワークフローの消費量は知らない。1つの枠を食いうるワークフローは **しきい値を下げて余白を確保**（例 80→60）するか、**FR-08 watchdog 前提**に切り替える。
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
    "command": "~/.claude/statusline-command.sh"
  }
}
```

> 既存の statusline がある環境では、配線は変えず、その既存コマンドの中に上記「tee」ブロックだけを追記する。抽出（`five_pct` など）が未定義なら、抽出行もあわせて追記する。

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

## 付録 B：mid-run watchdog の運用手順（FR-08 の詳細）

1つの枠（5時間）を超える単発ワークフローをやり切るための手順。

**実体**：新しいプログラムではなく、エージェントが既存の部品（`rate-guard.sh` ＋ Workflow ツール標準の `run_in_background` / `TaskStop` / `resumeFromRunId`）の上で回す監視ループ。`TaskStop`/`resumeFromRunId` はセッションに紐づくため、**監視するのはエージェント自身**（素の cron では不可）。

**ループ（手順の概略）**：

```
launch:  runId = Workflow(scriptPath, run_in_background=true)

監視ループ（粗い間隔で起き・各回 rate-guard.sh を実行）:
  VERDICT=OK    かつ 実行中  → 次の監視を再予約
  VERDICT=DEFER かつ 実行中  → TaskStop(runId)              # journal は保たれる
                               RESETS_AT を記録し再開を予約（FR-07 と同じ手順）
  完了の通知を受けた         → ループ終了（成果物を回収）

resume（予約発火時）:
  rate-guard.sh で再確認 → OK を確認（thrash 防止）
  Workflow(scriptPath, resumeFromRunId=runId, run_in_background=true) で続行
  監視ループへ戻す（複数の枠をまたぐなら DEFER のたびに繰り返す）
```

**設計上の要点**：

- **80% で能動的に止める価値**：100% の枠切れを待つと、Workflow の `agent()` がリトライ後に `null` に握りつぶされ、**縮退した結果が黙って返る**（黙った打ち切り）。しきい値での `TaskStop` はきれいに中断し journal を残すので、これを避けられる。
- **停止位置は決まらない**：外部からの監視なので区切り（phase 境界）では止まらない。中断時に走っていたエージェントは再開でやり直す。**読み取りだけのワークフロー（コードレビューなど）は無害**。書き込み（ファイル/外部投稿/DB 更新/アップロード）を伴うものは、冪等キー（request_hash/batch_id など＝疎結合の取り決め#4）で二重実行を吸収できる範囲に限る。
- **再開の前提**：スクリプトは決定的であること（`Date.now()`/乱数に依存しない）。同じ script ＋同じ args なら、完了済みのエージェントは 100% キャッシュから戻る。
- **切り離したサブプロセス**：ワークフローが外部プロセスを起動する場合、それは `TaskStop` で死なない。再開時は再起動でなく、**既存の目印/ロック（PID の生存）を監視** して続行する（切り離し＋監視 方式）。
- **監視のコスト**：各監視は「state の読み取り＋数値の比較」だけ。間隔は粗く（キャッシュ維持を意識）。上限の近くで監視自体が枠を食わないこと（NFR-08）。

## 付録 C：強制（PreToolUse フック）への格上げ（任意）

取りこぼし（エージェントがゲート実行を忘れる／思い出せない）を完全に潰したい場合のみ。

- `Workflow` ツールへの PreToolUse フックで `rate-guard.sh` を実行し、`DEFER` ならツール呼び出しを止め＋理由を返す。
- **代償**：すべての Workflow 呼び出しに一律で効く（軽い呼び出しも対象）。スクリプトのバグで全面的に止めうる、危険な仕組み。例外運用には、回避の仕組み（環境変数のフラグ・特定 label の除外）が別途必要。
- **限界**：フックで硬くできるのは「起動を止める」ところまで。先送りの予約・ユーザー通知という後続は、結局エージェントの動作（FR-06/07）に残る。
- 採用時は、設定ファイル（`settings.json` の `hooks`）の変更＝全セッションの挙動の変更となるため、導入は明示の承認のうえで。
