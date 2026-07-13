#!/usr/bin/env bash
# adapter-grok.sh — xAI Grok CLI 어댑터 (Grok Build / Grok Agent)
#
# 호출: grok -p "$(cat <prompt>)" --cwd <worktree> -m <model> \
#        --output-format json --json-schema <schema> --verbatim \
#        --disable-web-search --no-subagents --sandbox read-only \
#        --permission-mode dontAsk --allow Read --allow Grep \
#        --deny 'Bash(*)' --deny 'Edit(*)' --reasoning-effort <effort>
# 완료 감지: exit code + streaming-json 마지막 이벤트

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
  "$SKILL_LIB/health-check.sh" tool grok
}

version() {
  command -v grok >/dev/null 2>&1 && grok --version 2>&1 | head -1 || echo "grok not installed"
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

  if ! "$SKILL_LIB/health-check.sh" tool grok >/dev/null 2>&1; then
    echo "ERROR: grok unavailable" >&2
    return 201
  fi

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-grok-${role}.json"
  local log_file="$io_dir/log-grok-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")

  local schema_file="$ADAPTER_DIR/../schemas/${role}-schema.json"

  # role에 따른 sandbox 모드 결정
  # - plan / review / verify: read-only
  # - implement / repair: workspace-write
  local sandbox_mode
  case "$role" in
    plan|review|verify)
      sandbox_mode="read-only"
      ;;
    implement|repair)
      sandbox_mode="workspace-write"
      ;;
    *)
      sandbox_mode="read-only"
      ;;
  esac

  # role에 따른 permission_mode 결정
  # - read-only 단계: dontAsk + Read/Grep만
  # - implement 단계: workspace-write에서는 Edit/Bash도 일부 허용 필요
  local permission_mode="dontAsk"
  local allow_extra=""
  case "$role" in
    implement|repair)
      permission_mode="acceptEdits"
      allow_extra="--allow Edit --allow Bash"
      ;;
  esac

  # sandbox 프로필 가용성 검증
  # ~/.grok/sandbox.toml이 없거나 요청된 프로필이 정의되지 않은 경우
  # --sandbox 플래그를 전달하면 grok이 실행 자체를 거부한다.
  # (실측: "workspace-write" 프로필 부재 시 error: could not apply the
  # 'workspace-write' sandbox profile — calculator.py 생성+실행은 --sandbox
  # 없이 정상 동작 확인)
  #
  # 안전 장치: timeout-runner.sh가 subprocess의 cwd를 worktree로 강제 격리
  # (process group 분리 + cwd 정규화). grok sandbox를 사용할 수 없을 때의
  # 대안이지 동등한 OS-level sandbox는 아님. implement/repair role에서는
  # permission_mode=acceptEdits + Edit/Bash 허용이므로 safety-check.sh가
  # 최종 안전망으로 동작한다.
  local sandbox_args=()
  local sandbox_toml="${HOME}/.grok/sandbox.toml"
  if [ -f "$sandbox_toml" ]; then
    # sandbox.toml이 존재: 요청된 프로필이 [profile-name] 섹션으로 정의되어 있는지 확인
    # POSIX 호환 grep 사용 (\s 대신 [[:space:]] — macOS bash 3.2 + grep 호환)
    if grep -qE "^[[:space:]]*\\[[[:space:]]*${sandbox_mode}[[:space:]]*\\][[:space:]]*([#].*)?$" "$sandbox_toml" 2>/dev/null; then
      sandbox_args=(--sandbox "$sandbox_mode")
    else
      echo "[adapter-grok] WARN: sandbox profile '$sandbox_mode' not found in $sandbox_toml — omitting --sandbox flag (cwd constrained by timeout-runner)" >&2
    fi
  else
    # sandbox.toml 자체가 없으면 sandbox 프로필을 사용할 수 없음
    echo "[adapter-grok] WARN: $sandbox_toml not found — omitting --sandbox flag (cwd constrained by timeout-runner)" >&2
  fi

  # Grok은 prompt를 -p 인자로 받음. 임시 파일에서 stdin 파이프도 가능.
  local cmd=(
    grok
    --no-auto-update
    -p "$(cat "$prompt_file")"
    --cwd "$worktree"
    -m "$model"
    --output-format json
    --verbatim
    --disable-web-search
    --no-subagents
    --permission-mode "$permission_mode"
    --allow Read
    --allow Grep
  )

  # sandbox가 검증된 경우에만 플래그 추가 (빈 배열이면 아무것도 안 함)
  if [ ${#sandbox_args[@]} -gt 0 ]; then
    cmd+=( "${sandbox_args[@]}" )
  fi

  # json-schema 추가 (옵션)
  if [ -f "$schema_file" ]; then
    cmd+=( --json-schema "$schema_file" )
  fi

  if [ -n "$allow_extra" ]; then
    IFS=' ' read -ra extras <<< "$allow_extra"
    cmd+=( "${extras[@]}" )
  fi

  case "$role" in
    plan|review|verify)
      cmd+=( --deny 'Bash(*)' --deny 'Edit(*)' )
      ;;
  esac

  # reasoning effort (grok-4.x 이상에서 유효)
  local effort="${KANT_GROK_REASONING_EFFORT:-high}"
  if printf '%s' "$model" | grep -qE 'grok-4\.'; then
    cmd+=( --reasoning-effort "$effort" )
  fi

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
    local failure_mode
    failure_mode=$("$SKILL_LIB/fallback-dispatcher.sh" classify "grok" "$rc" "$(cat "$log_file" 2>/dev/null)")
    echo "FAIL:${failure_mode:-EXTRACT_FAILED}"
    return 1
  fi

  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text")

  local json_path="$io_dir/grok-${role}.json"
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
    echo "adapter-grok.sh — xAI Grok CLI 어댑터"
    echo ""
    echo "사용법:"
    echo "  adapter-grok.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-grok.sh health"
    echo "  adapter-grok.sh version"
    exit 1
    ;;
esac