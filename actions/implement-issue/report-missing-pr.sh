#!/usr/bin/env bash
# 実装の実行後、対象Issueを閉じるPull Requestが存在しなければ、
# 状況（Claudeの最終メッセージ・権限で拒否されたコマンド）をIssueにコメントしてジョブを失敗させる。
#
# 環境変数:
#   GH_TOKEN           Issueへのコメント権限（issues: write）を持つトークン
#   GITHUB_REPOSITORY  対象リポジトリ（OWNER/REPO）
#   ISSUE_NUMBER       対象Issueの番号
#   EXECUTION_FILE     claude-code-action の実行ログ（JSON）。無い場合は詳細を省いて報告する
#   RUN_URL            このworkflow実行のURL
set -euo pipefail

pr_count=$(
  gh pr list --repo "$GITHUB_REPOSITORY" --state open --limit 100 --json body |
    jq --arg n "$ISSUE_NUMBER" '[.[] | select(.body | test("Closes #" + $n + "\\b"))] | length'
)
if [[ "$pr_count" -gt 0 ]]; then
  echo "Issue #${ISSUE_NUMBER} を閉じるPull Requestを確認しました。"
  exit 0
fi

# 実行ログの最後の result メッセージから、指定したjqフィルタの結果を取り出す
read_result() {
  [[ -f "${EXECUTION_FILE:-}" ]] || return 0
  jq -r "(if type == \"array\" then . else [.] end) | map(select(.type == \"result\")) | last // {} | $1" \
    "$EXECUTION_FILE" || true
}

final_message=$(read_result '.result // "" | tostring | .[0:3000]')
denials=$(read_result '.permission_denials // [] | .[]
  | "- " + .tool_name + ": "
    + ((.tool_input.command // .tool_input.file_path // (.tool_input | tojson)) | tostring | .[0:500])')

body_file=$(mktemp)
{
  echo "## 実装が完了しませんでした"
  echo
  echo "実装のworkflowは終了しましたが、このIssueを閉じるPull Requestが作成されていません。"
  echo
  echo "- 実行ログ: ${RUN_URL}"
  echo
  echo "### 権限で拒否されたコマンド"
  echo
  if [[ -n "$denials" ]]; then
    echo '````text'
    echo "$denials"
    echo '````'
  else
    echo "記録はありません。"
  fi
  echo
  echo "### Claudeの最終メッセージ"
  echo
  if [[ -n "$final_message" ]]; then
    echo '````text'
    echo "$final_message"
    echo '````'
  else
    echo "取得できませんでした（最大ターン数への到達や実行エラーの可能性があります）。"
  fi
} > "$body_file"

gh issue comment "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$body_file" ||
  echo "::warning::Issueへのコメントに失敗しました（呼び出し側 workflow に issues: write が必要です）。"

echo "::error::Issue #${ISSUE_NUMBER} を閉じるPull Requestが作成されませんでした。"
exit 1
