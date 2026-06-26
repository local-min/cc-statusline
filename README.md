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
| 3 | コンテキスト使用率 + モデル名 | プログレスバー付き。200k トークン超過時に `⚠ 200k+` を赤字表示 |
| 4 | レートリミット（5時間 / 7日） | Claude Max / Pro プランのみ表示。リセット時刻付き |
| 5 | PR 番号 | Claude Code が渡す `pr.number` を優先利用（**通信なし**）。無い場合のみ `gh` CLI で取得し 5 分間キャッシュ。レビュー状態を `✓`（approved）/ `✗`（changes_requested）/ `…`（pending）/ `draft` のバッジで表示。PR がなければ非表示 |

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
echo '{"cwd":"/Users/you/project","model":{"display_name":"Opus 4.6"},"context_window":{"used_percentage":42},"exceeds_200k_tokens":false,"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":1743850800},"seven_day":{"used_percentage":30,"resets_at":1744412400}}}' | ~/.claude/statusline.sh
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
| `CCSL_NO_COLOR` | ANSI カラーを無効化（標準の `NO_COLOR` も尊重します） | （未設定） |

例: PR 行を消してバーを 30 文字に広げる → `CCSL_SHOW_PR=0 CCSL_BAR_WIDTH=30`

## 仕組み

- Claude Code はメッセージ応答のたびに `statusline.sh` を実行し、セッション情報を JSON で stdin に渡します
- スクリプトの stdout がステータスラインとして画面下部に表示されます
- ANSI エスケープコードによるカラー表示に対応しています
- スクリプトはローカルで実行されるため、API トークンは消費しません

### 実装上の工夫

- **jq 呼び出しは 1 回**：全フィールドをまとめて抽出してから組み立てます（毎メッセージ実行されるため）
- **PR 番号は通信レス優先**：JSON の `pr.number` があれば `gh` を呼ばず、ネットワーク待ちが発生しません
- **ANSI インジェクション対策**：`cwd` / モデル名などの値は制御文字を除去してから表示し、色は固定の ESC シーケンスのみを使います
- **不正な JSON は明示**：パースに失敗した場合は黙って空表示にせず、`(statusline) invalid JSON on stdin` と短く表示します
- **クロスプラットフォーム**：`date` / `stat` / `md5` の差異を `uname` で吸収（macOS / Linux 両対応）。`resets_at` は epoch 秒前提ですが、念のため ISO8601 もベストエフォートで解釈します

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `jq: command not found` / 表示が崩れる | `brew install jq` で jq をインストール |
| ステータスラインが表示されない | `chmod +x ~/.claude/statusline.sh` を確認。`settings.json` の `statusLine` 設定を確認 |
| 「statusline skipped」と表示される | ワークスペース信頼ダイアログを承認する |
| レートリミットが表示されない | API キーユーザーには表示されません（Max/Pro プランのみ） |
| PR 番号が表示されない | `gh auth login` でログイン済みか確認。対象ブランチに PR がない場合も非表示 |
| リセット時刻がずれて見える | ローカルタイムゾーンで表示されます。`date` の出力（`date '+%H:%M'`）と合っているか確認 |

## ライセンス

[MIT License](LICENSE) の下で公開しています。
