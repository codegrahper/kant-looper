#!/usr/bin/env bash
# routing-parser.sh — TASK 키워드 → 도구/모델 매핑
#
# 판정 규칙의 SSOT는 코드: intent/complexity 규칙은 judge_task_routing()
# (lines 248-541), classify_task_intent(), estimate_complexity()에 Bash grep
# 패턴으로 구현. 가이드 문서에서 파싱하는 것은 **모델명만** (parse_routing_guide,
# lines 45-94): gpt-5.6-luna/terra/sol, glm-5.2, grok-4.5, gemini-3.5-flash.
# 가이드의 모델명 갱신 시 KANT_PRIMARY_* 변수가 자동 반영되는 구조.
# intent·complexity·route 결정 규칙을 바꾸려면 코드를 수정할 것.
#
# bash 3.2 호환 (macOS 기본 bash). associative array 사용 안 함.
# 출처: codex-agent-loop-v4.sh:extract_json_object 패턴 + routing 가이드 8절.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 경로 상수
# ---------------------------------------------------------------------------

# 이 스크립트 위치 기준 부모 디렉터리 = skill 루트
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
REFERENCES_DIR="$SKILL_ROOT/references"
ROUTING_GUIDE="$REFERENCES_DIR/multimodel-coding-agent-routing-guide.md"

# ---------------------------------------------------------------------------
# 가이드 파싱 캐시
# ---------------------------------------------------------------------------

# 캐시 디렉터리 (state 영역 안에 둠)
CACHE_DIR="${KANT_STATE_DIR:-$HOME/.claude/state/kant-looper/.cache}"
mkdir -p "$CACHE_DIR"
GUIDE_CACHE="$CACHE_DIR/parsed-guide.sh"
GUIDE_HASH_FILE="$CACHE_DIR/guide.hash"

# 가이드 파일 mtime 기반 캐시 무효화
_guide_is_fresh() {
  [ -f "$GUIDE_CACHE" ] && [ -f "$GUIDE_HASH_FILE" ] || return 1
  local current_hash
  current_hash="$(shasum -a 256 "$ROUTING_GUIDE" 2>/dev/null | cut -d' ' -f1 || true)"
  if [ -z "$current_hash" ]; then
    return 1
  fi
  local cached_hash
  cached_hash="$(cat "$GUIDE_HASH_FILE" 2>/dev/null || true)"
  [ "$current_hash" = "$cached_hash" ]
}

parse_routing_guide() {
  if _guide_is_fresh; then
    # shellcheck source=/dev/null
    . "$GUIDE_CACHE"
    return 0
  fi

  if [ ! -f "$ROUTING_GUIDE" ]; then
    echo "WARN: routing-guide.md not found: $ROUTING_GUIDE" >&2
    return 1
  fi

  local primary_luna primary_terra primary_sol primary_glm52 primary_grok45 primary_gemini35flash
  local model_kant_minimax

  primary_luna="$(grep -E 'gpt-5\.6-luna' "$ROUTING_GUIDE" | head -1 | grep -oE 'gpt-5\.6-luna' || echo 'gpt-5.6-luna')"
  primary_terra="$(grep -E 'gpt-5\.6-terra' "$ROUTING_GUIDE" | head -1 | grep -oE 'gpt-5\.6-terra' || echo 'gpt-5.6-terra')"
  primary_sol="$(grep -E 'gpt-5\.6-sol' "$ROUTING_GUIDE" | head -1 | grep -oE 'gpt-5\.6-sol' || echo 'gpt-5.6-sol')"
  primary_glm52="$(grep -E 'glm-5\.2[^.]' "$ROUTING_GUIDE" | head -1 | grep -oE 'glm-5\.2' || echo 'glm-5.2')"
  primary_grok45="$(grep -E 'grok-4\.5' "$ROUTING_GUIDE" | head -1 | grep -oE 'grok-4\.5' || echo 'grok-4.5')"
  primary_gemini35flash="$(grep -E 'gemini-3\.5-flash' "$ROUTING_GUIDE" | head -1 | grep -oE 'gemini-3\.5-flash' || echo 'gemini-3.5-flash')"
  model_kant_minimax="default"

  # 캐시 파일 생성
  cat > "$GUIDE_CACHE" <<EOF
# Auto-generated from routing-guide.md. DO NOT EDIT.
# 갱신: /kant-looper update-guide 또는 routing-parser.sh refresh
KANT_PRIMARY_LUNA="$primary_luna"
KANT_PRIMARY_TERRA="$primary_terra"
KANT_PRIMARY_SOL="$primary_sol"
KANT_PRIMARY_GLM52="$primary_glm52"
KANT_PRIMARY_GROK45="$primary_grok45"
KANT_PRIMARY_GEMINI35FLASH="$primary_gemini35flash"
KANT_CLAUDE_MODEL="default"

KANT_ROUTE_TINY_PRIMARY="codex:$primary_luna"
KANT_ROUTE_STANDARD_PRIMARY="codex:$primary_terra"
KANT_ROUTE_HARD_PRIMARY="codex:$primary_sol"
KANT_ROUTE_HUGE_PRIMARY="opencode:$primary_glm52"
KANT_ROUTE_VISUAL_PRIMARY="agy:$primary_gemini35flash"
KANT_ROUTE_VISUAL_HARNESS="antigravity"
KANT_ROUTE_REVIEW_PRIMARY="codex:$primary_sol"
KANT_ROUTE_REVIEW_RULE="provider_must_differ_from_implementer"
EOF

  shasum -a 256 "$ROUTING_GUIDE" | cut -d' ' -f1 > "$GUIDE_HASH_FILE"

  # shellcheck source=/dev/null
  . "$GUIDE_CACHE"
}

# 강제 갱신 (update-guide 서브커맨드에서 호출)
refresh_routing_guide() {
  rm -f "$GUIDE_CACHE" "$GUIDE_HASH_FILE"
  parse_routing_guide
}

# ---------------------------------------------------------------------------
# intent × complexity → route 이름 매핑
# ---------------------------------------------------------------------------

_intent_to_route() {
  local intent="$1"
  case "$intent" in
    test)     echo "tiny" ;;
    ui)       echo "visual" ;;
    review)   echo "review" ;;
    refactor) echo "huge" ;;
    debug|docs|cli|research|implement|"") echo "standard" ;;
    *)        echo "standard" ;;
  esac
}

# ---------------------------------------------------------------------------
# route 이름 + tier → tool:model 반환
# ---------------------------------------------------------------------------

_get_route_candidate() {
  local route="$1" tier="$2"
  parse_routing_guide

  if [ "${KANT_ROUTING_SOURCE:-hardcode}" = "ssot" ] && [ -f "$LIB_DIR/ssot-shadow.sh" ]; then
    source "$LIB_DIR/ssot-shadow.sh"
    local ssot_primary
    ssot_primary="$(ssot_resolve_route_primary "${route%_repo}" 2>/dev/null || true)"
    if [ -n "$ssot_primary" ]; then
      echo "$ssot_primary"
      return 0
    fi
  fi

  local route_key="${route%_repo}"
  local route_uc
  route_uc="$(printf '%s' "$route_key" | tr '[:lower:]' '[:upper:]')"
  local primary="KANT_ROUTE_${route_uc}_PRIMARY"

  local val
  val="$(eval "echo \$$primary" 2>/dev/null || true)"
  if [ -n "$val" ]; then
    echo "$val"
    return 0
  fi

  echo "codex:${KANT_PRIMARY_TERRA}"
}

# ---------------------------------------------------------------------------
# tool + model 유효성 검증
# ---------------------------------------------------------------------------

is_official_minimax_model() {
  case "$1" in
    MiniMax-M3|MiniMax-M2.7|MiniMax-M2.7-highspeed)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

model_basename() {
  local value="$1"
  value="${value##*:}"
  value="${value##*/}"
  printf '%s\n' "$value"
}

is_model_valid() {
  local tool="$1" model="$2"
  local bare_model
  bare_model="$(model_basename "$model")"
  case "$tool" in
    codex)
      echo "$bare_model" | grep -qE '^gpt-5\.' && return 0
      ;;
    opencode)
      case "$bare_model" in
        glm-5.2|glm-4.7)
          return 0
          ;;
      esac
      if is_official_minimax_model "$bare_model"; then
        return 0
      fi
      ;;
    grok)
      echo "$bare_model" | grep -qE '^grok-' && return 0
      ;;
    agy)
      echo "$bare_model" | grep -qE '^gemini-' && return 0
      ;;
    claude)
      [ "$bare_model" = "default" ] && return 0
      ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# tool 가용성 검증
# ---------------------------------------------------------------------------

is_tool_available() {
  local tool="$1"
  "$LIB_DIR/health-check.sh" tool "$tool" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# tool 가용성 + model 유효성 검증
# ---------------------------------------------------------------------------

_validate_candidate() {
  local candidate="$1"
  local tool="${candidate%%:*}"
  local model="${candidate#*:}"

  if ! is_tool_available "$tool"; then
    return 1
  fi

  if ! is_model_valid "$tool" "$model"; then
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# fallback chain에서 첫 번째 유효한 후보 선택
# ---------------------------------------------------------------------------

_select_valid_fallback() {
  local fb_chain="$1"  # comma-separated "tool:model,tool:model,..."
  local IFS=','
  set -f
  set -- $fb_chain
  set +f

  for candidate in "$@"; do
    if _validate_candidate "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 단일 판정 함수: intent + complexity + route + reason을 한 번에 계산
# Evidence scoring 방식 - 단일 키워드 매칭이 아닌 신호 점수화
# ---------------------------------------------------------------------------

judge_task_routing() {
  local task_file="${1:-}"

  if [ -z "$task_file" ] || [ ! -f "$task_file" ]; then
    echo "ERROR: judge_task_routing requires a valid task file" >&2
    return 1
  fi

  local task_text task_lc
  task_text="$(cat "$task_file" 2>/dev/null || true)"
  task_lc="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"

  # ------------------------------------------------------------
  # 신호 점수 계산 (양수=긍정, 음수=부정)
  # ------------------------------------------------------------

  # UI 신호
  local ui_score=0
  local ui_signals=""
  local ui_neg_signals=""

  # 강한 긍정 신호 (+3)
  if printf '%s' "$task_lc" | grep -qE '접근성|웹 접근성|a11y|accessibility'; then
    ui_score=$((ui_score + 3))
    ui_signals="${ui_signals},accessibility"
  fi
  if printf '%s' "$task_lc" | grep -qE 'visual regression|시각적 회귀|screenshot|스크린샷|브라우저 렌더링|browser rendering'; then
    ui_score=$((ui_score + 3))
    ui_signals="${ui_signals},visual-regression"
  fi
  if printf '%s' "$task_lc" | grep -qE '브라우저 자동화|browser automation|computer use|computer-use'; then
    ui_score=$((ui_score + 3))
    ui_signals="${ui_signals},browser-automation"
  fi

  # 중간 긍정 신호 (+2)
  if printf '%s' "$task_lc" | grep -qE 'css|layout|component|frontend|ui |tailwind|modal|drawer|screen|stitch'; then
    ui_score=$((ui_score + 2))
    ui_signals="${ui_signals},css-layout-component"
  fi

  # 강한 부정 신호 (-3): 파일/디렉터리 접근 권한 문맥
  if printf '%s' "$task_lc" | grep -qE '파일 접근|파일 권한|directory permission|file permission|접근 허용|접근 제어|권한 확인|permission check'; then
    ui_score=$((ui_score - 3))
    ui_neg_signals="${ui_neg_signals},file-permission-context"
  fi

  # 중간 부정 신호 (-2): CLI/Bash/Adapter 문맥
  if printf '%s' "$task_lc" | grep -qE 'bash|shell|adapter|parser|routing|cli '; then
    ui_score=$((ui_score - 2))
    ui_neg_signals="${ui_neg_signals},cli-adapter-context"
  fi

  # DEBUG 신호
  local debug_score=0
  local debug_signals=""

  # 강한 긍정 신호 (+3)
  if printf '%s' "$task_lc" | grep -qE '버그|bug|오류|error|에러|장애|fail|broken|재현|reproduce|수정|fix'; then
    debug_score=$((debug_score + 3))
    debug_signals="${debug_signals},bug-error-fix"
  fi

  # 중간 긍정 신호 (+2)
  if printf '%s' "$task_lc" | grep -qE 'parser|routing|regression|회귀|adapter|expect.*actual|actual.*expect'; then
    debug_score=$((debug_score + 2))
    debug_signals="${debug_signals},parser-routing-regression"
  fi

  # REFACTOR 신호
  local refactor_score=0
  local refactor_signals=""

  # 강한 긍정 신호 (+3)
  if printf '%s' "$task_lc" | grep -qE '리팩터|refactor|공통화|중복 제거|duplicate removal|refactor'; then
    refactor_score=$((refactor_score + 3))
    refactor_signals="${refactor_signals},refactor-commonize"
  fi

  # 중간 긍정 신호 (+2)
  if printf '%s' "$task_lc" | grep -qE '함수 추출|extract function|structure 개선|restructure|migration|migrate|마이그레이션|cleanup'; then
    refactor_score=$((refactor_score + 2))
    refactor_signals="${refactor_signals},extract-restructur-migration"
  fi

  # TEST 신호
  local test_score=0
  local test_signals=""

  # 강한 긍정 신호 (+3): 테스트 작성/추가
  if printf '%s' "$task_lc" | grep -qE '테스트 작성|테스트 추가|테스트 생성|테스트 구현|unit test|write test|add test|create test|테스트만|fixture|mock|snapshot'; then
    test_score=$((test_score + 3))
    test_signals="${test_signals},test-creation"
  fi

  # REVIEW 신호
  local review_score=0
  local review_signals=""

  # 강한 긍정 신호 (+3)
  if printf '%s' "$task_lc" | grep -qE '리뷰|review|검증|verify|감사|audit|inspect|점검'; then
    review_score=$((review_score + 3))
    review_signals="${review_signals},review-audit"
  fi

  # DOCS 신호
  local docs_score=0
  local docs_signals=""

  if printf '%s' "$task_lc" | grep -qE '문서|주석|readme|문서화|docs?|comment'; then
    docs_score=$((docs_score + 2))
    docs_signals="${docs_signals},docs-comment"
  fi

  # CLI 신호
  local cli_score=0
  local cli_signals=""

  if printf '%s' "$task_lc" | grep -qE '터미널|terminal|cli |shell|bash|zsh|^rust|c\+\+|system|kernel'; then
    cli_score=$((cli_score + 2))
    cli_signals="${cli_signals},terminal-system"
  fi

  # RESEARCH 신호
  local research_score=0
  local research_signals=""

  if printf '%s' "$task_lc" | grep -qE '조사|분석|탐색|research|investigate|analyze|explore'; then
    research_score=$((research_score + 2))
    research_signals="${research_signals},research-analyze"
  fi

  # ------------------------------------------------------------
  # UI 안전장치: 강한 신호 없으면 UI 선택 안 함
  # ------------------------------------------------------------
  local has_strong_ui_signal=0
  if printf '%s' "$task_lc" | grep -qE '접근성|웹 접근성|a11y|accessibility|visual regression|시각적 회귀|screenshot|스크린샷|브라우저 렌더링|browser rendering|브라우저 자동화|browser automation|computer use'; then
    has_strong_ui_signal=1
  fi

  if [ "$has_strong_ui_signal" = "0" ] && [ "$ui_score" -lt 3 ]; then
    ui_score=0
  fi

  # ------------------------------------------------------------
  # Intent 선택 (최고 점수, 동점이면 규칙 적용)
  # ------------------------------------------------------------

  local primary_intent="implement"
  local secondary_intents=""
  local best_score=0

  # 점수 비교
  if [ "$debug_score" -gt "$best_score" ]; then
    best_score=$debug_score; primary_intent="debug"
  fi
  if [ "$refactor_score" -gt "$best_score" ]; then
    best_score=$refactor_score; primary_intent="refactor"
  fi
  if [ "$test_score" -gt "$best_score" ]; then
    best_score=$test_score; primary_intent="test"
  fi
  if [ "$review_score" -gt "$best_score" ]; then
    best_score=$review_score; primary_intent="review"
  fi
  if [ "$docs_score" -gt "$best_score" ]; then
    best_score=$docs_score; primary_intent="docs"
  fi
  if [ "$cli_score" -gt "$best_score" ]; then
    best_score=$cli_score; primary_intent="cli"
  fi
  if [ "$research_score" -gt "$best_score" ]; then
    best_score=$research_score; primary_intent="research"
  fi
  if [ "$ui_score" -gt "$best_score" ]; then
    best_score=$ui_score; primary_intent="ui"
  fi

  # 동점 처리: 점수가 0보다 클 때만 적용 (모두 0이면 implement 유지)
  if [ "$best_score" -gt 0 ]; then
    if [ "$debug_score" -eq "$best_score" ] && [ "$primary_intent" != "debug" ]; then
      case "$primary_intent" in
        implement|research|cli) primary_intent="debug" ;;
      esac
    fi
    if [ "$refactor_score" -eq "$best_score" ] && [ "$primary_intent" != "refactor" ]; then
      case "$primary_intent" in
        implement|research|cli) primary_intent="refactor" ;;
      esac
    fi
    # Strong UI signal beats test when tied
    if [ "$ui_score" -eq "$best_score" ] && [ "$primary_intent" = "test" ] && [ "$has_strong_ui_signal" = "1" ]; then
      primary_intent="ui"
    fi
  fi

  # bash/cli context: cli_score captures both; preserve explicit intent over context override

  # secondary signals 수집
  local all_signals=""
  [ -n "$debug_signals" ] && all_signals="${all_signals}${debug_signals}"
  [ -n "$refactor_signals" ] && all_signals="${all_signals}${refactor_signals}"
  [ -n "$test_signals" ] && all_signals="${all_signals}${test_signals}"
  [ -n "$review_signals" ] && all_signals="${all_signals}${review_signals}"
  [ -n "$ui_signals" ] && all_signals="${all_signals}${ui_signals}"
  [ -n "$docs_signals" ] && all_signals="${all_signals}${docs_signals}"
  [ -n "$cli_signals" ] && all_signals="${all_signals}${cli_signals}"
  [ -n "$research_signals" ] && all_signals="${all_signals}${research_signals}"

  # secondary intents 추출 (primary 제외)
  local secondary_list=""
  [ "$primary_intent" != "debug" ] && [ "$debug_score" -gt 0 ] && secondary_list="${secondary_list},debug"
  [ "$primary_intent" != "refactor" ] && [ "$refactor_score" -gt 0 ] && secondary_list="${secondary_list},refactor"
  [ "$primary_intent" != "test" ] && [ "$test_score" -gt 0 ] && secondary_list="${secondary_list},test"
  [ "$primary_intent" != "review" ] && [ "$review_score" -gt 0 ] && secondary_list="${secondary_list},review"
  [ "$primary_intent" != "ui" ] && [ "$ui_score" -gt 0 ] && secondary_list="${secondary_list},ui"

  # ------------------------------------------------------------
  # Complexity 판정 (구조적 신호 우선)
  # ------------------------------------------------------------

  local complexity="T1"

  # T4: 1M 컨텍스트 / 대형 저장소 / 장기 / 다중 시스템
  if printf '%s' "$task_lc" | grep -qE '1m[-[:space:]]*(context|컨텍스트)|huge|large repo|large repository|entire codebase|대형 저장소|전체 코드베이스|장기|다중 시스템|architecture|architectural|아키텍처|설계 변경'; then
    complexity="T4"
  # T3: 저장소 전체 / 다수 독립 서브시스템 / 공개 인터페이스 변경 / 마이그레이션
  elif printf '%s' "$task_lc" | grep -qE '전체[[:space:]]+(저장소|코드베이스)|저장소[[:space:]]+전체|(entire|whole)[[:space:]]+(repository|repo|codebase)|(repository|repo|codebase)[[:space:]]+(wide|전체)|리팩터|마이그레이션|restructure|migrate'; then
    complexity="T3"
  # T2: 여러 파일 / 여러 모듈 / 설계 판단
  elif printf '%s' "$task_lc" | grep -qE '여러|several|multiple|across[[:space:]]+(multiple|several|[0-9]+|files?|modules?|components?|repository|repo|codebase)|integration|integrate|연동|통합|설계'; then
    complexity="T2"
  # T0: 읽기 / 요약 / 추출 / 정형 변환
  elif printf '%s' "$task_lc" | grep -qE '읽기|요약|추출|정형|변환|read |summary|extract|transform|간단|small'; then
    complexity="T0"
  else
    complexity="T1"
  fi

  # ------------------------------------------------------------
  # Route 결정
  # ------------------------------------------------------------

  local route_name
  case "$primary_intent" in
    test)     route_name="tiny" ;;
    ui)       route_name="visual" ;;
    review)   route_name="review" ;;
    refactor) route_name="huge" ;;
    debug|docs|cli|research|implement|"") route_name="standard" ;;
    *)        route_name="standard" ;;
  esac

  # complexityOverride for T3/T4
  if [ "$complexity" = "T4" ]; then
    route_name="huge"
  elif [ "$complexity" = "T3" ]; then
    case "$primary_intent" in
      implement|debug|research) route_name="hard" ;;
    esac
  fi

  # route candidate 가져오기
  parse_routing_guide
  local candidate="$(_get_route_candidate "$route_name" "primary")"

  # ------------------------------------------------------------
  # 출력 형식
  # ------------------------------------------------------------

  # reason 문자열 구성
  local reason_str="intent:${primary_intent};complexity:${complexity};route:${route_name}"
  if [ -n "$all_signals" ]; then
    # 첫 번째 쉼표 제거
    reason_str="${reason_str};signals:${all_signals#,}"
  fi
  if [ -n "$secondary_list" ]; then
    reason_str="${reason_str};secondary:${secondary_list#,}"
  fi

  # judge_task_routing 레벨에서는 health check 없음
  # effective_route = judged_route (health check는 실행 시 수행)
  local effective_route="$candidate"
  local fb_reason=""

  # 현재 judge 레벨에서는 health check/fallback 없음
  # future: health check 실패 시 fallback 적용 로직 추가 가능

  # 기계 판독 가능한 출력
  printf 'intent=%s\n' "$primary_intent"
  printf 'complexity=%s\n' "$complexity"
  printf 'judged_route=%s\n' "$candidate"
  printf 'effective_route=%s\n' "$effective_route"
  printf 'fallback_reason=%s\n' "$fb_reason"
  printf 'reason=%s\n' "$reason_str"
}

# ---------------------------------------------------------------------------
# 메타 에이전트 판단 기반 라우팅 (judge_task_routing으로 통합)
# ---------------------------------------------------------------------------

match_with_judgment() {
  # --intent and --complexity arguments are now ignored (calculated internally)
  # maintained for backward compatibility
  local task_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --intent=*|--complexity=*) ;;  # ignore, judge_task_routing calculates
      *)
        if [ -z "$task_file" ]; then task_file="$1"; fi ;;
    esac
    shift
  done

  if [ -z "$task_file" ]; then
    echo "ERROR: task file required" >&2
    return 1
  fi

  judge_task_routing "$task_file"
}

classify_task_intent() {
  local task_file="$1"
  local task_text task_lc
  task_text="$(cat "$task_file" 2>/dev/null || true)"
  task_lc="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$task_lc" | grep -qE 'ui |component|screen|stitch|modal|drawer|tailwind|css|frontend|접근성|a11y|accessibility|사용자 인터페이스'; then
    echo "ui"
  elif printf '%s' "$task_lc" | grep -qE '리뷰|검증|감사|review|verify|audit|inspect|점검'; then
    echo "review"
  elif printf '%s' "$task_lc" | grep -qE '리팩터|마이그레이션|대규모|cleanup|restructure|refactor|migrate|rewrite'; then
    echo "refactor"
  elif printf '%s' "$task_lc" | grep -qE '테스트 (작성|추가|생성|만들|구현)|^test | unit test|테스트만|테스트만 추가|fixture|mock|snapshot'; then
    echo "test"
  elif printf '%s' "$task_lc" | grep -qE '버그|오류|수정|fix|debug|broken|fail|에러|장애'; then
    echo "debug"
  elif printf '%s' "$task_lc" | grep -qE '문서|주석|readme|문서화|docs?|comment'; then
    echo "docs"
  elif printf '%s' "$task_lc" | grep -qE '터미널|cli |shell|bash|zsh|^rust|c\+\+|system|kernel'; then
    echo "cli"
  elif printf '%s' "$task_lc" | grep -qE '조사|분석|탐색|research|investigate|analyze|explore'; then
    echo "research"
  else
    echo "implement"
  fi
}

estimate_complexity() {
  local task_file="$1"
  local task_text task_lc
  task_text="$(cat "$task_file" 2>/dev/null || true)"
  task_lc="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$task_lc" | grep -qE '1m[-[:space:]]*(context|컨텍스트)|huge|large repo|large repository|entire codebase|대형 저장소|전체 코드베이스|장기|다중 시스템|architecture|architectural|아키텍처|설계 변경'; then
    echo "T4"
  elif printf '%s' "$task_lc" | grep -qE '전체[[:space:]]+(저장소|코드베이스)|저장소[[:space:]]+전체|(entire|whole)[[:space:]]+(repository|repo|codebase)|(repository|repo|codebase)[[:space:]]+(wide|전체)|리팩터|마이그레이션|restructure|migrate'; then
    echo "T3"
  elif printf '%s' "$task_lc" | grep -qE '여러|several|multiple|across[[:space:]]+(multiple|several|[0-9]+|files?|modules?|components?|repository|repo|codebase)|integration|integrate|연동|통합|설계'; then
    echo "T2"
  elif printf '%s' "$task_lc" | grep -qE '읽기|요약|추출|정형|변환|read |summary|extract|transform|간단|small'; then
    echo "T0"
  else
    echo "T1"
  fi
}

# ---------------------------------------------------------------------------
# TASK 키워드 → 라우트 매핑
# ---------------------------------------------------------------------------

match_task_to_route() {
  local task_file="$1"
  parse_routing_guide

  if [ ! -f "$task_file" ]; then
    echo "${KANT_DEFAULT_TOOL:-codex}:${KANT_DEFAULT_MODEL:-$KANT_PRIMARY_TERRA}"
    return 0
  fi

  local task_text
  task_text="$(cat "$task_file" 2>/dev/null || true)"
  local task_lc
  task_lc="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"

  # UI / 시각
  if printf '%s' "$task_lc" | grep -qE 'ui |component|screen|stitch|modal|drawer|tailwind|css|frontend|접근|사용자 인터페이스'; then
    echo "agy:${KANT_PRIMARY_GEMINI35FLASH}"
    return 0
  fi

  # 테스트
  if printf '%s' "$task_lc" | grep -qE ' unit test|^test |테스트 작성|테스트 추가|fixture|mock|snapshot'; then
    echo "codex:${KANT_PRIMARY_LUNA}"
    return 0
  fi

  # 대형 리팩터링 / 마이그레이션
  if printf '%s' "$task_lc" | grep -qE 'refactor|migrate|rewrite|restructure|cleanup|대규모|마이그레이션|리팩터'; then
    echo "opencode:${KANT_PRIMARY_GLM52}"
    return 0
  fi

  # 터미널 / 시스템
  if printf '%s' "$task_lc" | grep -qE 'terminal|cli |shell|bash|zsh|^rust|c\+\+|system|kernel'; then
    echo "grok:${KANT_PRIMARY_GROK45}"
    return 0
  fi

  # 리뷰 / 검증
  if printf '%s' "$task_lc" | grep -qE 'review|verify|audit|check |validate|검증|리뷰|감사'; then
    echo "codex:${KANT_PRIMARY_SOL}"
    return 0
  fi

  # 대규모 컨텍스트
  if printf '%s' "$task_lc" | grep -qE '1m|huge|large repo|entire codebase|대형 저장소'; then
    echo "opencode:${KANT_PRIMARY_GLM52}"
    return 0
  fi

  # 기본
  echo "codex:${KANT_PRIMARY_TERRA}"
}

# ---------------------------------------------------------------------------
# 여러 도구 동시 호출용 슬라이싱 (--parallel)
# ---------------------------------------------------------------------------

slice_task_for_parallel() {
  local task_file="$1"
  parse_routing_guide
  local task_text task_lc
  task_text="$(cat "$task_file" 2>/dev/null || true)"
  task_lc="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"

  local has_ui has_logic has_review
  has_ui=$(printf '%s' "$task_lc" | grep -cE 'ui |component|screen|stitch|modal|css|frontend' || true)
  has_logic=$(printf '%s' "$task_lc" | grep -cE 'logic|algorithm|compute|로직|알고리즘' || true)
  has_review=$(printf '%s' "$task_lc" | grep -cE 'review|verify|audit|test|검증|테스트' || true)

  local parts=""
  if [ "${has_ui:-0}" -gt 0 ] 2>/dev/null; then
    parts="agy:${KANT_PRIMARY_GEMINI35FLASH}"
  fi
  if [ "${has_logic:-0}" -gt 0 ] 2>/dev/null; then
    if [ -n "$parts" ]; then parts="${parts},"; fi
    parts="${parts}opencode:${KANT_PRIMARY_GLM52}"
  fi
  if [ "${has_review:-0}" -gt 0 ] 2>/dev/null; then
    if [ -n "$parts" ]; then parts="${parts},"; fi
    parts="${parts}codex:${KANT_PRIMARY_SOL}"
  fi
  if [ -z "$parts" ]; then
    parts="codex:${KANT_PRIMARY_TERRA},opencode:${KANT_PRIMARY_GLM52}"
  fi

  echo "$parts"
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "refresh" ]; then
  shift
  refresh_routing_guide
  echo "routing guide refreshed from $ROUTING_GUIDE"
  exit 0
fi

if [ "${1:-}" = "match" ]; then
  shift
  judge_task_routing "$@"
  exit 0
fi

if [ "${1:-}" = "slice" ]; then
  shift
  slice_task_for_parallel "$@"
  exit 0
fi

if [ "${1:-}" = "match-with-judgment" ]; then
  shift
  match_with_judgment "$@"
  exit 0
fi

if [ "${1:-}" = "judge" ]; then
  shift
  judge_task_routing "$@"
  exit 0
fi

if [ "${1:-}" = "classify-intent" ]; then
  shift
  classify_task_intent "$@"
  exit 0
fi

if [ "${1:-}" = "estimate-complexity" ]; then
  shift
  estimate_complexity "$@"
  exit 0
fi

if [ "${1:-}" = "is-available" ]; then
  shift
  if is_tool_available "$@"; then
    echo "available"
    exit 0
  else
    echo "unavailable"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# CLI: validate-model <tool> <model>
# ---------------------------------------------------------------------------

case "${1:-}" in
  validate-model)
    shift
    tool="$1"; model="$2"
    if [ -z "$tool" ] || [ -z "$model" ]; then
      echo "Usage: routing-parser.sh validate-model <tool> <model>" >&2
      exit 1
    fi
    if is_model_valid "$tool" "$model"; then
      exit 0
    else
      exit 1
    fi
    ;;
esac

# 직접 실행 시: 가이드 파싱 후 핵심 변수 dump
if [ "${1:-}" = "dump" ] || [ "${1:-}" = "" ]; then
  parse_routing_guide
  cat <<EOF
KANT_PRIMARY_LUNA=$KANT_PRIMARY_LUNA
KANT_PRIMARY_TERRA=$KANT_PRIMARY_TERRA
KANT_PRIMARY_SOL=$KANT_PRIMARY_SOL
KANT_PRIMARY_GLM52=$KANT_PRIMARY_GLM52
KANT_PRIMARY_GROK45=$KANT_PRIMARY_GROK45
KANT_PRIMARY_GEMINI35FLASH=$KANT_PRIMARY_GEMINI35FLASH
KANT_CLAUDE_MODEL=$KANT_CLAUDE_MODEL
EOF
  exit 0
fi

# 인자 없이 실행 시 도움말
cat <<EOF
routing-parser.sh — 라우팅 가이드 동적 파싱

사용법:
  routing-parser.sh dump                       # 가이드에서 추출한 핵심 변수 dump
  routing-parser.sh refresh                    # 캐시 강제 갱신
  routing-parser.sh match TASK.md              # TASK.md → 단일 도구:모델
  routing-parser.sh slice TASK.md              # TASK.md → 병렬 호출 리스트
  routing-parser.sh match-with-judgment TASK.md --intent=<I> --complexity=<T>
                                                # 메타 에이전트 판단 기반 라우팅
                                                # --intent: implement|test|review|refactor|ui|debug|docs|research|cli
                                                # --complexity: T0|T1|T2|T3|T4
  routing-parser.sh classify-intent TASK.md    # 작업 의도 분류
  routing-parser.sh estimate-complexity TASK.md  # 작업 복잡도 추정
  routing-parser.sh is-available <tool>        # 도구 가용성 확인

가이드 위치: $ROUTING_GUIDE
EOF
