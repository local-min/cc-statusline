# Claude Code Statusline

Claude Code の画面下部にリッチなステータス情報を常時表示するカスタムステータスラインです。

## 表示内容

```
📁 ~/git/github.com/org/my-repo              ← カレントディレクトリ
🐙 my-repo │ 🌿 feat/login +3 ~2             ← リポジトリ名 │ ブランチ │ 差分
🧠 ████████░░░░░░░░░░░░ 40%  │ 💪 Opus 4.6   ← コンテキスト使用率 │ モデル
💰 5h 12% (🔄 16:00) │ 7d 36% (🔄 4/12 01:00)  ← レートリミット (Max/Pro)
PR #324 ✓                                      ← 関連PR番号（レビュー状態バッジ付き）
```

### 各行の詳細

| 行 | 内容 | 備考 |
|---|---|---|
| 1 | カレントディレクトリ | `$HOME` は `~` に短縮 |
| 2 | リポジトリ名 / ブランチ名 / 差分 | `+N` = staged, `~N` = unstaged + untracked。git リポジトリ外では非表示。`CCSL_SHOW_LINES=1` でセッションの追加/削除行数（`📊 +N -N`）も表示 |
| 3 | コンテキスト使用率 + モデル名 | プログレスバー付き。使用率がしきい値（デフォルト 70%）に達すると `⚠ 70%+` を赤字表示（`CCSL_CTX_WARN_PCT` で変更・無効化可）。使用率は Claude Code が実際のコンテキストウィンドウ（200k / 1M）に対して計算した値なので、モデルが変わっても同じ意味になります。使用率がまだ分からないときは `0%` ではなく、compaction 直後なら `↺ compacted`、セッション開始直後などは `--%` と表示します（詳しくは[コンテキスト使用率が分からないとき](#コンテキスト使用率が分からないとき)） |
| 4 | レートリミット（5時間 / 7日） | Claude Max / Pro プランのみ表示。リセット時刻付き。5時間枠と7日枠は個別に表示し、片方がリセットされて JSON から消えても、もう片方は残ります |
| 5 | PR 番号 | Claude Code が渡す `pr.number` を優先利用（**通信なし**）。無い場合のみ `gh` CLI で取得し 5 分間キャッシュ（キャッシュは `${TMPDIR:-/tmp}/claude-statusline-<uid>` に本人専用〔mode 700〕で置き、他人が作ったディレクトリやシンボリックリンクは使わない。数字以外の値は表示しない）。レビュー状態を `✓`（approved）/ `✗`（changes_requested）/ `…`（pending）/ `draft` のバッジで表示。PR がなければ非表示 |

> **git の参照ディレクトリ**: 2 行目・5 行目の git / PR 情報は、JSON で渡される `cwd`（Claude Code が表示しているディレクトリ）を基準に取得します（`git -C "$cwd"`）。スクリプト自身のカレントディレクトリには依存しません。

### 色分けルール

コンテキスト使用率・レートリミットの値に応じて自動で色が変わります。

- **緑**: 50% 未満
- **黄**: 50% 以上 80% 未満
- **赤**: 80% 以上

## 前提条件

> **対応 OS: macOS / Linux**
> macOS（BSD 系コマンド）と Linux（GNU coreutils）の両方に対応しています。`uname` で OS を判定し、`date` / `stat` / `md5`（Linux では `md5sum`）を自動で切り替えます。

以下のツールは [Homebrew](https://brew.sh/) でインストールできます。

| ツール | 用途 | インストール |
|---|---|---|
| **jq** | JSON のパース（**必須**。無い場合は案内メッセージのみ表示） | `brew install jq` |
| **git** | 2 行目（リポジトリ / ブランチ / 差分）の表示に必要。無くても他の行は動作 | macOS 標準。なければ `brew install git` |
| **gh** | PR 番号取得のフォールバックに使用（任意）。Claude Code が `pr.number` を渡す場合は **gh なしでも PR 行は表示** | `brew install gh` → `gh auth login` |

## セットアップ

新規ユーザーが clone から表示確認までを行う手順です。上から順に実行してください。

### 1. 前提ツールをインストール

すでに入っていればスキップして構いません。

```bash
brew install jq                   # 必須
brew install gh && gh auth login  # 任意（PR 番号を表示したい場合のみ）
```

### 2. リポジトリを clone

```bash
git clone https://github.com/local-min/cc-statusline.git
cd cc-statusline
```

### 3. スクリプトを配置

clone したディレクトリ内で、`statusline.sh` を `~/.claude/` にコピーして実行権限を付与します。

```bash
mkdir -p ~/.claude
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

### 4. settings.json に追加

`~/.claude/settings.json` に `statusLine` を設定します。

**ファイルがまだ無い場合**は、以下の内容で新規作成します。

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

**既存の設定がある場合**は、一番外側の `{ ... }` の中に `statusLine` キーだけを追記します（他のキーはそのまま残してください）。

`padding` はステータスラインの上下余白（行数）です。お好みで `0`〜`2` を指定してください。

### 5. 動作確認（任意）

Claude Code を再起動する前に、モック JSON でスクリプト単体の動作を確認できます。

```bash
echo '{"cwd":"/Users/you/project","model":{"display_name":"Opus 4.6"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":1743850800},"seven_day":{"used_percentage":30,"resets_at":1744412400}}}' | ~/.claude/statusline.sh
```

4 行目に `💰 5h 15% (🔄 20:00) │ 7d 30% (🔄 4/12 08:00)` のような表示が出れば成功です（時刻はローカルタイムゾーンに依存）。

### 6. Claude Code を再起動

次回の Claude Code 起動時から自動的にステータスラインが表示されます。

> **Note**: 初回起動時にワークスペース信頼ダイアログが表示される場合があります。承認するとステータスラインが有効になります。

## カスタマイズ

各種の挙動は**環境変数**で変更できます（スクリプト本体を編集する必要はありません）。`settings.json` の `command` にインラインで指定するのが手軽です。

```json
{
  "statusLine": {
    "type": "command",
    "command": "CCSL_BAR_WIDTH=30 CCSL_SHOW_PR=0 ~/.claude/statusline.sh",
    "padding": 1
  }
}
```

| 環境変数 | 用途 | デフォルト |
|---|---|---|
| `CCSL_BAR_WIDTH` | コンテキストバーの幅（文字数）。`1`〜`200` にクランプ。非数値はデフォルトに戻ります | `20` |
| `CCSL_PR_TTL` | PR 番号キャッシュの有効期間（秒）。`gh` フォールバック時のみ有効（`pr.number` 利用時は通信が発生しません） | `300` |
| `CCSL_TIME_FMT_5H` | 5時間リセット時刻の `strftime` 書式 | `%H:%M` |
| `CCSL_TIME_FMT_7D` | 7日リセット時刻の `strftime` 書式 | `%-m/%-d %H:%M` |
| `CCSL_SHOW_DIR` / `_GIT` / `_CONTEXT` / `_RATE` / `_PR` | 各行の表示切替（`1`=表示 / `0`=非表示） | `1` |
| `CCSL_SHOW_LINES` | 2 行目にセッションの追加/削除行数（`📊 +N -N`）を表示 | `0` |
| `CCSL_CTX_WARN_PCT` | コンテキスト警告のしきい値（%）。`context_window.used_percentage` がこの値以上になると `⚠ N%+` を赤字表示。`0` で無効化。非数値はデフォルトに戻ります | `70` |
| `CCSL_CTX_WARN_K` | 絶対値によるコンテキスト警告のしきい値（千トークン単位）。`total_input_tokens` が超過すると `⚠ Nk+` を赤字表示。`0` で無効化。`CCSL_CTX_WARN_PCT` と両方が該当するときは使用率の警告を表示します | `0`（無効） |
| `CCSL_NO_COLOR` | ANSI カラーを無効化（標準の `NO_COLOR` も尊重します） | （未設定） |

例: PR 行を消してバーを 30 文字に広げる → `CCSL_SHOW_PR=0 CCSL_BAR_WIDTH=30`

以前の既定（入力トークン 300k 超で警告）に戻す → `CCSL_CTX_WARN_PCT=0 CCSL_CTX_WARN_K=300`

## 仕組み

- Claude Code は `statusline.sh` を実行し、セッション情報を JSON で stdin に渡します。実行されるのはセッション開始時と、主に次のタイミングです（[公式ドキュメント](https://code.claude.com/docs/en/statusline)）
  - アシスタントの応答が届いたとき
  - `/compact` や自動 compaction（アイドル時の idle compaction を含む）が終わったとき
  - レートリミット枠が `resets_at` に達したとき、プロンプトキャッシュが `expires_at` に達したとき
  - `refreshInterval` を設定している場合はその間隔ごと
- スクリプトの stdout がステータスラインとして画面下部に表示されます
- ANSI エスケープコードによるカラー表示に対応しています
- スクリプトはローカルで実行されるため、API トークンは消費しません

### 実装上の工夫

- **jq 呼び出しは 1 回**：全フィールドをまとめて抽出してから組み立てます（毎メッセージ実行されるため）
- **PR 番号は通信レス優先**：JSON の `pr.number` があれば `gh` を呼ばず、ネットワーク待ちが発生しません
- **ANSI インジェクション対策**：`cwd` / モデル名などの値は制御文字を除去してから表示し、色は固定の ESC シーケンスのみを使います
- **不正な JSON は明示**：パースに失敗した場合は黙って空表示にせず、`(statusline) invalid JSON on stdin` と短く表示します
- **クロスプラットフォーム**：`date` / `stat` / `md5` の差異を `uname` で吸収（macOS / Linux 両対応）。`resets_at` は epoch 秒前提ですが、念のため ISO8601 もベストエフォートで解釈します

### コンテキスト使用率が分からないとき

Claude Code は、最初の API 呼び出しの前と、compaction の直後（次の API 呼び出しまで）に `context_window.current_usage` を `null` で渡します。このとき実際の使用量はまだ分からないため、`0%` とは表示しません。

| 表示 | 状態 | 判定 |
|---|---|---|
| `↺ compacted` | compaction 直後。次の応答で実際の使用率に戻ります | `current_usage` が `null` で、`prompt_cache` がある（＝このセッションで API 応答を受け取り済み） |
| `--%` | セッション開始直後など、使用率が分からない | 上記以外で使用率が得られない |

- しきい値（デフォルト 200K トークン）を超えた会話を約 1 時間放置すると、Claude Code は [idle compaction](https://code.claude.com/docs/en/settings-reference#idlecompaction) で会話を要約します。席を外して戻ったときに `↺ compacted` が出ているのはこのためです。しきい値や ON/OFF は [idle compaction の設定](#idle-compaction-の設定claude-code-側) で変えられます
- 使用率が分からない間は、`CCSL_CTX_WARN_PCT` / `CCSL_CTX_WARN_K` の警告も出しません（compaction 前のトークン数が残っていても誤って警告しないため）
- `used_percentage` だけが欠けていて `current_usage` がある場合は、公式と同じ計算式（`input_tokens + cache_creation_input_tokens + cache_read_input_tokens`）で `context_window_size` に対する割合を求めます

### idle compaction の設定（Claude Code 側）

idle compaction は Claude Code 本体の機能で、このスクリプトの設定ではありません。どの設定でもステータスラインはそのまま動きます。設定は `~/.claude/settings.json` に書きます（[公式ドキュメント](https://code.claude.com/docs/en/settings-reference#idlecompaction)）。

| やりたいこと | 設定 | 備考 |
|---|---|---|
| 発動するコンテキストの大きさを変える | `env` の `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS` | トークン数で指定（デフォルト `200000`）。`100000` 未満は `100000` になります |
| idle compaction だけ止める | `"idleCompaction": false`（または `/config` の **Idle compaction**） | 上限に近づいたときの自動 compaction は残ります |
| 自動 compaction ごと止める | `"autoCompactEnabled": false`（または `/config` の **Auto-compact**） | idle compaction も止まります。手動の `/compact` は使えます |

しきい値は % では指定できないので、使っているモデルのコンテキストウィンドウから計算します。例えば 1M ウィンドウ（Opus 4.7 以降、Sonnet 5 以降、Fable など）で「50% 以上のときだけ」にするなら `500000` です。

```json
{
  "env": {
    "CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS": "500000"
  }
}
```

- 既存の `settings.json` に追記するときは、一番外側の `{ ... }` に `env` キーを足します（すでに `env` があればその中に追加）
- 新しく起動したセッションから確実に反映されます。設定を消した場合も、反映は次の起動からです
- しきい値を上げたり idle compaction を止めたりすると、その分だけ要約されずに残る会話が増えます。1 時間以上放置した後の最初のメッセージでは、プロンプトキャッシュが切れているため、コンテキスト全体をキャッシュなしで処理し直します（応答が遅くなり、レートリミットの消費も増えます）
- 発動するのは、対話セッションで、自動 compaction が有効で、1 時間のプロンプトキャッシュを使っているときです。`idleCompaction` キーは Claude Code v2.1.290 以降、`/config` の行は v2.1.302 以降で使えます

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `jq: command not found` / 表示が崩れる | `brew install jq` で jq をインストール |
| ステータスラインが表示されない | `chmod +x ~/.claude/statusline.sh` を確認。`settings.json` の `statusLine` 設定を確認 |
| 「statusline skipped」と表示される | ワークスペース信頼ダイアログを承認する |
| レートリミットが表示されない | API キーユーザーには表示されません（Max/Pro プランのみ） |
| しばらく放置すると `↺ compacted` になる | idle compaction で会話が要約された直後の表示です。次の応答で実際の使用率に戻ります（[コンテキスト使用率が分からないとき](#コンテキスト使用率が分からないとき)） |
| 放置後に 5h が消えて 7d だけになる | 5時間枠がリセットされ、Claude Code が JSON からその枠を外したためです。次の応答で再び表示されます |
| PR 番号が表示されない | `gh auth login` でログイン済みか確認。対象ブランチに PR がない場合も非表示 |
| リセット時刻がずれて見える | ローカルタイムゾーンで表示されます。`date` の出力（`date '+%H:%M'`）と合っているか確認 |

## ライセンス

[MIT License](LICENSE) の下で公開しています。
