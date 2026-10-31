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

# 実物と同じく、端末幅で折り返して着色したトークンを描画する
cat > "$WORK/stubs/claude" <<'STUB'
#!/usr/bin/env bash
touch "$WORK/claude-called"
[ -n "${CLAUDE_TOKEN_OUTPUT:-}" ] || exit 1
columns="$(stty size | cut -d' ' -f2)"
[ "$columns" -gt 0 ] || columns=80
printf '\033[33m%s\033[39m\n' "$(printf '%s' "$CLAUDE_TOKEN_OUTPUT" | fold -w "$columns")"
STUB
chmod +x "$WORK/stubs/gh" "$WORK/stubs/claude"

failures=0

reset_state() {
  rm -f "$WORK/gh.log" "$WORK/secret" "$WORK/claude-called"
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
token_not_in_arguments() { ! grep -q 'sk-ant' "$WORK/gh.log"; }
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
CLAUDE_TOKEN_OUTPUT="$TOKEN" run_command owner/repo
check '発行されたトークンをSecretに登録する' secret_is "$TOKEN"
check '登録が成功すれば正常終了する' status_is 0
check 'トークンをコマンドライン引数に渡さない' token_not_in_arguments

reset_state
run_command owner/repo < <(sleep 1; printf '%s\n' "$TOKEN")
check '読み取れなければ貼り付けたトークンを登録する' secret_is "$TOKEN"

reset_state
run_command owner/repo < <(sleep 1; printf 'invalid-token\n')
check '貼り付けた値の形式が不正なら異常終了する' status_is 1
check '貼り付けた値の形式が不正なら登録しない' secret_not_set

reset_state
run_command owner/repo < <(sleep 1; printf '\n')
check '貼り付けが空なら登録しない' secret_not_set

if [ "$failures" -ne 0 ]; then
  echo "${failures}件失敗" >&2
  exit 1
fi
echo 'すべて成功'
