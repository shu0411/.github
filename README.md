# .github

各リポジトリで共通利用する、Issue 駆動開発（Issue → AI エージェントが実装 → PR）の仕組み。

## 全体フロー

1. 人間が Issue テンプレート（Requirement）で簡単な要求を書く
2. ローカルの Claude Code で `/design-issue <番号>` を実行し、Issue を設計済みの仕様書に育てる
3. 人間が内容を確認し、`ready-for-claude` ラベルを付ける（実装開始の承認）
4. GitHub Actions 上の Claude Code が実装し、`Closes #<番号>` 付きの PR を作成する

このリポジトリは 1 と 4、および `ready-for-claude` ラベルの作成コマンドを提供する。
2 の Skill は対象外。

## 構成

| パス | 役割 |
| --- | --- |
| [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/) | 共通の Issue テンプレート。自前の `ISSUE_TEMPLATE` を持たないリポジトリに自動で適用される |
| [`actions/implement-issue/`](actions/implement-issue/action.yml) | Claude Code を呼び出す Composite Action。Actions 上での指示（進め方・禁止事項・PR 本文フォーマット）はここが正 |
| [`workflow-templates/`](workflow-templates/) | 各リポジトリに置く呼び出し側 workflow の雛形 |
| [`.github/workflows/`](.github/workflows/) | このリポジトリ自身の CI（配布物の構文検証） |
| [`scripts/create-label.sh`](scripts/create-label.sh) | 指定したリポジトリに実装開始用ラベルを作成するコマンド |

実行環境（checkout・依存関係の準備）はリポジトリごとに異なるため、共通化するのは
Claude を呼び出す step のみ。環境構築は各リポジトリの workflow に書く。
Actions 上での指示は共通 Action に集約しているので、各リポジトリの `CLAUDE.md` に
PR 本文フォーマットなどを書く必要はない
（アーキテクチャや lint / test コマンドなど、リポジトリ固有の開発ルールは
従来どおり `AGENTS.md` / `CLAUDE.md` に書く）。

Composite Action は実行時に [`shu0411/dotfiles`](https://github.com/shu0411/dotfiles)
をcheckoutし、`~/.claude/CLAUDE.md` を配置してグローバルなClaude Code設定
（`CLAUDE.md` 本体と、そこから `@` importされる `AGENTS.md`）を読み込ませる
（dotfiles は public である必要がある）。

## 導入手順

1. リポジトリの Secrets に `CLAUDE_CODE_OAUTH_TOKEN` を登録する
   （ローカルで `claude setup-token` を実行して発行。Claude のサブスクリプション契約が前提）
2. [`workflow-templates/claude-agent-implement.yml`](workflow-templates/claude-agent-implement.yml) を
   `.github/workflows/` にコピーする
   （Actions の「New workflow」に表示される場合はそこから選んでもよい）
3. コピーした workflow の TODO 部分に、そのリポジトリで lint / test を動かすための環境準備を書き、
   必要に応じて `additional-allowed-tools` / `extra-prompt` を設定する
4. 自前の `.github/ISSUE_TEMPLATE/` があれば削除する（残っていると共通テンプレートは使われない）
5. 下記のコマンドで実装開始用ラベルを作成する

### 実装開始用ラベルの作成

GitHub CLI（`gh`）と Bash が必要。`gh auth login` で、対象リポジトリのラベルを
作成できる権限を持つアカウントにログインし、このリポジトリのルートで実行する。

```bash
bash scripts/create-label.sh OWNER/REPO
```

`OWNER/REPO` を対象リポジトリ（例: `shu0411/my-project`）に置き換える。
`ready-for-claude` を作成し、すでに存在する場合は色と説明をスクリプトの定義に更新する。

### Composite Action の入力

入力の一覧と既定値は [`action.yml`](actions/implement-issue/action.yml) を参照。

## 開発

配布物を変更したら、push 前にローカルで CI と同じ検証を行う。

```bash
uvx --from actionlint-py actionlint .github/workflows/*.yml workflow-templates/*.yml
uvx check-jsonschema --builtin-schema vendor.github-actions actions/*/action.yml
bash -n scripts/*.sh
```

呼び出し側は `@main` を参照しているため、`main` への変更は即座に全リポジトリへ反映される。

## リポジトリ管理

- 本リポジトリの更新は、PRの作成を必須とする
