#!/usr/bin/env bash
# failure-context.sh — 실패 컨텍스트 캡처 모듈
#
# kant-loop 실패 시 메타 에이전트(kant-failure-analyzer)에 전달할
# 구조화된 컨텍스트를 생성합니다.
#
# ⚠ 수동 복구 전용(manual recovery) — core runtime(kant-loop.sh)에서 자동
#   호출되지 않는다. 사용법·전체 흐름·안전 가드: references/self-repair-subsystem.md

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$LIB_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# redactor — 민감정보 마스킹
# ---------------------------------------------------------------------------
# review critique: 페일러 컨텍스트가 Claude로 전송되기 전에
# secret/credential이 제거 또는 마스킹되어야 한다. 다음을 마스킹한다:
#   - OpenAI/Anthropic/MiniMax 스타일 API 키 (sk-..., sk-cp-...)
#   - "Authorization: Bearer ..." 헤더
#   - "ANTHROPIC_API_KEY=..." / "OPENAI_API_KEY=..." 환경변수 형식
#   - .env 파일 내용
#   - 원격 URL에 포함된 userinfo (https://user:token@host)
#   - home 디렉터리 절대경로 (예: /Users/<user> → ~)
#
# 입력: stdin 또는 첫 번째 인자의 문자열
# 출력: 마스킹된 문자열 (stdout), 마스킹된 줄 수는 stderr로 보고

redactor() {
  local input
  if [ $# -gt 0 ]; then
    input="$1"
  else
    input="$(cat)"
  fi

  # sed는 no-match 시 비정상 종료를 하므로 || true 로 강제
  # 1) 환경변수 형식 키=value
  input=$(printf '%s' "$input" | sed -E \
    -e 's/(ANTHROPIC_API_KEY|OPENAI_API_KEY|OPENAI_AUTH_TOKEN|ANTHROPIC_AUTH_TOKEN|MINIMAX_API_KEY|MINI_MAX_API_KEY|GEMINI_API_KEY|CLAUDE_API_KEY)[ =:]+"?[A-Za-z0-9_\-]+"?/\1=[REDACTED]/gI' \
    -e 's/("?(api[_-]?key|api[_-]?secret|access[_-]?token|secret[_-]?key|auth[_-]?token)"?[[:space:]]*[:=][[:space:]]*)"?[A-Za-z0-9_\-]{12,}"?/\1"[REDACTED]"/gI' \
    2>/dev/null
  ) || true

  # 2) OpenAI sk-..., Anthropic sk-ant-..., MiniMax sk-cp-... 키
  input=$(printf '%s' "$input" | sed -E \
    's/\bsk-(cp-|ant-)?[A-Za-z0-9_\-]{20,}\b/sk-\1[REDACTED]/g' \
    2>/dev/null
  ) || true

  # 3) Bearer 헤더
  input=$(printf '%s' "$input" | sed -E \
    's/(Bearer[[:space:]]+)[A-Za-z0-9_\-\.]{12,}/\1[REDACTED]/gI' \
    2>/dev/null
  ) || true

  # 4) JWT (eyJ... 형태, 길이로 휴리스틱)
  # macOS sed는 \b 미지원 — POSIX [[:<:]] 사용
  input=$(printf '%s' "$input" | sed -E \
    's|[[:<:]]eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{10,}[[:>:]]|[REDACTED-JWT]|g' \
    2>/dev/null
  ) || true

  # 5) URL userinfo (https://user:token@host)
  # macOS/BSD sed는 \s를 지원하지 않으므로 POSIX [:space:] 사용
  input=$(printf '%s' "$input" | sed -E \
    's|(https?://)[^/@:[:space:]]+:[^/@:[:space:]]+@|\1[REDACTED]@|g' \
    2>/dev/null
  ) || true

  # 6) 홈 디렉터리 절대경로 → ~
  if [ -n "${HOME:-}" ]; then
    input=$(printf '%s' "$input" | sed -E "s|${HOME}|~|g" 2>/dev/null) || true
  fi

  printf '%s\n' "$input"
}

# ---------------------------------------------------------------------------
# capture_context
# ---------------------------------------------------------------------------
# 인자: state_dir
# 출력 (stdout): 구조화된 YAML-like 컨텍스트

capture_context() {
  local state_dir="$1"

  if [ ! -d "$state_dir" ]; then
    echo "ERROR: state_dir not found: $state_dir" >&2
    return 1
  fi

  local failure_code="unknown"
  failure_code="$(cat "$state_dir/failure-code.txt" 2>/dev/null || echo "unknown")"

  local failure_message=""
  failure_message="$(cat "$state_dir/failure-message.txt" 2>/dev/null || echo "")"

  local worktree=""
  worktree="$(cat "$state_dir/worktree.txt" 2>/dev/null || echo "")"

  local run_id=""
  run_id="$(cat "$state_dir/run-id.txt" 2>/dev/null || echo "")"

  local branch=""
  branch="$(cat "$state_dir/branch.txt" 2>/dev/null || echo "")"

  local phase_events=""
  phase_events="$(cat "$state_dir/phase-events.log" 2>/dev/null || echo "")"

  local adapter_log=""
  if [ -n "$worktree" ] && [ -d "$worktree/.kant-looper" ]; then
    adapter_log="$(ls "$worktree/.kant-looper"/*.log 2>/dev/null | head -1 || true)"
    if [ -n "$adapter_log" ] && [ -f "$adapter_log" ]; then
      adapter_log="$(tail -20 "$adapter_log" 2>/dev/null || true)"
    fi
  fi

  local git_diff=""
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    git_diff="$(cd "$worktree" && git diff HEAD 2>/dev/null || true)"
    if [ -z "$git_diff" ]; then
      git_diff="$(cd "$worktree" && git status --short 2>/dev/null || true)"
    fi
  fi

  local recent_commits=""
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    recent_commits="$(cd "$worktree" && git log --oneline -5 2>/dev/null || true)"
  fi

  cat <<YAMLEOF
---
failure_context:
  run_id: $(printf '%s' "$run_id" | redactor)
  branch: $(printf '%s' "$branch" | redactor)
  worktree: $(printf '%s' "$worktree" | redactor)
  failure_code: $failure_code
  failure_message: |
$(printf '%s' "$failure_message" | redactor | sed 's/^/    /')

phase_events: |
$(printf '%s' "$phase_events" | redactor | sed 's/^/    /')

adapter_log_tail: |
$(printf '%s' "$adapter_log" | redactor | sed 's/^/    /')

git_diff: |
$(printf '%s' "$git_diff" | redactor | sed 's/^/    /')

recent_commits: |
$(printf '%s' "$recent_commits" | redactor | sed 's/^/    /')

analyzer_instructions: |
  Analyze the failure, identify root cause, propose minimal fix.
  Fix MUST be made in a 'fix/<descriptive-name>' branch.
  NEVER touch main directly.
  Run regression tests after fix.
  Output JSON with: root_cause, fix_summary, files_changed, commands_to_run
YAMLEOF
}

# CLI 진입점
case "${1:-}" in
  capture)
    shift
    capture_context "$@"
    ;;
  *)
    echo "failure-context.sh — 실패 컨텍스트 캡처 모듈"
    echo ""
    echo "사용법:"
    echo "  failure-context.sh capture <state_dir>"
    exit 1
    ;;
esac
