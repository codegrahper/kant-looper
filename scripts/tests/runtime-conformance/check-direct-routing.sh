#!/usr/bin/env bash
# check-direct-routing.sh — HOST-CONTRACT 직접 라우팅의 런타임 그림자 검증

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"

declare -i PASS=0 FAIL=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export KANT_STATE_ROOT="$TMP_ROOT/state"

TASK_MD="$TMP_ROOT/TASK.md"
printf '# Runtime routing test\n\n## 목표\n직접 지정한 provider와 model을 유지한다.\n' > "$TASK_MD"

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

route_from() {
  sed -n 's/^[[:space:]]*effective_route: //p' | tail -1
}

echo "[assertion 1] 명시한 opencode:glm-5.2가 effective_route에 그대로 보존된다"
output="$($KANT_LOOP run "$TASK_MD" --dry-run --agent opencode --model glm-5.2 2>&1)"
rc=$?
route="$(printf '%s\n' "$output" | route_from)"
assert_true "명시적 provider/model 직접 라우팅" test "$rc" -eq 0 -a "$route" = "opencode:glm-5.2"

echo "[assertion 2] codex에서 모델을 생략해도 provider는 codex로 유지되고 기본 모델이 채워진다"
output="$($KANT_LOOP run "$TASK_MD" --dry-run --agent codex 2>&1)"
rc=$?
route="$(printf '%s\n' "$output" | route_from)"
assert_true "codex provider 유지 및 기본 모델 채움" sh -c '[ "$1" -eq 0 ] && case "$2" in codex:?*) exit 0 ;; *) exit 1 ;; esac' sh "$rc" "$route"

echo "[assertion 3/negative] opencode 요청이 codex provider로 몰래 변경되면 실패한다"
output="$($KANT_LOOP run "$TASK_MD" --dry-run --agent opencode --model glm-5.2 2>&1)"
rc=$?
route="$(printf '%s\n' "$output" | route_from)"
# 회귀 시 route가 codex:*가 되어 이 음성 assertion이 실제 FAIL한다.
assert_true "provider 임의 변경 없음" sh -c '[ "$1" -eq 0 ] && case "$2" in codex:*) exit 1 ;; *) exit 0 ;; esac' sh "$rc" "$route"

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
