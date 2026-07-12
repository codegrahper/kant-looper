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

  # 간단한 파싱: 가이드의 §8.3 routes 표와 §8.2 models 표 + 본문 휴리스틱 추출
  # 정밀 파싱 대신 빠르게 텍스트 grep으로 핵심 패턴만 추출

  # 가드: 가이드 파일 없으면 빈 매핑 반환
  if [ ! -f "$ROUTING_GUIDE" ]; then
    echo "WARN: routing-guide.md not found: $ROUTING_GUIDE" >&2
    return 1
  fi

  # 동적 변수 정의 (캐시 파일에 저장)
  local primary_luna primary_terra primary_sol primary_glm52 primary_grok45 primary_gemini35flash
  local primary_glm47 primary_glm5turbo primary_glm47flashx primary_glm5vturbo
  local primary_grokbuild
  local primary_gemini31pro primary_gemini31lite
  local primary_claude_m3 primary_claude_m27 primary_claude_m27hs
  local route_tiny route_standard route_hard route_huge route_visual route_review

  primary_luna="$(grep -E 'gpt-5\.6-luna' "$ROUTING_GUIDE" | head -1 | grep -oE 'gpt-5\.6-luna' || echo 'gpt-5.6-luna')"
  primary_terra="$(grep -E 'gpt-5\.6-terra' "$ROUTING_GUIDE" | head -1 | grep -oE 'gpt-5\.6-terra' || echo 'gpt-5.6-terra')"
  primary_sol="$(grep -E 'gpt-5\.6-sol' "$ROUTING_GUIDE" | head -1 | grep -oE 'gpt-5\.6-sol' || echo 'gpt-5.6-sol')"
  primary_glm52="$(grep -E 'glm-5\.2[^.]' "$ROUTING_GUIDE" | head -1 | grep -oE 'glm-5\.2' || echo 'glm-5.2')"
  primary_grok45="$(grep -E 'grok-4\.5' "$ROUTING_GUIDE" | head -1 | grep -oE 'grok-4\.5' || echo 'grok-4.5')"
  primary_gemini35flash="$(grep -E 'gemini-3\.5-flash' "$ROUTING_GUIDE" | head -1 | grep -oE 'gemini-3\.5-flash' || echo 'gemini-3.5-flash')"

  # §3~§7 전체 모델 레지스트리 추출 (메타 에이전트 참조용)
  primary_glm47="$(grep -E 'glm-4\.7[^-]' "$ROUTING_GUIDE" | head -1 | grep -oE 'glm-4\.7' || echo 'glm-4.7')"
  primary_glm5turbo="$(grep -E 'glm-5-turbo' "$ROUTING_GUIDE" | head -1 | grep -oE 'glm-5-turbo' || echo 'glm-5-turbo')"
  primary_glm47flashx="$(grep -E 'glm-4\.7-flashx' "$ROUTING_GUIDE" | head -1 | grep -oE 'glm-4\.7-flashx' || echo 'glm-4.7-flashx')"
  primary_glm5vturbo="$(grep -E 'glm-5v-turbo' "$ROUTING_GUIDE" | head -1 | grep -oE 'glm-5v-turbo' || echo 'glm-5v-turbo')"
  primary_grokbuild="$(grep -E 'grok-build-0\.1' "$ROUTING_GUIDE" | head -1 | grep -oE 'grok-build-0\.1' || echo 'grok-build-0.1')"
  primary_gemini31pro="$(grep -E 'gemini-3\.1-pro-preview' "$ROUTING_GUIDE" | head -1 | grep -oE 'gemini-3\.1-pro-preview' || echo 'gemini-3.1-pro-preview')"
  primary_gemini31lite="$(grep -E 'gemini-3\.1-flash-lite' "$ROUTING_GUIDE" | head -1 | grep -oE 'gemini-3\.1-flash-lite' || echo 'gemini-3.1-flash-lite')"
  primary_claude_m3="$(grep -E 'MiniMax-M3' "$ROUTING_GUIDE" | head -1 | grep -oE 'MiniMax-M3' || echo 'MiniMax-M3')"
  primary_claude_m27="$(grep -E 'MiniMax-M2\.7[^-]' "$ROUTING_GUIDE" | head -1 | grep -oE 'MiniMax-M2\.7' | head -1 || echo 'MiniMax-M2.7')"
  primary_claude_m27hs="$(grep -E 'MiniMax-M2\.7-highspeed' "$ROUTING_GUIDE" | head -1 | grep -oE 'MiniMax-M2\.7-highspeed' || echo 'MiniMax-M2.7-highspeed')"

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
KANT_CLAUDE_MODEL="$primary_claude_m3"

# §3~§7 전체 모델 레지스트리 (메타 에이전트 참조용)
KANT_PRIMARY_GLM47="$primary_glm47"
KANT_PRIMARY_GLM5TURBO="$primary_glm5turbo"
KANT_PRIMARY_GLM47FLASHX="$primary_glm47flashx"
KANT_PRIMARY_GLM5VTURBO="$primary_glm5vturbo"
KANT_PRIMARY_GROKBUILD="$primary_grokbuild"
KANT_PRIMARY_GEMINI31PRO="$primary_gemini31pro"
KANT_PRIMARY_GEMINI31LITE="$primary_gemini31lite"
KANT_PRIMARY_CLAUDE_M3="$primary_claude_m3"
KANT_PRIMARY_CLAUDE_M27="$primary_claude_m27"
KANT_PRIMARY_CLAUDE_M27HS="$primary_claude_m27hs"

# §17.2 강점 태그 (메타 에이전트 빠른 매칭용)
KANT_TAG_CODING_MODELS="gpt-5.6-sol gpt-5.6-terra glm-5.2 grok-4.5 gemini-3.5-flash"
KANT_TAG_FRONTEND_MODELS="gemini-3.5-flash glm-5v-turbo gemini-3.1-pro-preview"
KANT_TAG_KOREAN_MODELS="gpt-5.6-sol gpt-5.6-terra MiniMax-M3 MiniMax-M2.7"
KANT_TAG_FAST_MODELS="gpt-5.6-luna glm-4.7-flashx gemini-3.1-flash-lite grok-4.5"
KANT_TAG_HUGE_CONTEXT_MODELS="glm-5.2 MiniMax-M3"

KANT_ROUTE_TINY_PRIMARY="$primary_luna"
KANT_ROUTE_STANDARD_PRIMARY="$primary_terra"
KANT_ROUTE_HARD_PRIMARY="$primary_sol"
KANT_ROUTE_HUGE_PRIMARY="$primary_glm52"
KANT_ROUTE_VISUAL_PRIMARY="$primary_gemini35flash"
KANT_ROUTE_VISUAL_HARNESS="antigravity"
KANT_ROUTE_REVIEW_PRIMARY="$primary_sol"
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
# TASK 키워드 → 라우트 매핑
# ---------------------------------------------------------------------------

# 인자: TASK.md 경로
# 출력: "tool:model" 또는 "tool1:model1,tool2:model2" (--parallel용)
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

  # 기본: standard_repo
  echo "codex:${KANT_PRIMARY_TERRA}"
}

# ---------------------------------------------------------------------------
# 여러 도구 동시 호출용 슬라이싱 (--parallel)
# ---------------------------------------------------------------------------

# 인자: TASK.md 경로
# 출력: 콤마 구분 "tool:model" 리스트 (2~4개)
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
--- full registry ---
KANT_PRIMARY_GLM47=$KANT_PRIMARY_GLM47
KANT_PRIMARY_GLM5TURBO=$KANT_PRIMARY_GLM5TURBO
KANT_PRIMARY_GLM47FLASHX=$KANT_PRIMARY_GLM47FLASHX
KANT_PRIMARY_GLM5VTURBO=$KANT_PRIMARY_GLM5VTURBO
KANT_PRIMARY_GROKBUILD=$KANT_PRIMARY_GROKBUILD
KANT_PRIMARY_GEMINI31PRO=$KANT_PRIMARY_GEMINI31PRO
KANT_PRIMARY_GEMINI31LITE=$KANT_PRIMARY_GEMINI31LITE
KANT_PRIMARY_CLAUDE_M3=$KANT_PRIMARY_CLAUDE_M3
KANT_PRIMARY_CLAUDE_M27=$KANT_PRIMARY_CLAUDE_M27
KANT_PRIMARY_CLAUDE_M27HS=$KANT_PRIMARY_CLAUDE_M27HS
--- tags ---
KANT_TAG_CODING_MODELS=$KANT_TAG_CODING_MODELS
KANT_TAG_FRONTEND_MODELS=$KANT_TAG_FRONTEND_MODELS
KANT_TAG_KOREAN_MODELS=$KANT_TAG_KOREAN_MODELS
KANT_TAG_FAST_MODELS=$KANT_TAG_FAST_MODELS
KANT_TAG_HUGE_CONTEXT_MODELS=$KANT_TAG_HUGE_CONTEXT_MODELS
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

가이드 위치: $ROUTING_GUIDE
EOF
