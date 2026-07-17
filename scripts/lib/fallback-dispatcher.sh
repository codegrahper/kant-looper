#!/usr/bin/env bash
# fallback-dispatcher.sh — 호출 실패 시 다른 도구/모델로 즉시 전환
#
# 이 스크립트가 kant-looper의 "이바가 개입하는 순간 그것은 kant-looper가 아닙니다" 약속을 지킴.
# 어떤 도구/모델이 죽어도 작업은 claude까지 자동으로 이어짐.
#
# bash 3.2 호환.

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK_LOG="${KANT_FALLBACK_LOG:-${KANT_STATE_DIR:-$HOME/.claude/state/kant-looper}/fallback.log}"

# ---------------------------------------------------------------------------
# Fallback 체인 정의 (references/fallback-table.md와 동기)
# ---------------------------------------------------------------------------
# 형식: "primary_tool|primary_model|fb_tool1|fb_model1|fb_tool2|fb_model2|..."
# 각 (tool, model) 쌍은 어댑터 호출 시 정확히 그 인자로 사용됨.
# 주의: 어댑터 이름(tool)은 실제 스크립트 이름과 일치해야 함 (예: adapter-opencode.sh).
#       모델은 같은 어댑터 내에서 다르게 시도 가능 (예: codex+gpt-5.6-luna).

# Fallback chain notes:
# - claude:default means "claude with its own default model" (no --model flag passed to Claude CLI)
# - MiniMax models are ONLY available through opencode agent, NOT through claude
# - Claude final fallback uses "default" sentinel, NOT MiniMax model IDs
declare -a KANT_FALLBACK_CHAINS_LINEAR=(
  "codex|gpt-5.6-sol|codex|gpt-5.6-terra|opencode|glm-5.2|agy|gemini-3.5-flash|grok|grok-4.5|claude|default"
  "codex|gpt-5.6-terra|codex|gpt-5.6-luna|opencode|glm-5.2|agy|gemini-3.5-flash|claude|default"
  "codex|gpt-5.6-luna|claude|default"
  "grok|grok-4.5|opencode|glm-5.2|codex|gpt-5.6-terra|agy|gemini-3.5-flash|claude|default"
  "opencode|glm-5.2|opencode|glm-4.7|codex|gpt-5.6-terra|agy|gemini-3.5-flash|grok|grok-4.5|claude|default"
  "opencode|glm-4.7|codex|gpt-5.6-terra|agy|gemini-3.5-flash|grok|grok-4.5|claude|default"
  "agy|gemini-3.5-flash|agy|gemini-3.1-pro-preview|opencode|glm-5.2|claude|default"
  "claude|default|claude|default"
)

# flat key-value로 변환: get_fallback_chain tool model → next tools/models (콤마 구분 "tool:model" 형식)
get_fallback_chain() {
  local tool="$1" model="$2"

  local line chain=""
  for line in "${KANT_FALLBACK_CHAINS_LINEAR[@]}"; do
    IFS='|' read -ra parts <<< "$line"
    if [ "${parts[0]}" = "$tool" ] && [ "${parts[1]}" = "$model" ]; then
      local i=2
      while [ $i -lt ${#parts[@]} ]; do
        local next_tool="${parts[$i]}"
        local next_model="${parts[$((i+1))]}"
        if [ -z "$chain" ]; then
          chain="${next_tool}:${next_model}"
        else
          chain="${chain},${next_tool}:${next_model}"
        fi
        i=$((i+2))
      done
      echo "$chain"
      return 0
    fi
  done
  echo ""
}

# 호환성을 위해 기본 fallback chain도 export
get_default_tool_model() {
  local task_kind="${1:-standard_repo}"
  case "$task_kind" in
    tiny) echo "codex:gpt-5.6-luna" ;;
    standard_repo) echo "codex:gpt-5.6-terra" ;;
    hard_repo) echo "codex:gpt-5.6-sol" ;;
    huge_context) echo "opencode:glm-5.2" ;;
    visual_browser) echo "agy:gemini-3.5-flash" ;;
    independent_review) echo "codex:gpt-5.6-sol" ;;
    *) echo "codex:gpt-5.6-terra" ;;
  esac
}

# ---------------------------------------------------------------------------
# 실패 모드별 1차 대응 시간
# ---------------------------------------------------------------------------

# 인자: failure_mode
# 출력: backoff 초
get_backoff_seconds() {
  local mode="$1"
  case "$mode" in
    TIMEOUT) echo 5 ;;
    RATE_LIMITED) echo 30 ;;
    AUTH_FAILED) echo 0 ;;        # 즉시 다른 공급자
    NETWORK_ERROR) echo 10 ;;
    INVALID_OUTPUT) echo 0 ;;    # 즉시 재시도
    INFRA_ERROR) echo 5 ;;
    *) echo 3 ;;
  esac
}

# ---------------------------------------------------------------------------
# fallback 실행
# ---------------------------------------------------------------------------
# 인자:
#   $1 = failed_tool
#   $2 = failed_model
#   $3 = failure_mode (TIMEOUT|RATE_LIMITED|AUTH_FAILED|NETWORK_ERROR|INVALID_OUTPUT|INFRA_ERROR)
#   $4 = prompt_file
#   $5 = worktree_path
#   $6 = role (plan|implement|review|verify|etc)
# 출력 (stdout): 시도 성공한 tool:model (콤마 구분 fallback chain 안에 첫 번째 성공)
# 종료 코드: 0 = fallback에서 성공, 1 = 모두 실패 (claude 포함)

do_fallback() {
  local failed_tool="$1" failed_model="$2" failure_mode="$3" prompt_file="$4" worktree="$5" role="${6:-implement}"

  local chain
  chain="$(get_fallback_chain "$failed_tool" "$failed_model")"
  if [ -z "$chain" ]; then
    chain="claude:default"
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback: $failed_tool:$failed_model ($failure_mode) → chain=$chain" >> "$FALLBACK_LOG"

  # 콤마로 분리된 chain을 순회
  IFS=',' read -ra pairs <<< "$chain"
  local pair next_tool next_model attempt rc
  for attempt in 1 2; do
    for pair in "${pairs[@]}"; do
      IFS=':' read -ra tm <<< "$pair"
      next_tool="${tm[0]}"
      next_model="${tm[1]}"

      # claude는 마지막 폴백이므로 2회차에서는 1회만 더 시도
      if [ "$attempt" -ge 2 ] && [ "$next_tool" = "claude" ]; then
        continue
      fi

      # 1차 backoff
      local backoff
      backoff=$(get_backoff_seconds "$failure_mode")
      if [ "$backoff" -gt 0 ]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback backoff ${backoff}s before $next_tool:$next_model" >> "$FALLBACK_LOG"
        sleep "$backoff"
      fi

      # 호출 — 어댑터가 rc=0으로 응답해도 verdict=PASS일 때만 SUCCESS로 간주
      # (BLOCKED/CHANGES_REQUESTED/INVALID_OUTPUT 응답은 다음 fallback 시도)
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback attempt: $next_tool:$next_model role=$role" >> "$FALLBACK_LOG"
      local fb_output fb_verdict
      if fb_output="$("$LIB_DIR/../adapters/adapter-$next_tool.sh" call "$role" "$prompt_file" "$worktree" "$next_model")"; then
        fb_verdict="${fb_output%%|*}"
        if [ "$fb_verdict" = "PASS" ]; then
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback SUCCESS: $next_tool:$next_model" >> "$FALLBACK_LOG"
          echo "$fb_output"
          return 0
        else
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback NOT_PASS: $next_tool:$next_model verdict=$fb_verdict (다음 fallback 시도)" >> "$FALLBACK_LOG"
          # 다음 fallback으로 진행
        fi
      else
        rc=$?
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback FAIL: $next_tool:$next_model (rc=$rc)" >> "$FALLBACK_LOG"
      fi
    done
  done

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback EXHAUSTED: all tools/models failed" >> "$FALLBACK_LOG"
  return 1
}

# ---------------------------------------------------------------------------
# 실패 모드 분류
# ---------------------------------------------------------------------------

# 인자: tool_name, exit_code, stderr_or_stdout
# 출력: TIMEOUT|RATE_LIMITED|AUTH_FAILED|NETWORK_ERROR|INVALID_OUTPUT|INFRA_ERROR
classify_failure() {
  local tool="$1" exit_code="$2" output="${3:-}"

  if [ "$exit_code" = "124" ]; then
    echo "TIMEOUT"
    return 0
  fi

  # HTTP 패턴
  if printf '%s' "$output" | grep -qE 'HTTP/[0-9.]+ 401|HTTP/[0-9.]+ 403|unauthorized|authentication failed|invalid api key'; then
    echo "AUTH_FAILED"
    return 0
  fi
  if printf '%s' "$output" | grep -qE 'HTTP/[0-9.]+ 429|rate limit|quota exceeded|too many requests'; then
    echo "RATE_LIMITED"
    return 0
  fi
  if printf '%s' "$output" | grep -qE 'connection refused|dns|network is unreachable|no route to host|getaddrinfo'; then
    echo "NETWORK_ERROR"
    return 0
  fi

  # INVALID_OUTPUT (JSON 파싱 실패) — exit 65
  if [ "$exit_code" = "65" ]; then
    echo "INVALID_OUTPUT"
    return 0
  fi

  echo "INFRA_ERROR"
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "chain" ]; then
  shift
  get_fallback_chain "$@"
  exit 0
fi

if [ "${1:-}" = "classify" ]; then
  shift
  classify_failure "$@"
  exit 0
fi

if [ "${1:-}" = "default" ]; then
  shift
  get_default_tool_model "$@"
  exit 0
fi

if [ "${1:-}" = "run" ]; then
  shift
  do_fallback "$@"
  exit $?
fi

cat <<EOF
fallback-dispatcher.sh — 호출 실패 시 다른 도구/모델로 즉시 전환

사용법:
  fallback-dispatcher.sh chain <tool> <model>     # fallback 체인 출력 (콤마 구분)
  fallback-dispatcher.sh classify <tool> <rc> <output>   # 실패 모드 분류
  fallback-dispatcher.sh default <task_kind>       # 기본 도구:모델
  fallback-dispatcher.sh run <tool> <model> <mode> <prompt> <worktree> <role>
EOF
exit 1
