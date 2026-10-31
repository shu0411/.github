#!/usr/bin/env bash
# scripts/create-secret.sh のテスト。claude / gh はスタブに差し替え、実際の発行・登録は行わない。
set -uo pipefail

COMMAND="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/create-secret.sh"
TOKEN="sk-ant-oat01-$(printf 'aB3_-%.0s' {1..20})"

WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/stubs"

cat > "$WORK/stubs/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/gh.log"
[ "$1" = repo ] && exit "${GH_REPO_EXIT:-0}"
cat > "$WORK/secret"
STUB

# 発行（setup-token）と、トークンの確認（-p）で動作を分ける
cat > "$WORK/stubs/claude" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = setup-token ]; then
  touch "$WORK/claude-called"
  exit "${SETUP_TOKEN_EXIT:-0}"
fi
touch "$WORK/verify-called"
printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" > "$WORK/verified-token"
printf '%s' "${ANTHROPIC_API_KEY:-}" > "$WORK/verify-api-key"
printf '%s' "$CLAUDE_CONFIG_DIR" > "$WORK/verify-config-dir"
[ -d "$CLAUDE_CONFIG_DIR" ] && [ -z "$(ls -A "$CLAUDE_CONFIG_DIR")" ] && touch "$WORK/verify-config-empty"
echo 'API Error: 401'
exit "${VERIFY_EXIT:-0}"
STUB
chmod +x "$WORK/stubs/gh" "$WORK/stubs/claude"

failures=0

reset_state() {
  rm -f "$WORK"/{gh.log,secret,claude-called,verify-called,verified-token,verify-api-key,verify-config-dir,verify-config-empty}
}

run_command() {
  PATH="$WORK/stubs:$PATH" bash "$COMMAND" "$@" > "$WORK/output" 2>&1
  status=$?
}

check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok: $name"
  else
    echo "NG: $name" >&2
    failures=$((failures + 1))
  fi
}

secret_is() { [ "$(cat "$WORK/secret" 2>/dev/null)" = "$1" ]; }
secret_not_set() { [ ! -e "$WORK/secret" ]; }
claude_not_called() { [ ! -e "$WORK/claude-called" ]; }
verify_not_called() { [ ! -e "$WORK/verify-called" ]; }
verified_with_token() { [ "$(cat "$WORK/verified-token" 2>/dev/null)" = "$TOKEN" ]; }
verified_without_api_key() { [ ! -s "$WORK/verify-api-key" ]; }
verified_with_empty_config() { [ -e "$WORK/verify-config-empty" ]; }
config_dir_removed() { [ ! -e "$(cat "$WORK/verify-config-dir")" ]; }
token_not_in_arguments() { ! grep -q 'sk-ant' "$WORK/gh.log"; }
output_contains() { grep -q "$1" "$WORK/output"; }
status_is() { [ "$status" -eq "$1" ]; }
status_is_not_zero() { [ "$status" -ne 0 ]; }

reset_state
run_command not-a-repo
check 'リポジトリの形式が不正なら異常終了する' status_is 1
check 'リポジトリの形式が不正ならトークンを発行しない' claude_not_called

reset_state
GH_REPO_EXIT=1 run_command owner/repo
check 'リポジトリにアクセスできなければ異常終了する' status_is_not_zero
check 'リポジトリにアクセスできなければトークンを発行しない' claude_not_called

reset_state
ANTHROPIC_API_KEY=dummy run_command owner/repo <<< "$TOKEN"
check '貼り付けたトークンをSecretに登録する' secret_is "$TOKEN"
check '登録が成功すれば正常終了する' status_is 0
check 'トークンをコマンドライン引数に渡さない' token_not_in_arguments
check '貼り付けたトークンで接続を確認する' verified_with_token
check '接続の確認にほかの認証情報を使わない' verified_without_api_key
check '接続の確認に保存済みのログイン情報を使わない' verified_with_empty_config
check '接続の確認に使った設定ディレクトリを残さない' config_dir_removed

reset_state
VERIFY_EXIT=1 run_command owner/repo <<< "$TOKEN"
check '接続を確認できなければ異常終了する' status_is 1
check '接続を確認できなければ登録しない' secret_not_set
check '接続を確認できなければエラー内容を表示する' output_contains 'API Error: 401'
check '接続を確認できなくても設定ディレクトリを残さない' config_dir_removed

reset_state
SETUP_TOKEN_EXIT=1 run_command owner/repo <<< "$TOKEN"
check 'トークンの発行に失敗すれば異常終了する' status_is_not_zero
check 'トークンの発行に失敗すれば登録しない' secret_not_set

reset_state
run_command owner/repo <<< 'invalid-token'
check '貼り付けた値の形式が不正なら異常終了する' status_is 1
check '貼り付けた値の形式が不正なら接続を確認しない' verify_not_called
check '貼り付けた値の形式が不正なら登録しない' secret_not_set

reset_state
run_command owner/repo <<< ''
check '貼り付けが空なら登録しない' secret_not_set

if [ "$failures" -ne 0 ]; then
  echo "${failures}件失敗" >&2
  exit 1
fi
echo 'すべて成功'
