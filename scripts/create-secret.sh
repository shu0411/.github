#!/usr/bin/env bash
set -euo pipefail

SECRET_NAME=CLAUDE_CODE_OAUTH_TOKEN
TOKEN_PATTERN='sk-ant-oat01-[A-Za-z0-9_-]+'

# setup-token の画面は差分描画で文字が欠けるため、出力は読み取らず貼り付けてもらう
prompt_token() {
  local pasted
  echo '表示されたトークンを1行で貼り付けてください（入力は表示されません）:' >&2
  IFS= read -rs pasted || true
  if [[ ! "$pasted" =~ ^${TOKEN_PATTERN}$ ]]; then
    echo 'トークンの形式が正しくないため、登録を中止しました。' >&2
    return 1
  fi
  printf '%s' "$pasted"
}

# 保存済みのログイン情報があると無効なトークンでも成功するため、空の設定ディレクトリで確認する
verify_token() {
  local config_dir output
  local status=0
  config_dir="$(mktemp -d)"
  output="$(
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    export CLAUDE_CONFIG_DIR="$config_dir" CLAUDE_CODE_OAUTH_TOKEN="$1"
    claude -p 'OKとだけ返答してください' --max-turns 1 < /dev/null 2>&1
  )" || status=$?
  rm -rf "$config_dir"
  if [[ "$status" -ne 0 ]]; then
    echo 'トークンで接続できないため、登録を中止しました。' >&2
    echo "$output" >&2
    return 1
  fi
}

if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]]; then
  echo '使い方: bash scripts/create-secret.sh OWNER/REPO' >&2
  exit 1
fi
repo="$1"

# 長期間有効なトークンを無駄に発行しないよう、先にリポジトリを確認する
gh repo view "$repo" --json name > /dev/null

echo 'トークンが折り返されないよう、ターミナルの幅を広げてから続けてください。' >&2
claude setup-token

token="$(prompt_token)"
verify_token "$token"

printf '%s' "$token" | gh secret set "$SECRET_NAME" --repo "$repo"
echo "$repo に $SECRET_NAME を登録しました。"
