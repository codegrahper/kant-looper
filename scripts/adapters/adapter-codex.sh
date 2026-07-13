#!/usr/bin/env bash
# adapter-codex.sh — OpenAI Codex CLI 어댑터
#
# 호출: codex exec --json -o <response> -s <sandbox> -m <model> "<prompt>"
#       --skip-git-repo-check </dev/null
# 완료 감지: exit code + -o FILE last message + --json JSONL 마지막 이벤트
#
# 강화 (2026-07-13, Goal 2):
# - </dev/null: stdin 명시 차단 (백그라운드 무한 대기 방지)
# - --skip-git-repo-check: 비-git 환경 호환 (skill-codex 규칙)
# - detached 모드에서 approval_policy=never: 자동 응답 정책
#   (safety check는 safety-check.sh가 별도로 수행)

set -Eeuo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="$ADAPTER_DIR/../lib"

# 응답/로그 디렉터리 (worktree 안 또는 state dir)
get_io_dir() {
  local worktree="$1"
  local io_dir="$worktree/.kant-looper"
  mkdir -p "$io_dir"
  echo "$io_dir"
}

# ---------------------------------------------------------------------------
# health
# ---------------------------------------------------------------------------

health() {
  "$SKILL_LIB/health-check.sh" tool codex
}

version() {
  command -v codex >/dev/null 2>&1 && codex --version 2>&1 | head -1 || echo "codex not installed"
}

# ---------------------------------------------------------------------------
# call
# ---------------------------------------------------------------------------
# 인자: role, prompt_file, worktree, model
# 출력 (stdout): verdict | json_path
# 종료 코드: 0 = 정상, 그 외 = 실패

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"

  if [ ! -f "$prompt_file" ]; then
    echo "ERROR: prompt file not found: $prompt_file" >&2
    return 1
  fi

  # health check
  if ! "$SKILL_LIB/health-check.sh" tool codex >/dev/null 2>&1; then
    echo "ERROR: codex unavailable" >&2
    return 201   # AUTH_FAILED 또는 사용 불가
  fi

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-codex-${role}.txt"
  local log_file="$io_dir/log-codex-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")

  # role에 따른 sandbox 모드 결정
  # - plan / review / verify: read-only (검증은 read-only여야 안전)
  # - implement / repair: workspace-write (구현은 파일 변경 필요)
  local sandbox_mode
  case "$role" in
    plan|review|verify)
      sandbox_mode="read-only"
      ;;
    implement|repair)
      sandbox_mode="workspace-write"
      ;;
    *)
      sandbox_mode="read-only"   # 안전 기본값
      ;;
  esac

  # prompt 읽기 (작은 경우 stdin으로 전달 가능하지만 안전을 위해 임시 파일에 저장)
  local prompt
  prompt="$(cat "$prompt_file")"

  # 명령 구성 — role별 sandbox + json + json-schema (있다면)
  local cmd=(
    codex exec
    --json
    -o "$response_file"
    -s "$sandbox_mode"
    -C "$worktree"
    -m "$model"
    --skip-git-repo-check    # FIX (Goal 2): 비-git 디렉터리 호환 (skill-codex 규칙)
  )

  # json-schema가 role별로 가능하면 추가 (옵션)
  local schema_file="$ADAPTER_DIR/../schemas/${role}-schema.json"
  if [ -f "$schema_file" ]; then
    cmd+=( --output-schema "$schema_file" )
  fi

  # reasoning effort (gpt-5.6 모델군에서 유효)
  if printf '%s' "$model" | grep -qE 'gpt-5\.'; then
    local effort="${KANT_CODEX_REASONING_EFFORT:-medium}"
    cmd+=( -c "model_reasoning_effort=$effort" )
  fi

  # FIX (Goal 2): detached 모드에서 approval_policy=never. 사용자가 즉시 응답 불가.
  # Kant의 safety-check.sh가 별도로 protected paths/forbidden patterns 검사하므로
  # Codex 자체의 approval은 sandbox 경계 안에서 자동 처리.
  if [ "${KANT_DETACHED:-0}" = "1" ]; then
    cmd+=( -c "approval_policy=never" )
  fi

  # prompt 추가
  cmd+=( "$prompt" )

  # 실행 — set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  # FIX (Goal 4): KANT_CODEX_RUNTIME 기본값을 app-server로 변경.
  # 기존에는 exec였지만, app-server가 v1 안정화되었으므로 기본값 전환.
  # app-server 실패 시 codex-runtime.sh가 자동으로 exec로 fallback (KANT_CODEX_FALLBACK_TO_EXEC=1 기본).
  # FIX (Goal 3): KANT_CODEX_RUNTIME 환경변수로 exec 또는 app-server 선택.
  # FIX (Goal 2): </dev/null 명시는 codex-runtime.sh 내부에서 처리.
  local runtime="${KANT_CODEX_RUNTIME:-app-server}"
  local rc=0
  local runner_output
  if runner_output="$("$SKILL_LIB/codex-runtime.sh" "$runtime" "$timeout" "$log_file" "$response_file" "$worktree" "$model" "$prompt_file" "$sandbox_mode")"; then
    rc=0
  else
    rc=$?
  fi

  # 응답 처리
  local json_text
  json_text="$("$SKILL_LIB/verdict-extractor.sh" extract "$response_file" 2>/dev/null || true)"

  if [ -z "$json_text" ]; then
    # 응답 추출 실패 → 명시적 실패 표시 (stdout + non-zero exit)
    local failure_mode
    failure_mode=$("$SKILL_LIB/fallback-dispatcher.sh" classify "codex" "$rc" "$(cat "$log_file" 2>/dev/null)")
    echo "FAIL:${failure_mode:-EXTRACT_FAILED}"
    return 1
  fi

  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text")

  local json_path="$io_dir/codex-${role}.json"
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
    echo "adapter-codex.sh — OpenAI Codex CLI 어댑터"
    echo ""
    echo "사용법:"
    echo "  adapter-codex.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-codex.sh health"
    echo "  adapter-codex.sh version"
    exit 1
    ;;
esac