#!/usr/bin/env bash
# adapter-claude.sh — Claude 자체 호출 (subagent 모드)
#
# 호출: claude -p "$(cat <prompt>)" --model <model> --permission-mode <mode> \
#        --tools <tools> --effort <effort>
# 완료 감지: exit code + stdout JSON

# kant-looper의 "최종 폴백"이자 "사용자가 명시적으로 claude 호출" 케이스용.
# 이 어댑터가 마지막 폴백이므로 실패 시 더 이상 fallback 없음.
#
# claude는 구독 로그인(OAuth) 상태 그대로 호출. MiniMax의 Anthropic-호환
# 엔드포인트(ANTHROPIC_AUTH_TOKEN/ANTHROPIC_BASE_URL)는 사용하지 않으며,
# model="default"이면 --model 플래그를 붙이지 않아 CLI 기본 모델을 그대로 쓴다.

set -Eeuo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="$ADAPTER_DIR/../lib"

get_io_dir() {
  local worktree="$1"
  local io_dir="$worktree/.kant-looper"
  mkdir -p "$io_dir"
  echo "$io_dir"
}

health() {
  "$SKILL_LIB/health-check.sh" tool claude
}

version() {
  command -v claude >/dev/null 2>&1 && claude --version 2>&1 | head -1 || echo "claude not installed"
}

# ---------------------------------------------------------------------------
# call
# ---------------------------------------------------------------------------

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"

  if [ ! -f "$prompt_file" ]; then
    echo "ERROR: prompt file not found: $prompt_file" >&2
    return 1
  fi

  if ! "$SKILL_LIB/health-check.sh" tool claude >/dev/null 2>&1; then
    echo "ERROR: claude unavailable" >&2
    return 201
  fi

  # MiniMax models must not be routed to claude adapter
  local bare_model="${model##*:}"
  bare_model="${bare_model##*/}"
  case "$bare_model" in
    MiniMax-M3|MiniMax-M2.7|MiniMax-M2.7-highspeed)
      echo "ERROR: MiniMax models are available only through the OpenCode agent." >&2
      echo "ERROR: Claude remains independent and does not select MiniMax model IDs." >&2
      return 1
      ;;
  esac

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-claude-${role}.json"
  local log_file="$io_dir/log-claude-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")

  local permission_mode="${KANT_CLAUDE_PERMISSION_MODE:-acceptEdits}"
  local tools="${KANT_CLAUDE_TOOLS:-Read,Write,Edit,Bash}"
  local effort="${KANT_CLAUDE_EFFORT:-medium}"

  # role별 tools/permission 조정
  case "$role" in
    plan|review|verify)
      permission_mode="dontAsk"
      tools="Read,Grep,Glob"
      effort="${KANT_CLAUDE_EFFORT:-high}"
      ;;
    implement|repair)
      permission_mode="acceptEdits"
      tools="Read,Write,Edit,Glob,Grep,Bash"
      effort="${KANT_CLAUDE_EFFORT:-medium}"
      ;;
  esac

  local cmd=(claude -p "$(cat "$prompt_file")")
  [ "$model" != "default" ] && cmd+=(--model "$model")
  cmd+=(
    --permission-mode "$permission_mode"
    --tools "$tools"
    --effort "$effort"
    --output-format json
  )

  # 실행 — set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  local rc=0
  local runner_output
  if runner_output="$("$SKILL_LIB/timeout-runner.sh" run "$timeout" "$log_file" "$response_file" "$worktree" "${cmd[@]}")"; then
    rc=0
  else
    rc=$?
  fi

  local json_text
  json_text="$("$SKILL_LIB/verdict-extractor.sh" extract "$response_file" 2>/dev/null || true)"

  if [ -z "$json_text" ]; then
    # claude는 마지막 폴백. 실패 시 fallback 없음 → 명시적 실패 보고
    echo "FAIL:FINAL_FALLBACK_FAILED"
    return 1
  fi

  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text")

  local json_path="$io_dir/claude-${role}.json"
  printf '%s' "$json_text" > "$json_path"

  echo "$verdict|$json_path"
  return 0
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

case "${1:-}" in
  call)
    shift
    call "$@"
    exit $?
    ;;
  health)
    health
    exit $?
    ;;
  version)
    version
    exit 0
    ;;
  *)
    echo "adapter-claude.sh — Claude 자체 호출 어댑터 (subagent 모드)"
    echo ""
    echo "사용법:"
    echo "  adapter-claude.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-claude.sh health"
    echo "  adapter-claude.sh version"
    echo ""
    echo "주의: claude는 마지막 폴백. 실패 시 더 이상 fallback 없음."
    exit 1
    ;;
esac
