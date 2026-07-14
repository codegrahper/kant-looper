#!/usr/bin/env bash
# test-meta-aware-routing.sh — 메타 에이전트 판단 기반 라우팅 테스트
#
# 기존 자동 라우팅은 "인증 로직을 수정하고 테스트를 추가한다" 같은 작업에서
# "테스트" 키워드에 이끌려 codex:luna를 선택함 (잘못된 라우팅).
# 메타 에이전트가 작업의 주 의도를 먼저 판단하면 이 문제가 개선됨.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
ROUTING_PARSER="$SKILL_ROOT/scripts/lib/routing-parser.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# 색상
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "${GREEN}PASS${NC}: $label"
    PASSED=$((PASSED + 1))
  else
    echo "${RED}FAIL${NC}: $label"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAILED=$((FAILED + 1))
  fi
}

# ----------------------------------------------------------------------------
# 기존 동작 회귀 테스트 (하위 호환성)
# ----------------------------------------------------------------------------

echo "=== 기존 CLI 회귀 테스트 ==="

# 1. 키워드 "test"가 포함된 작업: 기존 동작 = codex:luna
TASK_FILE="$TMPDIR/test_task.md"
echo "# 단위 테스트 작성" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null || true)"
assert_eq "기존 match: test 키워드 → codex:luna" "codex:gpt-5.6-luna" "$result"

# 2. 키워드 "refactor"가 포함된 작업: 기존 동작 = opencode:glm-5.2
echo "# 코드 리팩터링" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null || true)"
assert_eq "기존 match: refactor → opencode:glm-5.2" "opencode:glm-5.2" "$result"

# 3. 키워드 "ui"가 포함된 작업: 기존 동작 = agy:gemini-3.5-flash
echo "# UI 컴포넌트 수정" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null || true)"
assert_eq "기존 match: ui → agy:gemini-3.5-flash" "agy:gemini-3.5-flash" "$result"

# ----------------------------------------------------------------------------
# 새 기능: 메타 에이전트 판단 기반 라우팅
# ----------------------------------------------------------------------------

echo ""
echo "=== 메타 에이전트 판단 기반 라우팅 (신규) ==="

# 4. 주 의도 = "implement", 보조 키워드 = "test" → codex:terra (구현이 주)
# 기존 동작: codex:luna (잘못된 라우팅)
echo "# 인증 로직을 수정하고 테스트를 추가한다" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=implement --complexity=T1 2>/dev/null || true)"
expected="codex:gpt-5.6-terra"
assert_eq "메타 판단: implement+T1 → codex:terra (기존 match 결과와 다름)" "$expected" "$result"

# 5. 주 의도 = "implement", 복잡도 = T3 → codex:sol (저장소 영향 큼)
echo "# 분산 시스템의 결제 모듈을 전체적으로 재설계" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=implement --complexity=T3 2>/dev/null || true)"
expected="codex:gpt-5.6-sol"
assert_eq "메타 판단: implement+T3 → codex:sol" "$expected" "$result"

# 6. 주 의도 = "review", 복잡도 = T2 → codex:sol
echo "# PR 리뷰를 수행하고 개선 제안" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=review --complexity=T2 2>/dev/null || true)"
expected="codex:gpt-5.6-sol"
assert_eq "메타 판단: review+T2 → codex:sol" "$expected" "$result"

# 7. 주 의도 = "refactor", 복잡도 = T3 → opencode:glm-5.2
echo "# 대형 저장소 리팩터링" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=refactor --complexity=T3 2>/dev/null || true)"
expected="opencode:glm-5.2"
assert_eq "메타 판단: refactor+T3 → opencode:glm-5.2" "$expected" "$result"

# 8. 주 의도 = "test", 복잡도 = T0 → codex:luna (맞음)
echo "# 함수 단위 테스트 추가" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=test --complexity=T0 2>/dev/null || true)"
expected="codex:gpt-5.6-luna"
assert_eq "메타 판단: test+T0 → codex:luna" "$expected" "$result"

# 9. 주 의도 = "ui", 복잡도 = T2 → agy:gemini-3.5-flash
echo "# 새로운 UI 컴포넌트 디자인" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=ui --complexity=T2 2>/dev/null || true)"
expected="agy:gemini-3.5-flash"
assert_eq "메타 판단: ui+T2 → agy:gemini-3.5-flash" "$expected" "$result"

# 10. 주 의도 = "implement", 복잡도 = T4 (1M 컨텍스트 필요) → opencode:glm-5.2
echo "# 전체 코드베이스 분석 후 구현" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=implement --complexity=T4 2>/dev/null || true)"
expected="opencode:glm-5.2"
assert_eq "메타 판단: implement+T4 → opencode:glm-5.2" "$expected" "$result"

# ----------------------------------------------------------------------------
# 결과 출력
# ----------------------------------------------------------------------------

echo ""
echo "=== 결과 ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0