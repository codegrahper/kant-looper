#!/usr/bin/env bash
# failure-context.sh — 실패 컨텍스트 캡처 모듈
#
# kant-loop 실패 시 메타 에이전트(kant-failure-analyzer)에 전달할
# 구조화된 컨텍스트를 생성합니다.

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$LIB_DIR/.." && pwd)"

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
  run_id: $run_id
  branch: $branch
  worktree: $worktree
  failure_code: $failure_code
  failure_message: |
$(echo "$failure_message" | sed 's/^/    /')

phase_events: |
$(echo "$phase_events" | sed 's/^/    /')

adapter_log_tail: |
$(echo "$adapter_log" | sed 's/^/    /')

git_diff: |
$(echo "$git_diff" | sed 's/^/    /')

recent_commits: |
$(echo "$recent_commits" | sed 's/^/    /')

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
