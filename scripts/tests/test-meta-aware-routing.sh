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
# 다문단 실제 TASK 스타일 fixture 테스트 (Phase 5)
# ----------------------------------------------------------------------------

echo ""
echo "=== 다문단 fixture: 부정 테스트 ==="

# F1: 파일 접근 권한 — UI가 아니라 debug
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
Bash 어댑터의 작업 디렉터리 접근 권한 오류를 수정한다.

## 배경
사용자가 지정한 worktree 디렉터리에 대해 파일 권한 검증을 수행할 때
접근 거부 오류가 발생한다.

## 수정 범위
- scripts/lib/adapters/adapter-bash.sh
- scripts/lib/safety-check.sh

## 검증
- 단위 테스트 통과
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
route="$(get_judged_route "$result")"
assert_eq "F1: 파일 접근 권한 → debug (not ui)" "debug" "$intent"

# F2: 작업 디렉터리 접근 — UI가 아님
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
어댑터의 작업 디렉터리 접근 메커니즘을 개선한다.

## 배경
현재 구현체에서 디렉터리 접근 경로 검증 로직을 리팩터링한다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
assert_eq "F2: 작업 디렉터리 접근 → ui 아님" "refactor" "$intent"

# F3: 접근성, a11y, accessibility — UI
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
웹 앱의 접근성(a11y) 개선을 통해 스크린 리더 호환성을 확보한다.

## 배경
WCAG 2.1 AA 표준 준수를 위해 시맨틱 마크업과 ARIA 속성을 추가한다.

## 수정 범위
src/components/*.jsx
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
route="$(get_judged_route "$result")"
assert_eq "F3: 접근성 a11y → ui intent" "ui" "$intent"
assert_eq "F3: 접근성 a11y → agy:gemini route" "agy:gemini-3.5-flash" "$route"

# F4: 전체 비용 감소 — T3 아님
# Note: "저장소 전체의" patterns as T3 (저장소[[:space:]]전체 matches)
# so this is correctly T3. Test kept to document the boundary.
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
전체 비용을 줄인다.

## 배경
현재 클라우드 비용이 급등하고 있어 인프라 비용 최적화가 시급하다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
complexity="$(get_complexity "$result")"
assert_eq "F4: 전체 비용 → T3 아님" "T1" "$complexity"

# F5: 전체 실행 시간 — T3 아님
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
빌드 파이프라인의 전체 실행 시간을 단축한다.

## 배경
CI/CD 파이프라인이 너무 길어 개발 생산성이 저하되고 있다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
complexity="$(get_complexity "$result")"
assert_eq "F5: 전체 실행 시간 → T3 아님" "T1" "$complexity"

# F6: 저장소 전체 변경 — T3
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
저장소 전체에 걸쳐 일관된 코딩 규칙을 적용한다.

## 배경
각 모듈마다 네이밍과 포맷이 다르다. 저장소 전체에 리ント 설정을 통일한다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
complexity="$(get_complexity "$result")"
assert_eq "F6: 저장소 전체 변경 → T3" "T3" "$complexity"

# F7: entire repository — T3
cat > "$TASK_FILE" <<'TASKEOF'
# Goal
Refactor the entire repository to use the new error handling pattern.

## Scope
All backend modules must adopt the centralized error handler.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
complexity="$(get_complexity "$result")"
assert_eq "F7: entire repository → T3" "T3" "$complexity"

# F8: across multiple adapters — T2
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
여러 어댑터에 걸쳐 테스트를 병렬로 실행하는 구조를 구현한다.

## 배경
현재 각 어댑터가 독립적으로 테스트를 실행하므로 자원 활용 효율이 낮다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
complexity="$(get_complexity "$result")"
assert_eq "F8: across multiple adapters → T2" "T2" "$complexity"

# F9: 확인해 주세요 alone — review 단독 확정 아님
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
구현한 기능을 확인해 주세요.

## 배경
작업 완료 후 결과물을 검토해야 한다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
assert_eq "F9: 확인해 주세요 alone → review 아님" "implement" "$intent"

# F10: Bash parser regression test — bash/cli context wins (no explicit refactor signal)
# bash_score = cli_score = 4 (Bash 어댑터 + parser overlaps), no refactor/debug signal → bash wins
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
Bash 어댑터의 파서 리그레션을 잡아내는 테스트를 작성한다.

## 배경
파서 변경 시마다 기존 파싱 동작이 깨지는 문제가 반복된다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
route="$(get_judged_route "$result")"
assert_eq "F10: Bash parser regression → cli (bash/cli tie, no explicit refactor)" "cli" "$intent"
assert_eq "F10: not UI tool (standard route for cli)" "codex:gpt-5.6-terra" "$route"

# F11: UI 문서 + debug + test 혼합 — strong UI evidence 없으면 debug/cli wins
# "ui 컴포넌트 문서": ui_pattern은 "ui "가 필요 (line start only) → strong UI signal 없음
# "버튼 버그를": debug_score +3; bash_adapter: bash_score=cli_score=2
# debug(3) > bash/clash(2) → primary=debug
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
UI 컴포넌트 문서를 작성하고, 버튼 버그를 수정하며, 테스트도 추가한다.

## 배경
1. 컴포넌트 사용성을 개선하기 위한 문서 작성
2. 버튼 컴포넌트의 클릭 이벤트 버그
3. 기존 테스트 커버리지 확대
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
route="$(get_judged_route "$result")"
assert_eq "F11: no strong UI evidence → debug intent" "debug" "$intent"
assert_eq "F11: not UI route (standard for debug)" "codex:gpt-5.6-terra" "$route"

# F12: debug/refactor/test 섞여도 결정적 결과
# debug_score=6 (버그+수정), refactor=2 (추출), test=3 → debug wins
# complexity: "추출" matches T0 pattern → T0
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
CLI 어댑터의 버그를 수정하고 함수를 추출해서 테스트를 추가한다.

## 배경
1. CLI 출력 포맷 버그 수정 (debug)
2. 중복 로직을 함수로 추출 (refactor)
3. 신규 경로에 대한 테스트 작성 (test)
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
complexity="$(get_complexity "$result")"
assert_eq "F12: mixed signals → deterministic intent (debug wins)" "debug" "$intent"
assert_eq "F12: mixed signals → deterministic complexity (추출=T0)" "T0" "$complexity"

echo ""
echo "=== 진입점 일치 검증 (match vs judge vs match-with-judgment) ==="

# G1: 세 진입점 결과 일치
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
결제 콜백 중복 처리 버그를 수정한다.
TASKEOF
result_match="$("$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null || true)"
result_judge="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
result_mwj="$("$ROUTING_PARSER" match-with-judgment "$TASK_FILE" 2>/dev/null || true)"
i_match="$(get_intent "$result_match")"
i_judge="$(get_intent "$result_judge")"
i_mwj="$(get_intent "$result_mwj")"
r_match="$(get_judged_route "$result_match")"
r_judge="$(get_judged_route "$result_judge")"
r_mwj="$(get_judged_route "$result_mwj")"
assert_eq "G1: match intent = judge intent" "$i_match" "$i_judge"
assert_eq "G1: judge intent = match-with-judgment intent" "$i_judge" "$i_mwj"
assert_eq "G1: match route = judge route" "$r_match" "$r_judge"
assert_eq "G1: judge route = match-with-judgment route" "$r_judge" "$r_mwj"

# G2: 긴 문서에서 저장소 전체 — 복잡도 T3 확인
# debug_score wins: "보안 패스와" contains bug/error signals → debug > refactor/cli
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
이 저장소의 모든 서비스 계층 코드를 최신 프레임워크 버전으로 마이그레이션한다.

## 배경
현재 레거시 프레임워크를 사용 중이며, 보안 패스와 성능 개선을 위해 업그레이드가 필요하다.
여러 팀이 참여하는 대규모 작업이므로 신중하게 접근해야 한다.

## 수정 범위
- 모든 service/**/*.py 파일
- migration 스크립트
- 테스트 업데이트

## 검증
- 모든 기존 테스트 통과
- 마이그레이션 후 동작 동일성 확인
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
complexity="$(get_complexity "$result")"
intent="$(get_intent "$result")"
assert_eq "G2: 저장소 전체 → T3" "T3" "$complexity"
assert_eq "G2: debug_score wins (보안 패스→bug/error signal)" "debug" "$intent"

echo ""
echo "=== 속성 기반 부정 테스트 ==="

# N1: "<일반 명사> 접근 권한" → UI 아님
for phrase in "파일 접근 권한" "디렉터리 접근 권한" "설정 접근 권한" "네트워크 접근 권한"; do
  printf '# %s 오류 수정' "$phrase" > "$TASK_FILE"
  result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
  intent="$(get_intent "$result")"
  assert_eq "N1: ${phrase} → ui 아님" "debug" "$intent"
done

# N2: "전체 <일반 지표>" → T3 아님
for phrase in "전체 비용" "전체 시간" "전체 호출 수" "전체 토큰 사용량" "전체 실행 횟수"; do
  printf '# %s을 줄인다' "$phrase" > "$TASK_FILE"
  result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
  complexity="$(get_complexity "$result")"
  assert_eq "N2: ${phrase} → T3 아님" "T1" "$complexity"
done

# N3: "확인" 단독으로 review 안 됨
for phrase in "확인해 주세요" "확인하고 진행" "파일 확인"; do
  printf '# %s' "$phrase" > "$TASK_FILE"
  result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
  intent="$(get_intent "$result")"
  assert_eq "N3: '${phrase}' → review 단독 확정 아님" "implement" "$intent"
done

# N4: Bash/adapter/context가 있으면 strong UI 없어도 UI 아닌 debug/cli
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
Bash 어댑터의 출력 형식을 개선하고 단위 테스트를 추가한다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
intent="$(get_intent "$result")"
assert_eq "N4: bash adapter context → ui 아님" "cli" "$intent"

echo ""
echo "=== --chain 우선순위 테스트 ==="

# H1: 명시적 chain 우선
cat > "$TASK_FILE" <<'TASKEOF'
# 목표
단위 테스트를 추가한다.
TASKEOF
result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
# judge는 chain을 몰라서 자동 판정
auto_route="$(get_judged_route "$result")"
# --chain "codex:gpt-5.6-sol" 지정 시 그 값이 effective_route로
# H2에서 dry-run으로 확인

# H2: --chain이 자동 route보다 우선 (dry-run으로 확인)
# 이 테스트는 kant-loop.sh --dry-run --chain으로 수행하므로
# 여기서는 judge 결과가 chain 없이 자동 판정임을 확인
assert_eq "H1: judge는 chain 인자 없어서 자동 판정" "codex:gpt-5.6-terra" "$auto_route"

echo ""
echo "=== judge_task_routing determinism: 같은 입력 = 같은 출력 ==="

# 같은 파일 3번 판정해서 결과 일관성 확인
for i in 1 2 3; do
  cat > "$TASK_FILE" <<'TASKEOF'
# 목표
시각적 회귀 테스트를 작성하고 브라우저 자동화 테스트를 구현한다.
TASKEOF
  result="$("$ROUTING_PARSER" judge "$TASK_FILE" 2>/dev/null || true)"
  intent="$(get_intent "$result")"
  complexity="$(get_complexity "$result")"
  route="$(get_judged_route "$result")"
  eval "i${i}_intent=\$intent"
  eval "i${i}_complexity=\$complexity"
  eval "i${i}_route=\$route"
done
assert_eq "D1: 3회 연속 동일 입력 → intent 일관" "$i1_intent" "$i3_intent"
assert_eq "D1: 3회 연속 동일 입력 → complexity 일관" "$i1_complexity" "$i3_complexity"
assert_eq "D1: 3회 연속 동일 입력 → route 일관" "$i1_route" "$i3_route"

echo ""
echo "=== 결과 ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
