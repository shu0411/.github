#!/usr/bin/env bash

set -euo pipefail

assert_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -Fq -- "$expected" "$file"; then
    printf '期待する記述がありません: %s: %s\n' "$file" "$expected" >&2
    return 1
  fi
}

for action in actions/design-issue/action.yml actions/respond-mention/action.yml; do
  assert_contains "$action" 'Bash(gh issue create:*)'
  assert_contains "$action" '別のIssueへのコメント'
  assert_contains "$action" '新しいIssueの作成'
  assert_contains "$action" '明示的に依頼された場合'
  assert_contains "$action" '@claude'
done

printf 'Actionの振る舞いに関するテストが成功しました。\n'
