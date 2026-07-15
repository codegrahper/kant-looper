#!/usr/bin/env bash
# test-meta-aware-routing.sh — 메타 에이전트 판단 기반 라우팅 테스트
#
# Phase 1/2: judge_task_routing() 통합 후 업데이트
# - match, match-with-judgment, judge 모두 judge_task_routing() 사용
# - 출력 포맷: multi-line key=value (intent, complexity, judged_route, effective_route, fallback_reason, reason)

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
ROUTING_PARSER="$SKILL_ROOT/scripts/lib/routing-parser.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

# judge_task_routing 출력에서 judged_route 추출
get_judged_route() {
  printf '%s' "$1" | grep '^judged_route=' | cut -d= -f2
}

# judge_task_routing 출력에서 intent 추출
get_intent() {
  printf '%s' "$1" | grep '^intent=' | cut -d= -f2
}

# judge_task_routing 출력에서 complexity 추출
get_complexity() {
  printf '%s' "$1" | grep '^complexity=' | cut -d= -f2
}

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
# judge_task_routing 통합 테스트 (match, judge, match-with-judgment 통일)
# ----------------------------------------------------------------------------

echo "=== judge_task_routing() 통합: match ==="

TASK_FILE="$TMPDIR/test_task.md"

echo "# 단위 테스트 작성" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null || true)"
route="$(get_judged_route "$result")"
assert_eq "match: test 키워드 → codex:luna" "codex:gpt-5.6-luna" "$route"

echo "# 코드 리팩터링" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null || true)"
route="$(get_judged_route "$result")"
assert_eq "match: refactor → opencode:glm-5.2" "opencode:glm-5.2" "$route"

# Phase 1/2: component만으로는 UI가 아님 (강한 신호 필요)
echo "# UI 컴포넌트 수정" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null || true)"
route="$(get_judged_route "$result")"
# component는 CSS/layout 관련으로 +2점이지만, 강한 UI 신호 없으면 debug가 우선
assert_eq "match: component만으로는 UI 아님 → codex:terra" "codex:gpt-5.6-terra" "$route"

echo ""
echo "=== judge_task_routing() 통합: judge ==="

# judge는 match와 동일한 결과어야 함
echo "# 단위 테스트 작성" > "$TASK_FILE"
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
route="$(get_judged_route "$result")"
assert_eq "judge: test 키워드 → codex:luna" "codex:gpt-5.6-luna" "$route"

echo "# Bash 어댑터 파서 리팩터링" > "$TASK_FILE"
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
route="$(get_judged_route "$result")"
assert_eq "judge: refactor 신호 → refactor intent" "refactor" "$intent"
assert_eq "judge: refactor → opencode:glm-5.2" "opencode:glm-5.2" "$route"

echo ""
echo "=== match-with-judgment (--intent/--complexity 무시됨) ==="

# match-with-judgment는 이제 judge_task_routing()을 직접 호출
# --intent, --complexity 인자는 무시되고 자동으로 계산됨

echo "# 인증 로직을 수정하고 테스트를 추가한다" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=implement --complexity=T1 2>/dev/null || true)"
route="$(get_judged_route "$result")"
# 자동 계산: 수정(+3) + 테스트(+3) = debug/test 동점 → debug 우선
assert_eq "match-with-judgment: 자동 계산 → codex:terra" "codex:gpt-5.6-terra" "$route"

echo "# 분산 시스템의 결제 모듈을 전체적으로 재설계" > "$TASK_FILE"
result="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" --intent=implement --complexity=T3 2>/dev/null || true)"
complexity="$(get_complexity "$result")"
route="$(get_judged_route "$result")"
# 자동 계산: "전체적으로 재설계"는 T3 패턴 없음 (저장소 전체/리팩터 마이그레이션 아님)
# "재설계" alone doesn't match T3 patterns → T2
assert_eq "match-with-judgment: 전체 재설계 → T2" "T2" "$complexity"
assert_eq "match-with-judgment: implement+T2 → codex:terra" "codex:gpt-5.6-terra" "$route"

echo ""
echo "=== 의도/복잡도 휴리스틱 회귀 테스트 ==="

printf '%s\n' '# Bash 어댑터의 작업 디렉터리 접근 권한 오류 수정' > "$TASK_FILE"
result="$("$ROUTING_PARSER" classify-intent "$TASK_FILE")"
assert_eq "접근 권한은 UI가 아니라 debug" "debug" "$result"

printf '%s\n' '# UI 접근성 개선' > "$TASK_FILE"
result="$("$ROUTING_PARSER" classify-intent "$TASK_FILE")"
assert_eq "실제 UI 접근성은 ui" "ui" "$result"

printf '%s\n' '# PR 리뷰 수행' > "$TASK_FILE"
result="$("$ROUTING_PARSER" classify-intent "$TASK_FILE")"
assert_eq "리뷰는 review" "review" "$result"

printf '%s\n' '# 대규모 코드 리팩터링' > "$TASK_FILE"
result="$("$ROUTING_PARSER" classify-intent "$TASK_FILE")"
assert_eq "리팩터링은 refactor" "refactor" "$result"

printf '%s\n' '# Bash 명령어 옵션 추가' > "$TASK_FILE"
result="$("$ROUTING_PARSER" classify-intent "$TASK_FILE")"
assert_eq "Bash 작업은 cli" "cli" "$result"

printf '%s\n' '# 저장소 전체 영향 분석' > "$TASK_FILE"
result="$("$ROUTING_PARSER" estimate-complexity "$TASK_FILE")"
assert_eq "저장소 전체는 T3" "T3" "$result"

printf '%s\n' '# Bash 어댑터의 전체 비용을 낮춘다' > "$TASK_FILE"
result="$("$ROUTING_PARSER" estimate-complexity "$TASK_FILE")"
assert_eq "전체 비용은 T3가 아님" "T1" "$result"

printf '%s\n' '# archive 메타데이터를 읽는다' > "$TASK_FILE"
result="$("$ROUTING_PARSER" estimate-complexity "$TASK_FILE")"
assert_eq "archive의 부분 문자열은 T4가 아님" "T1" "$result"

echo ""
echo "=== judge_task_routing() 새 신호 점수화 테스트 ==="

# Phase 1/2: 증거 점수화 테스트

printf '%s\n' '# 시각적 회귀 테스트 추가' > "$TASK_FILE"
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
route="$(get_judged_route "$result")"
# 시각적 회귀 = strong UI signal → UI intent
assert_eq "visual regression 신호 → ui intent" "ui" "$intent"
assert_eq "visual regression → agy:gemini-3.5-flash" "agy:gemini-3.5-flash" "$route"

printf '%s\n' '# 시스템 커널 모듈 버그 수정' > "$TASK_FILE"
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
route="$(get_judged_route "$result")"
# 버그 + kernel → debug
assert_eq "버그+kernel → debug intent" "debug" "$intent"

printf '%s\n' '# 함수 추출 및 구조 개선' > "$TASK_FILE"
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
# 함수 추출 = refactor signal
assert_eq "함수 추출 → refactor intent" "refactor" "$intent"

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
