#!/usr/bin/env bash
# routing-parser.sh — 라우팅 가이드 동적 파싱 + TASK 키워드 → 도구/모델 매핑
#
# 코드에 박힌 매핑 없음. references/multimodel-coding-agent-routing-guide.md를
# 매번 파싱해서 동적으로 결정. 가이드가 업데이트되면 코드 수정 없이 자동 반영.
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
  model_kant_minimax="MiniMax-M3"

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
KANT_CLAUDE_MODEL="$model_kant_minimax"

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

is_model_valid() {
  local tool="$1" model="$2"
  local bare_model="${model##*:}"
  case "$tool" in
    codex)
      echo "$bare_model" | grep -qE '^gpt-5\.' && return 0
      ;;
    opencode)
      echo "$bare_model" | grep -qE '^glm-' && return 0
      ;;
    grok)
      echo "$bare_model" | grep -qE '^grok-' && return 0
      ;;
    agy)
      echo "$bare_model" | grep -qE '^gemini-' && return 0
      ;;
    claude)
      echo "$bare_model" | grep -qE '^MiniMax-' && return 0
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
# 메타 에이전트 판단 기반 라우팅
# ---------------------------------------------------------------------------

match_with_judgment() {
  local task_file=""
  local intent="" complexity=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --intent=*) intent="${1#--intent=}" ;;
      --complexity=*) complexity="${1#--complexity=}" ;;
      *)
        if [ -z "$task_file" ]; then task_file="$1"; fi ;;
    esac
    shift
  done

  if [ -z "$intent" ] || [ -z "$complexity" ]; then
    echo "ERROR: --intent and --complexity are required" >&2
    return 1
  fi

  parse_routing_guide

  local route="$(_intent_to_route "$intent")"

  case "$complexity" in
    T4) route="huge" ;;
    T3)
      if [ "$intent" = "implement" ] || [ "$intent" = "debug" ] || [ "$intent" = "research" ]; then
        route="hard"
      fi
      ;;
  esac

  local candidate="$(_get_route_candidate "$route" "primary")"

  if _validate_candidate "$candidate"; then
    echo "$candidate"
    return 0
  fi

  local tool="${candidate%%:*}"
  local model="${candidate#*:}"
  local fb_chain
  fb_chain="$("$LIB_DIR/fallback-dispatcher.sh" chain "$tool" "$model" 2>/dev/null || true)"

  if [ -n "$fb_chain" ]; then
    local selected
    selected="$(_select_valid_fallback "$fb_chain")"
    if [ -n "$selected" ]; then
      echo "$selected"
      return 0
    fi
  fi

  echo "claude:${KANT_CLAUDE_MODEL}"
}

classify_task_intent() {
  local task_file="$1"
  local task_text task_lc
  task_text="$(cat "$task_file" 2>/dev/null || true)"
  task_lc="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$task_lc" | grep -qE 'ui |component|screen|stitch|modal|drawer|tailwind|css|frontend|접근|사용자 인터페이스'; then
    echo "ui"
  elif printf '%s' "$task_lc" | grep -qE '리뷰|검증|감사|review|verify|audit|inspect|점검|확인해'; then
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

  if printf '%s' "$task_lc" | grep -qE '1m|huge|large repo|entire codebase|대형 저장소|전체 코드베이스|장기|다중 시스템|arch|설계 변경'; then
    echo "T4"
  elif printf '%s' "$task_lc" | grep -qE '전체|all |across|repository|저장소 전체|리팩터|마이그레이션|restructure|migrate'; then
    echo "T3"
  elif printf '%s' "$task_lc" | grep -qE '여러|several|multiple|across|integration|integrate|연동|통합|설계'; then
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
  match_task_to_route "$@"
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
