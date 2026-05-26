# Claude Code Statusline

Claude Code の画面下部にリッチなステータス情報を常時表示するカスタムステータスラインです。

## 表示内容

```
📁 ~/git/github.com/org/my-repo              ← カレントディレクトリ
🐙 my-repo │ 🌿 feat/login +3 ~2             ← リポジトリ名 │ ブランチ │ 差分
🧠 ████████░░░░░░░░░░░░ 40%  │ 💪 Opus 4.6   ← コンテキスト使用率 │ モデル
💰 5h 12% (🔄 4pm) │ 7d 36% (🔄 4/12 1am)    ← レートリミット (Max/Pro)
PR #324                                        ← 関連PR番号
```

### 各行の詳細

| 行 | 内容 | 備考 |
|---|---|---|
| 1 | カレントディレクトリ | `$HOME` は `~` に短縮 |
| 2 | リポジトリ名 / ブランチ名 / 差分 | `+N` = staged, `~N` = unstaged + untracked。git リポジトリ外では非表示 |
| 3 | コンテキスト使用率 + モデル名 | プログレスバー付き。200k トークン超過時に `⚠ 200k+` を赤字表示 |
| 4 | レートリミット（5時間 / 7日） | Claude Max / Pro プランのみ表示。リセット時刻付き |
| 5 | PR 番号 | `gh` CLI で取得。5分間キャッシュ。PR がなければ非表示 |

### 色分けルール

コンテキスト使用率・レートリミットの値に応じて自動で色が変わります。

- **緑**: 50% 未満
- **黄**: 50% 以上 80% 未満
- **赤**: 80% 以上

## 前提条件

- **jq**: JSON パーサー（`brew install jq`）
- **gh**: GitHub CLI（`brew install gh`）— PR 番号の表示に必要。なくても動作する
- **git**: ブランチ・差分情報の表示に必要

## セットアップ

### 1. スクリプトを配置

`statusline.sh` を `~/.claude/` にコピーして実行権限を付与します。

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

### 2. settings.json に追加

`~/.claude/settings.json` に以下を追加します（既存の設定に追記）。

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

`padding` はステータスラインの上下余白（行数）です。お好みで `0`〜`2` を指定してください。

### 3. Claude Code を再起動

次回の Claude Code 起動時から自動的にステータスラインが表示されます。

> **Note**: 初回起動時にワークスペース信頼ダイアログが表示される場合があります。承認するとステータスラインが有効になります。

## カスタマイズ

### 表示行を減らしたい

不要な行のブロック（`# ─── Line N: ... ───` から次のブロックまで）をコメントアウトまたは削除してください。

### プログレスバーの幅を変えたい

Line 3 の `W=20` の数値を変更します（文字数）。

### PR 番号のキャッシュ時間を変えたい

Line 5 の `300`（秒）を変更します。`gh pr view` は通信が発生するため、短くしすぎるとレスポンスに影響します。

## 仕組み

- Claude Code はメッセージ応答のたびに `statusline.sh` を実行し、セッション情報を JSON で stdin に渡します
- スクリプトの stdout がステータスラインとして画面下部に表示されます
- ANSI エスケープコードによるカラー表示に対応しています
- スクリプトはローカルで実行されるため、API トークンは消費しません

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| ステータスラインが表示されない | `chmod +x ~/.claude/statusline.sh` を確認。`settings.json` の `statusLine` 設定を確認 |
| 「statusline skipped」と表示される | ワークスペース信頼ダイアログを承認する |
| レートリミットが表示されない | API キーユーザーには表示されません（Max/Pro プランのみ） |
| PR 番号が表示されない | `gh auth login` でログイン済みか確認。対象ブランチに PR がない場合も非表示 |
| 時刻が `午前/午後` で表示される | スクリプト内で `LC_ALL=C` を設定済みのため通常は発生しません。発生する場合はシェルのロケールを確認 |

## 動作テスト

モック JSON を使ってスクリプト単体でテストできます。

```bash
echo '{"cwd":"/Users/you/project","model":{"display_name":"Opus 4.6"},"context_window":{"used_percentage":42},"exceeds_200k_tokens":false,"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":1743850800},"seven_day":{"used_percentage":30,"resets_at":1744412400}}}' | ~/.claude/statusline.sh
```

## ライセンス

自由に改変・再配布してください。
