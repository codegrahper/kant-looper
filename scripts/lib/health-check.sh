#!/usr/bin/env bash
# health-check.sh — CLI/MCP 도구 연결 상태 점검
#
# 모든 외부 도구 호출 *전에* 실행. 죽은 도구는 즉시 우회하고 fallback_dispatch.
# kant-looper의 "안전하고 정확하고 빠름"의 "안전"을 책임지는 첫 단계.
#
# bash 3.2 호환 (macOS 기본 bash).

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 단일 도구 health check
# ---------------------------------------------------------------------------
# 인자: tool_name (codex | grok | opencode | agy | claude)
# 종료 코드: 0 (정상) 또는 1 (사용 불가)

health_check_tool() {
  local tool="$1"
  case "$tool" in
    codex)
      command -v codex >/dev/null 2>&1 || return 1
      codex --version >/dev/null 2>&1 || return 1
      # 도구 자체 응답 확인 (짧은 --help 호출)
      codex --help >/dev/null 2>&1 || true
      return 0
      ;;

    grok)
      command -v grok >/dev/null 2>&1 || return 1
      grok --version >/dev/null 2>&1 || return 1
      [ -f "${HOME}/.grok/auth.json" ] || return 1
      return 0
      ;;

    opencode)
      command -v opencode >/dev/null 2>&1 || return 1
      # 시스템 PATH 또는 ~/.opencode/bin/opencode 둘 다 시도
      if ! command -v opencode >/dev/null 2>&1; then
        [ -x "${HOME}/.opencode/bin/opencode" ] || return 1
      fi
      opencode --version >/dev/null 2>&1 || return 1
      return 0
      ;;

    agy)
      command -v agy >/dev/null 2>&1 || return 1
      agy --version >/dev/null 2>&1 || return 1
      return 0
      ;;

    claude)
      command -v claude >/dev/null 2>&1 || return 1
      claude --version >/dev/null 2>&1 || return 1
      # 인증은 claude CLI 자체에 위임. credentials.json/AP 키 부재가
      # UNAVAILABLE을 유발하면 모든 fallback chain의 최종 안전망이
      # 무력화되므로, 실제 인증 실패는 호출 시점에서 감지한다.
      return 0
      ;;

    *)
      echo "ERROR: unknown tool '$tool'" >&2
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 전체 점검
# ---------------------------------------------------------------------------
# 인자: 없음
# 출력: 각 도구의 OK / UNAVAILABLE 상태를 stdout에 한 줄씩

health_check_all() {
  local tool result status
  for tool in codex grok opencode agy claude; do
    if health_check_tool "$tool"; then
      status="OK"
    else
      status="UNAVAILABLE"
    fi
    echo "$tool: $status"
  done
}

# ---------------------------------------------------------------------------
# 호출 가능 도구만 콤마 구분
# ---------------------------------------------------------------------------

# 인자: 없음
# 출력: 콤마 구분된 사용 가능 도구 이름 (예: "codex,grok,opencode,claude")

available_tools() {
  local tool out=""
  for tool in codex grok opencode agy claude; do
    if health_check_tool "$tool"; then
      if [ -z "$out" ]; then
        out="$tool"
      else
        out="${out},${tool}"
      fi
    fi
  done
  echo "$out"
}

# ---------------------------------------------------------------------------
# 짧은 환경 sanity check (preflight)
# ---------------------------------------------------------------------------

preflight_check() {
  local log_path="${1:-/dev/null}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] kant-looper preflight starting" | tee -a "$log_path"
  echo "Tools:" | tee -a "$log_path"
  health_check_all | tee -a "$log_path"
  echo "" | tee -a "$log_path"

  # 가이드 파일 존재 확인
  local guide_path="$LIB_DIR/../../references/multimodel-coding-agent-routing-guide.md"
  if [ -f "$guide_path" ]; then
    echo "routing-guide.md: OK ($(wc -l < "$guide_path" | tr -d ' ') lines)" | tee -a "$log_path"
  else
    echo "routing-guide.md: MISSING (will use built-in defaults)" | tee -a "$log_path"
  fi

  # 필수 유틸 확인
  local util
  for util in git jq python3 shasum; do
    if command -v "$util" >/dev/null 2>&1; then
      echo "util $util: OK" | tee -a "$log_path"
    else
      echo "util $util: MISSING" | tee -a "$log_path"
    fi
  done

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] preflight done" | tee -a "$log_path"
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "tool" ]; then
  shift
  health_check_tool "$@"
  exit $?
fi

if [ "${1:-}" = "all" ]; then
  health_check_all
  exit 0
fi

if [ "${1:-}" = "available" ]; then
  available_tools
  exit 0
fi

if [ "${1:-}" = "preflight" ]; then
  shift
  preflight_check "$@"
  exit 0
fi

# 인자 없이 실행: 전체 점검
health_check_all
exit 0
