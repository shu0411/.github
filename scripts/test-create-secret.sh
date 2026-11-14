#!/usr/bin/env bash
# scripts/create-secret.sh のテスト。claude / gh はスタブに差し替え、実際の発行・登録は行わない。
set -uo pipefail

COMMAND="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/create-secret.sh"
TOKEN="sk-ant-oat01-$(printf 'aB3_-%.0s' {1..20})"

WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/stubs"

# リポジトリごとの状態は空白区切りの環境変数で与える
#   GH_INACCESSIBLE: repo view が失敗する / GH_REPOS: 所有リポジトリ / GH_ARCHIVED: アーカイブ済み
#   GH_REGISTERED: CLAUDE_CODE_OAUTH_TOKEN が登録済み / GH_SIMILAR: 名前の似た別の Secret だけが登録済み
#   GH_SECRET_LIST_FAIL: Secret の一覧取得が失敗する / GH_SET_FAIL: Secret の登録が失敗する
cat > "$WORK/stubs/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/gh.log"
includes() { [[ " $1 " == *" $2 "* ]]; }
repo=''
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = --repo ] && repo="${args[$((i + 1))]}"
done
case "$1 $2" in
  'repo view')
    includes "${GH_INACCESSIBLE:-}" "$3" && exit 1
    exit 0
    ;;
  'repo list')
    [ -n "${GH_LIST_EXIT:-}" ] && exit "$GH_LIST_EXIT"
    for r in ${GH_REPOS:-}; do echo "$r"; done
    if ! includes "$*" --no-archived; then
      for r in ${GH_ARCHIVED:-}; do echo "$r"; done
    fi
    ;;
  'secret list')
    includes "${GH_SECRET_LIST_FAIL:-}" "$repo" && exit 1
    echo OTHER_SECRET
    includes "${GH_REGISTERED:-}" "$repo" && echo CLAUDE_CODE_OAUTH_TOKEN
    includes "${GH_SIMILAR:-}" "$repo" && echo CLAUDE_CODE_OAUTH_TOKEN_OLD
    exit 0
    ;;
  'secret set')
    includes "${GH_SET_FAIL:-}" "$repo" && exit 1
    cat > "$WORK/secrets/${repo//\//__}"
    ;;
esac
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
  rm -rf "$WORK"/{gh.log,secrets,claude-called,verify-called,verified-token,verify-api-key,verify-config-dir,verify-config-empty}
  mkdir "$WORK/secrets"
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

secret_is() { [ "$(cat "$WORK/secrets/${1//\//__}" 2>/dev/null)" = "$2" ]; }
secret_not_set_to() { [ ! -e "$WORK/secrets/${1//\//__}" ]; }
secret_not_set() { [ -z "$(ls -A "$WORK/secrets")" ]; }
claude_not_called() { [ ! -e "$WORK/claude-called" ]; }
verify_not_called() { [ ! -e "$WORK/verify-called" ]; }
verified_with_token() { [ "$(cat "$WORK/verified-token" 2>/dev/null)" = "$TOKEN" ]; }
verified_without_api_key() { [ ! -s "$WORK/verify-api-key" ]; }
verified_with_empty_config() { [ -e "$WORK/verify-config-empty" ]; }
config_dir_removed() { [ ! -e "$(cat "$WORK/verify-config-dir")" ]; }
token_not_in_arguments() { ! grep -q 'sk-ant' "$WORK/gh.log"; }
output_contains() { grep -q -- "$1" "$WORK/output"; }
status_is() { [ "$status" -eq "$1" ]; }
status_is_not_zero() { [ "$status" -ne 0 ]; }

# --- 引数の検証 ---

reset_state
run_command
check '引数がなければ異常終了する' status_is 1
check '引数がなければトークンを発行しない' claude_not_called

reset_state
run_command not-a-repo
check 'リポジトリの形式が不正なら異常終了する' status_is 1
check 'リポジトリの形式が不正ならトークンを発行しない' claude_not_called

reset_state
run_command owner/a not-a-repo
check '複数指定のうち1つでも形式が不正なら異常終了する' status_is 1
check '複数指定のうち1つでも形式が不正ならトークンを発行しない' claude_not_called

reset_state
run_command --owner
check '--owner にOWNERがなければ異常終了する' status_is 1
check '--owner にOWNERがなければトークンを発行しない' claude_not_called

reset_state
run_command --owner owner/repo
check '--owner のOWNERの形式が不正なら異常終了する' status_is 1
check '--owner のOWNERの形式が不正ならトークンを発行しない' claude_not_called

# --- リポジトリを指定して登録する ---

reset_state
GH_INACCESSIBLE=owner/repo run_command owner/repo
check 'リポジトリにアクセスできなければ異常終了する' status_is_not_zero
check 'リポジトリにアクセスできなければトークンを発行しない' claude_not_called

reset_state
GH_INACCESSIBLE=owner/b run_command owner/a owner/b
check '複数指定のうち1つでもアクセスできなければ異常終了する' status_is_not_zero
check '複数指定のうち1つでもアクセスできなければトークンを発行しない' claude_not_called

reset_state
ANTHROPIC_API_KEY=dummy run_command owner/repo <<< "$TOKEN"
check '貼り付けたトークンをSecretに登録する' secret_is owner/repo "$TOKEN"
check '登録が成功すれば正常終了する' status_is 0
check 'トークンをコマンドライン引数に渡さない' token_not_in_arguments
check '貼り付けたトークンで接続を確認する' verified_with_token
check '接続の確認にほかの認証情報を使わない' verified_without_api_key
check '接続の確認に保存済みのログイン情報を使わない' verified_with_empty_config
check '接続の確認に使った設定ディレクトリを残さない' config_dir_removed

reset_state
run_command owner/a owner/b <<< "$TOKEN"
check '複数指定したリポジトリすべてに同じトークンを登録する' \
  eval 'secret_is owner/a "$TOKEN" && secret_is owner/b "$TOKEN"'
check '複数指定で登録が成功すれば正常終了する' status_is 0

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

reset_state
GH_SET_FAIL=owner/a run_command owner/a owner/b <<< "$TOKEN"
check '登録に失敗したリポジトリがあっても残りには登録する' secret_is owner/b "$TOKEN"
check '登録に失敗したリポジトリがあれば異常終了する' status_is 1
check '登録に失敗したリポジトリを表示する' output_contains '失敗: owner/a'

# --- 登録済みのリポジトリをまとめて更新する（--owner） ---

reset_state
GH_REPOS='owner/a owner/b owner/c' GH_REGISTERED='owner/a owner/c' \
  run_command --owner owner <<< $'y\n'"$TOKEN"
check '登録済みのリポジトリすべてに同じトークンを登録する' \
  eval 'secret_is owner/a "$TOKEN" && secret_is owner/c "$TOKEN"'
check '未登録のリポジトリには登録しない' secret_not_set_to owner/b
check '登録済みのリポジトリの更新が成功すれば正常終了する' status_is 0
check '更新の前に対象のリポジトリを表示する' \
  eval 'output_contains owner/a && output_contains owner/c'

reset_state
GH_REPOS='owner/a owner/b' GH_REGISTERED=owner/a GH_SIMILAR=owner/b \
  run_command --owner owner <<< $'y\n'"$TOKEN"
check '名前の似た別のSecretだけがあるリポジトリには登録しない' secret_not_set_to owner/b

reset_state
GH_REPOS=owner/a GH_ARCHIVED=owner/z GH_REGISTERED='owner/a owner/z' \
  run_command --owner owner <<< $'y\n'"$TOKEN"
check 'アーカイブ済みのリポジトリには登録しない' secret_not_set_to owner/z

reset_state
GH_REPOS='owner/a owner/b' GH_REGISTERED='owner/a owner/b' GH_SECRET_LIST_FAIL=owner/b \
  run_command --owner owner <<< $'y\n'"$TOKEN"
check 'Secretを確認できないリポジトリを除いて登録する' secret_is owner/a "$TOKEN"
check 'Secretを確認できないリポジトリには登録しない' secret_not_set_to owner/b
check 'Secretを確認できないリポジトリを表示する' output_contains owner/b

reset_state
GH_REPOS='owner/a' GH_REGISTERED=owner/a run_command --owner owner <<< $'n\n'"$TOKEN"
check '確認で中止すれば異常終了する' status_is_not_zero
check '確認で中止すればトークンを発行しない' claude_not_called
check '確認で中止すれば登録しない' secret_not_set

reset_state
GH_REPOS='owner/a' GH_REGISTERED=owner/a run_command --owner owner <<< ''
check '確認に回答がなければトークンを発行しない' claude_not_called

reset_state
GH_REPOS='owner/a owner/b' run_command --owner owner <<< $'y\n'"$TOKEN"
check '登録済みのリポジトリがなければ異常終了する' status_is 1
check '登録済みのリポジトリがなければトークンを発行しない' claude_not_called

reset_state
GH_LIST_EXIT=1 run_command --owner owner <<< $'y\n'"$TOKEN"
check 'リポジトリの一覧を取得できなければ異常終了する' status_is_not_zero
check 'リポジトリの一覧を取得できなければトークンを発行しない' claude_not_called

if [ "$failures" -ne 0 ]; then
  echo "${failures}件失敗" >&2
  exit 1
fi
echo 'すべて成功'
