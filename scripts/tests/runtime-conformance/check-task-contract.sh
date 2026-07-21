#!/usr/bin/env bash
# check-task-contract.sh — TASK 목표 섹션 강제 계약 검증

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"

declare -i PASS=0 FAIL=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export KANT_STATE_ROOT="$TMP_ROOT/state"

VALID_TASK="$TMP_ROOT/TASK-valid.md"
INVALID_TASK="$TMP_ROOT/TASK-without-objective.md"
printf '# Valid task\n\n## 목표\n목표가 있는 작업만 수락한다.\n' > "$VALID_TASK"
printf '# Invalid task\n\n## 작업\n목표 섹션이 의도적으로 없다.\n' > "$INVALID_TASK"

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

echo "[assertion 1] ## 목표가 있는 TASK는 dry-run에 성공하고 effective_route를 출력한다"
output="$($KANT_LOOP run "$VALID_TASK" --dry-run --agent codex 2>&1)"
rc=$?
assert_true "유효한 TASK 수락" sh -c '[ "$1" -eq 0 ] && printf "%s\n" "$2" | grep -q "^[[:space:]]*effective_route: codex:"' sh "$rc" "$output"

echo "[assertion 2/negative] 목표 계열 섹션이 없는 TASK는 dry-run 전에 비영으로 거부된다"
output="$($KANT_LOOP run "$INVALID_TASK" --dry-run --agent codex 2>&1)"
rc=$?
# validate_task_md가 제거되거나 dry-run 검증보다 뒤로 밀리면 rc=0이 되어 실제 FAIL한다.
assert_true "목표 없는 TASK 실행 거부" test "$rc" -ne 0

echo "[assertion 3/negative] 목표 없는 TASK 거부 메시지는 필요한 목표 섹션을 명시한다"
assert_true "목표 섹션 요구 오류 메시지" sh -c 'printf "%s\n" "$1" | grep -Eq "(must have.*(목표|Goal|Objective)|목표.*(필요|요구))"' sh "$output"

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
