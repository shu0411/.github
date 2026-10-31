# .github

各リポジトリで共通利用する、Issue 駆動開発（Issue → AI エージェントが実装 → PR）の仕組み。

## 全体フロー

1. 人間が Issue テンプレート（Requirement）で簡単な要求を書く
2. Issue を設計済みの仕様書に育てる。次のどちらかで行う
   - ローカルの Claude Code で `/design-issue <番号>` を実行し、対話しながら詰める
   - Issue に `design-by-claude` ラベルを付け、GitHub Actions 上の Claude Code に設計させる
     （対話できないため、判断が必要な論点は Issue 本文の「未確定事項」に残る。
     Issue のコメントで `@claude` とメンションして回答・修正依頼をすると設計に反映される）
3. 人間が内容を確認し、`implement-by-claude` ラベルを付ける（実装開始の承認）
4. GitHub Actions 上の Claude Code が実装し、`Closes #<番号>` 付きの PR を作成する
5. PR のコメント・レビューで `@claude` とメンションすると、Claude Code が修正や質問に応答する。
   Issue上・PR上のメンションでは、明示的に依頼すると、同じリポジトリの別Issueへのコメントや
   新しいIssueの作成も行える

このリポジトリは 1・2（Actions 上での設計）・4・5、およびラベルの作成・Secret の登録コマンドを提供する。
2 の Skill 本体は [`shu0411/dotfiles`](https://github.com/shu0411/dotfiles) にあり、対象外。

## 構成

| パス | 役割 |
| --- | --- |
| [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/) | 共通の Issue テンプレート。自前の `ISSUE_TEMPLATE` を持たないリポジトリに自動で適用される |
| [`actions/design-issue/`](actions/design-issue/action.yml) | Issue を設計する Composite Action（フロー 2）。ラベル付与時は dotfiles の `design-issue` Skill に沿って設計し（手順は Skill が正）、Issue 上の `@claude` メンション時は Skill を使わず既存の設計への修正依頼・質問に応答する。Actions 上での共通ルール（禁止事項など）はここが正 |
| [`actions/implement-issue/`](actions/implement-issue/action.yml) | Issue を実装する Composite Action（フロー 4）。Actions 上での指示（進め方・禁止事項・PR 本文フォーマット）はここが正。PR が作成されずに終わった場合は、権限で拒否されたコマンドと Claude の最終メッセージを Issue にコメントしてジョブを失敗させる（[`report-missing-pr.sh`](actions/implement-issue/report-missing-pr.sh)） |
| [`actions/respond-mention/`](actions/respond-mention/action.yml) | PR 上の `@claude` メンションに応答する Composite Action（フロー 5）。Actions 上での共通ルール（禁止事項など）はここが正 |
| [`actions/review-dependency-update/`](actions/review-dependency-update/action.yml) | Dependabot PR の脆弱性・更新前の影響・更新後の互換性を調査し、別ジョブからコメントする |
| [`workflow-templates/`](workflow-templates/) | 各リポジトリに置く呼び出し側 workflow の雛形 |
| [`.github/workflows/`](.github/workflows/) | このリポジトリ自身の CI（配布物の構文検証） |
| [`scripts/create-label.sh`](scripts/create-label.sh) | 指定したリポジトリに設計開始用・実装開始用ラベルを作成するコマンド |
| [`scripts/create-secret.sh`](scripts/create-secret.sh) | Claude Code のトークンを発行し、指定したリポジトリの Secret に登録するコマンド |

実行環境（checkout・依存関係の準備）はリポジトリごとに異なるため、共通化するのは
Claude を呼び出す step のみ。環境構築は各リポジトリの workflow に書く。
Actions 上での指示は共通 Action に集約しているので、各リポジトリの `CLAUDE.md` に
PR 本文フォーマットなどを書く必要はない
（アーキテクチャや lint / test コマンドなど、リポジトリ固有の開発ルールは
従来どおり `AGENTS.md` / `CLAUDE.md` に書く）。

Issue 設計・実装・メンション応答の Composite Action は実行時に [`shu0411/dotfiles`](https://github.com/shu0411/dotfiles)
をcheckoutし、`~/.claude/CLAUDE.md` を配置してグローバルなClaude Code設定
（`CLAUDE.md` 本体と、そこから `@` importされる `AGENTS.md`）を読み込ませる。
`design-issue` はラベル付与での設計時に、これに加えて `skills/design-issue/SKILL.md` をプロンプトに取り込む
（dotfiles は public である必要がある）。

## 導入手順

1. 下記のコマンドでリポジトリの Secrets に `CLAUDE_CODE_OAUTH_TOKEN` を登録する
   （Claude のサブスクリプション契約が前提）
2. [Claude GitHub App](https://github.com/apps/claude) をリポジトリにインストールする
3. 使う workflow の雛形を `.github/workflows/` にコピーする
   （Actions の「New workflow」に表示される場合はそこから選んでもよい）
   - Issue の設計（フロー 2）: [`workflow-templates/claude-agent-design.yml`](workflow-templates/claude-agent-design.yml)
   - Issue の実装（フロー 4）: [`workflow-templates/claude-agent-implement.yml`](workflow-templates/claude-agent-implement.yml)
   - PR でのメンション応答（フロー 5）: [`workflow-templates/claude-agent-mention.yml`](workflow-templates/claude-agent-mention.yml)
4. コピーした workflow の TODO 部分（実装・メンション応答の雛形にある）に、そのリポジトリで lint / test を動かすための環境準備を書き、
   必要に応じて `additional-allowed-tools` / `extra-prompt` を設定する
5. 自前の `.github/ISSUE_TEMPLATE/` があれば削除する（残っていると共通テンプレートは使われない）
6. 下記のコマンドで設計開始用・実装開始用ラベルを作成する

### Secret の登録

GitHub CLI（`gh`）、Claude Code（`claude`）と Bash が必要。
`gh auth login` で、対象リポジトリの Secrets を更新できる権限を持つアカウントにログインし、
このリポジトリのルートで実行する。

```bash
bash scripts/create-secret.sh OWNER/REPO
```

`claude setup-token` で 1 年間有効なトークンを発行する。画面に表示されたトークンを貼り付けると、
そのトークンで Claude に接続できることを確認してから、対象リポジトリの Actions Secret
`CLAUDE_CODE_OAUTH_TOKEN` に登録する（すでに存在する場合は上書きする）。
確認で 1 回 Claude を呼び出すため、少量の利用枠を消費する。

### 設計開始用・実装開始用ラベルの作成

GitHub CLI（`gh`）と Bash が必要。`gh auth login` で、対象リポジトリのラベルを
作成できる権限を持つアカウントにログインし、このリポジトリのルートで実行する。

```bash
bash scripts/create-label.sh OWNER/REPO
```

`OWNER/REPO` を対象リポジトリ（例: `shu0411/my-project`）に置き換える。
`design-by-claude` と `implement-by-claude` を作成し、すでに存在する場合は色と説明をスクリプトの定義に更新する。

### Composite Action の入力

入力の一覧と既定値は各 Action の `action.yml`
（[`design-issue`](actions/design-issue/action.yml) /
[`implement-issue`](actions/implement-issue/action.yml) /
[`respond-mention`](actions/respond-mention/action.yml)）を参照。

メンション応答（PR 上・Issue 上とも）はコメントしたユーザーにリポジトリへの書き込み権限が必要
（権限のないユーザーのメンションでは実行が失敗する）。

## 開発

配布物を変更したら、push 前にローカルで CI と同じ検証を行う。

```bash
uvx --from actionlint-py actionlint .github/workflows/*.yml workflow-templates/*.yml
uvx check-jsonschema --builtin-schema vendor.github-actions actions/*/action.yml
for f in scripts/*.sh actions/*/*.sh; do bash -n "$f"; done
bash scripts/test-actions.sh
bash scripts/test-create-secret.sh
```

呼び出し側は `@main` を参照しているため、`main` への変更は即座に全リポジトリへ反映される。

## リポジトリ管理

- 本リポジトリの更新は、PRの作成を必須とする


## Dependabot の依存更新レビュー

[`workflow-templates/claude-dependency-review.yml`](workflow-templates/claude-dependency-review.yml)
を対象リポジトリの `.github/workflows/` にコピーする。
既存と同じ Actions Secret `CLAUDE_CODE_OAUTH_TOKEN` を使用する。
明示的な `github_token` を使うため、この機能では Claude GitHub App は必須ではない。
ワークフローを既定ブランチに取り込んだ後、Dependabot PR の作成・更新・再オープンで起動する。
先行 CI の作成やワークフロー名の指定は不要。このリポジトリ自身の CI は `Lint` だが、
導入先の CI の有無・名前に依存しない。
このリポジトリ自身も [同じワークフロー](.github/workflows/claude-dependency-review.yml) を使い、
既存の `Lint` と並列に実行する。このリポジトリにも同じ Actions Secret の登録が必要。

調査の最大ターン数は既定で 60。必要に応じて呼び出し側の `with.max-turns` で変更できる。
実行時間は呼び出し側ジョブの `timeout-minutes` にも制限される（テンプレートは 20 分）。

### 起動と CI の扱い

作成元ブランチ名が `dependabot/` で始まり、作者が Dependabot 本人の PR のみ調査する。
security update と通常更新の両方を対象にし、脆弱性情報を取得できない場合は情報不足とする。
`pull_request_target` から、各リポジトリの CI と並列に実行する。
同じ PR の新しいイベントが来た場合は古い調査を中断する。
rebase などで PR が更新されても、Dependabot のコミットメッセージにある更新内容
（`updated-dependencies` のパッケージ・新版・種別）が既存の調査コメントと同じなら、
資料収集前に調査を中断し、コメントも更新しない。コメントの対象 head/base は調査時のまま残る。
コミットが 1 件でない、更新内容を読み取れない、更新内容が変わった場合は再調査する。
同じ更新内容を再調査したい場合は、調査コメントを削除してからワークフローを再実行する。

資料収集時点で、PR の head/base SHA に対応する `pull_request` 起点の GitHub Actions を取得する。
ワークフローごとに最新の実行を使い、成功・失敗・実行中・中断などを区別する。
実行がなければ「未検出（未設定または未開始）」、取得できなければ「未確認」として調査を続ける。
未開始の CI が後から追加される可能性があるため、取得済みの CI だけの状態であることを明記する。
対応する SHA を確認できない実行、調査自身の `pull_request_target` 実行、外部 CI は対象外。
CI 完了は待たず、完了後の再調査やコメントの自動更新もしない。
コメントの CI 状態は資料収集時点のものなので、マージ時に最新の CI 結果も確認する。
最新の CI はマージ時に確認する前提のため、CI が実行中・未検出・未確認であることだけでは
判断を「追加検証が必要」にしない。失敗した CI は判断に反映する（基準は prompt.md）。

### 調査と権限

調査基準の正は [`prompt.md`](actions/review-dependency-update/prompt.md)、
コメント本文の構成の正は [`template.md`](actions/review-dependency-update/template.md)。
テンプレートは prompt.md の末尾に付けて Claude に渡す。ローカルの調査スキルも同じファイルを参照する。
公開の一次情報と PR の base/head のコードを照合し、以下を日本語でコメントする。

- 脆弱性の条件、影響バージョンと修正版
- 更新前の利用箇所・依存経路・入力経路と、本番／ビルド／CI／開発時の影響
- 更新後の破壊的変更・設定変更漏れ・資料収集時点の CI 結果・必要な追加修正
- 根拠へのリンク、未調査範囲、追加検証事項

`mode: review` は読み取り専用ジョブ、`mode: publish` は別のコメント投稿ジョブで使う。
Claude のトークンを投稿ジョブに渡さず、書き込み権限を調査ジョブに与えない。
PR head は checkout せず、API で取得したコードを JSON 内のデータとして読む。
PR 内の hooks・MCP・エージェント指示ファイルは読み込まず、依存インストールやスクリプト実行もしない。
Claude の利用ツールは読み取り・検索に制限し、MCP サーバーは無効化する。
既定ブランチの checkout は信頼済みであることを前提とする。使う runner は GitHub-hosted を想定する。

リポジトリ・Dependabot の作者 login・PR の状態・イベントの base/head SHA を検証する。
調査中に PR が更新された場合は投稿をスキップする。
コメントは `github-actions[bot]` の既存の調査コメントを更新し、メンションは無効化する。
自動修正・マージ・デプロイは行わない。

### 調査の限界と動作確認

コードは各 SHA 最大 120 ファイル、1 ファイル 200 KB、合計 2 MB まで取得する。
省略ファイルとツリーの欠落を記録する。CI は最大 10 ワークフローの各ジョブ・ステップの成否と URL、
失敗した最大 3 ジョブのログ末尾 30000 文字を取得する。取得できないログと省略範囲を明記する。
過去の侵害の有無・実環境の設定は取得しない。
公開 Advisory は PR 本文にある GHSA を最大 10 件補足取得し、それ以外は Claude が公開情報を検索する。
Advisory の参照には公開 GitHub API を使うため、Dependabot alerts の追加権限は不要。
CI 成功は画面表示や全利用経路の互換性まで保証しない。

ローカルのテストは GitHub API のモックを使い、Claude の有料呼び出しやコメント投稿は行わない。
導入後は Dependabot PR で実際に起動し、CI の有無や完了状態にかかわらず調査できること、
PR 更新時のコメント更新、通常ユーザーの PR で Claude が呼ばれないことを確認する。
既存 PR は導入後の追加 push、PR の再オープン、または一度発生した調査ワークフローの再実行で調査できる。
検証用 CI の再実行だけでは調査は起動しない。
外部 Action の更新による挙動変化を避けたい場合は、呼び出し元の `@main` をレビュー済みの
コミット SHA に固定する。Claude の調査失敗時は Actions が失敗し、成功コメントは投稿しない。

```bash
node actions/review-dependency-update/review.test.cjs
```
