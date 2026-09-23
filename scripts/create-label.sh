#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]]; then
  echo '使い方: bash scripts/create-label.sh OWNER/REPO' >&2
  exit 1
fi

gh label create ready-for-claude \
  --repo "$1" \
  --force \
  --color 7057ff \
  --description 'Claudeに実装の依頼をする準備が整ったIssue。このラベルが付与されると、GitHub ActionsによりClaudeが呼び出され、実装が開始される。'
