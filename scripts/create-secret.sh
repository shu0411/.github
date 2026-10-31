#!/usr/bin/env bash
# claude setup-token でトークンを発行し、指定リポジトリの Actions Secret に登録する。
# 擬似端末に script（util-linux）を使うため Linux / WSL 専用。
set -euo pipefail

SECRET_NAME=CLAUDE_CODE_OAUTH_TOKEN
TOKEN_PATTERN='sk-ant-oat01-[A-Za-z0-9_-]+'

# setup-token は端末向けのTUIにしかトークンを描画しないため、擬似端末の出力を受け取る。
# 折り返されるとトークンが途中で切れるので、端末幅を十分に広げて実行する
issue_token() {
  script -qefc 'stty cols 1000; exec claude setup-token' /dev/null | tee /dev/stderr
}

extract_token() {
  sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | { grep -Eo "$TOKEN_PATTERN" || true; } | tail -n 1
}

prompt_token() {
  local pasted
  echo 'トークンを読み取れませんでした。表示されたトークンを貼り付けてください（入力は表示されません）:' >&2
  IFS= read -rs pasted || true
  if [[ ! "$pasted" =~ ^${TOKEN_PATTERN}$ ]]; then
    echo 'トークンの形式が正しくないため、登録を中止しました。' >&2
    return 1
  fi
  printf '%s' "$pasted"
}

if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]]; then
  echo '使い方: bash scripts/create-secret.sh OWNER/REPO' >&2
  exit 1
fi
repo="$1"

# 長期間有効なトークンを無駄に発行しないよう、先にリポジトリを確認する
gh repo view "$repo" --json name > /dev/null

token="$(issue_token | extract_token)" || true
if [[ -z "$token" ]]; then
  token="$(prompt_token)"
fi

printf '%s' "$token" | gh secret set "$SECRET_NAME" --repo "$repo"
echo "$repo に $SECRET_NAME を登録しました。"
