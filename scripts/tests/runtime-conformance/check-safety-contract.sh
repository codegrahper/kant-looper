#!/usr/bin/env bash
# check-safety-contract.sh — push/merge/promote/protected-path 안전 경계 검증

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"
SAFETY_CHECK="$SKILL_ROOT/scripts/lib/safety-check.sh"

declare -i PASS=0 FAIL=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_true() {
  local label="$1"
  shift
  if "$@"; then
    echo "  PASS: $label"
    ((PASS++))
  else
    echo "  FAIL: $label"
    ((FAIL++))
  fi
}

echo "[assertion 1/negative] kant-loop.sh에 git push 호출이 추가되면 실패한다"
push_count="$(grep -c 'git push' "$KANT_LOOP" 2>/dev/null || true)"
assert_true "자동 push 호출 없음" test "$push_count" -eq 0

echo "[assertion 2/negative] 모든 git merge 호출은 --ff-only이며 merge 게이트 자체도 존재한다"
merge_lines="$(grep -E '^[[:space:]]*git merge([[:space:]]|$)' "$KANT_LOOP" 2>/dev/null || true)"
unsafe_merge_lines="$(printf '%s\n' "$merge_lines" | grep -v -- '--ff-only' | grep -v '^$' || true)"
assert_true "merge는 ff-only로만 실행" sh -c '[ -n "$1" ] && [ -z "$2" ]' sh "$merge_lines" "$unsafe_merge_lines"

echo "[assertion 3/negative] result=running인 run은 completed 게이트에서 promote가 거부된다"
PROMOTE_REPO="$TMP_ROOT/promote-repo"
PROMOTE_STATE="$TMP_ROOT/promote-state"
mkdir -p "$PROMOTE_REPO" "$PROMOTE_STATE"
git -C "$PROMOTE_REPO" init -q
git -C "$PROMOTE_REPO" config user.email test@example.invalid
git -C "$PROMOTE_REPO" config user.name test
git -C "$PROMOTE_REPO" commit --allow-empty -qm initial
repo_hash="$(cd "$PROMOTE_REPO" && printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-12)"
fake_state="$PROMOTE_STATE/$repo_hash/fake-running-run"
mkdir -p "$fake_state"
printf '%s\n' 'agent/kant/fake-running' > "$fake_state/branch.txt"
printf '%s\n' 'running' > "$fake_state/result.txt"
output="$(cd "$PROMOTE_REPO" && KANT_STATE_ROOT="$PROMOTE_STATE" KANT_NOTIFY_OSASCRIPT=0 "$KANT_LOOP" promote agent/kant/fake-running --target main 2>&1)"
rc=$?
assert_true "미완료 run promote 비영 종료" test "$rc" -ne 0

echo "[assertion 4/negative] 미완료 promote 거부 메시지는 completed 상태 요구를 명시한다"
assert_true "completed 게이트 거부 메시지" sh -c 'printf "%s\n" "$1" | grep -Eq "not .completed.|completed.*(불가|거부|필요)"' sh "$output"

echo "[assertion 5/negative] 변경 목록의 보호 경로 .env는 safety-check paths가 차단한다"
BLOCKED_REPO="$TMP_ROOT/blocked-repo"
mkdir -p "$BLOCKED_REPO"
git -C "$BLOCKED_REPO" init -q
git -C "$BLOCKED_REPO" config user.email test@example.invalid
git -C "$BLOCKED_REPO" config user.name test
git -C "$BLOCKED_REPO" commit --allow-empty -qm initial
printf '%s\n' 'TEST_ONLY=value' > "$BLOCKED_REPO/.env"
output="$($SAFETY_CHECK paths "$BLOCKED_REPO" 2>&1)"
rc=$?
assert_true "보호 경로 변경 차단" sh -c '[ "$1" -ne 0 ] && printf "%s\n" "$2" | grep -q "^.env "' sh "$rc" "$output"

echo "[assertion 6] 보호 경로 변경이 없는 깨끗한 git worktree는 safety-check paths를 통과한다"
CLEAN_REPO="$TMP_ROOT/clean-repo"
mkdir -p "$CLEAN_REPO"
git -C "$CLEAN_REPO" init -q
git -C "$CLEAN_REPO" config user.email test@example.invalid
git -C "$CLEAN_REPO" config user.name test
printf '%s\n' 'clean' > "$CLEAN_REPO/README.md"
git -C "$CLEAN_REPO" add README.md
git -C "$CLEAN_REPO" commit -qm initial
output="$($SAFETY_CHECK paths "$CLEAN_REPO" 2>&1)"
rc=$?
assert_true "깨끗한 worktree 허용" test "$rc" -eq 0 -a -z "$output"

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
