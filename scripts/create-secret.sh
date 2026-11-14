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

REPO_PATTERN='^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$'
OWNER_PATTERN='^[A-Za-z0-9][A-Za-z0-9-]*$'

usage() {
  echo '使い方: bash scripts/create-secret.sh OWNER/REPO [OWNER/REPO...]' >&2
  echo '        bash scripts/create-secret.sh --registered OWNER' >&2
  exit 1
}

# OWNER のアーカイブされていないリポジトリのうち、Secret が登録済みのものを出力する
find_registered_repos() {
  local owner="$1" list repo names
  local repos=()
  if ! list="$(gh repo list "$owner" --no-archived --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')"; then
    echo "$owner のリポジトリ一覧を取得できませんでした。" >&2
    return 1
  fi
  [[ -n "$list" ]] && mapfile -t repos <<< "$list"
  for repo in "${repos[@]}"; do
    if ! names="$(gh secret list --repo "$repo" --json name --jq '.[].name')"; then
      echo "$repo の Secret を確認できないため、対象から除外します。" >&2
      continue
    fi
    if grep -qxF "$SECRET_NAME" <<< "$names"; then
      echo "$repo"
    fi
  done
}

confirm_targets() {
  local answer
  echo "次のリポジトリの $SECRET_NAME を新しいトークンで更新します:" >&2
  printf '  %s\n' "$@" >&2
  echo '続けますか？ [y/N]' >&2
  IFS= read -r answer || true
  if [[ "$answer" != [yY] ]]; then
    echo '中止しました。' >&2
    return 1
  fi
}

# トークンは発行済みのため、途中で失敗しても残りのリポジトリへの登録を続ける
apply_secret() {
  local token="$1" repo
  shift
  local failed=()
  for repo in "$@"; do
    if printf '%s' "$token" | gh secret set "$SECRET_NAME" --repo "$repo"; then
      echo "成功: $repo" >&2
    else
      echo "失敗: $repo" >&2
      failed+=("$repo")
    fi
  done
  if [[ "${#failed[@]}" -ne 0 ]]; then
    echo "${#failed[@]}件のリポジトリに登録できませんでした。個別にこのコマンドを実行して登録してください。" >&2
    return 1
  fi
  echo "$# 件のリポジトリに $SECRET_NAME を登録しました。" >&2
}

# 長期間有効なトークンを無駄に発行しないよう、トークンの発行前に対象リポジトリを確定する
targets=()
if [[ "${1:-}" == --registered ]]; then
  [[ $# -eq 2 && "$2" =~ $OWNER_PATTERN ]] || usage
  found="$(find_registered_repos "$2")"
  [[ -n "$found" ]] && mapfile -t targets <<< "$found"
  if [[ "${#targets[@]}" -eq 0 ]]; then
    echo "$2 に $SECRET_NAME が登録済みのリポジトリはありません。" >&2
    exit 1
  fi
  confirm_targets "${targets[@]}"
else
  [[ $# -ge 1 ]] || usage
  for repo in "$@"; do
    [[ "$repo" =~ $REPO_PATTERN ]] || usage
  done
  for repo in "$@"; do
    gh repo view "$repo" --json name > /dev/null
  done
  targets=("$@")
fi

echo 'トークンが折り返されないよう、ターミナルの幅を広げてから続けてください。' >&2
claude setup-token

token="$(prompt_token)"
verify_token "$token"

apply_secret "$token" "${targets[@]}"
