#!/usr/bin/env bash
# failure-analyzer.sh — 실패 컨텍스트를 메타 에이전트(claude)에 보내 분석 요청
#
# 출력: root_cause, fix_summary, files_changed, commands_to_run JSON
# 절대 main 브랜치에 직접 commit 하지 않는다.
# 모든 수정은 fix/ 브랜치에서 일어나야 한다.

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$LIB_DIR/.." && pwd)"
SKILL_ROOT="$(cd "$SKILL_DIR/.." && pwd)"
SKILL_LIB_DIR="$LIB_DIR"

# ---------------------------------------------------------------------------
# analyze
# ---------------------------------------------------------------------------
# 인자: state_dir
# 출력 (stdout): JSON (root_cause, fix_summary, files_changed, commands_to_run, branch_name)

analyze() {
  local state_dir="$1"

  if [ ! -d "$state_dir" ]; then
    echo "ERROR: state_dir not found: $state_dir" >&2
    return 1
  fi

  # 1) 실패 컨텍스트 캡처
  local context
  context="$("$LIB_DIR/failure-context.sh" capture "$state_dir")"

  # 2) 분석용 prompt 작성
  local analysis_prompt_file
  analysis_prompt_file="$(mktemp -t kant-analysis-XXXXXX)"
  cat > "$analysis_prompt_file" <<PROMPTEOF
You are a senior Bash/shell engineer analyzing a failure in kant-looper (a multi-model AI coding orchestrator).

Your job: identify the ROOT CAUSE of the failure and propose a MINIMAL FIX that resolves it.

$context

Constraints:
- You may ONLY modify files under: $SKILL_DIR/scripts/, $SKILL_DIR/scripts/lib/, $SKILL_DIR/scripts/adapters/, $SKILL_DIR/scripts/tests/
- NEVER touch main branch directly. Fix must be made in a 'fix/<name>' branch.
- Keep the diff minimal. Don't refactor unrelated code.
- After applying the fix, run regression tests (bash -n on all .sh files, then scripts/tests/*).

Output ONLY this JSON structure (no explanation, no markdown fence):
{
  "root_cause": "<one-line concise statement>",
  "fix_summary": "<2-4 sentences describing the fix approach>",
  "branch_name": "fix/<short-kebab-name>",
  "files_changed": ["<absolute paths>"],
  "changes": [
    {"file": "<path>", "old_string": "<exact text to replace>", "new_string": "<replacement>"}
  ],
  "commands_to_run": ["bash -c '<verification cmd>'"],
  "test_added": "<absolute path or empty>"
}
PROMPTEOF

  # 3) 메타 에이전트 호출 (claude의 sonnet/opus)
  local response_file
  response_file="$(mktemp -t kant-analysis-resp-XXXXXX)"

  local claude_model="${KANT_META_MODEL:-claude-sonnet-5}"
  local claude_perm_mode="${KANT_CLAUDE_PERMISSION_MODE:-plan}"

  if ! "$SKILL_LIB_DIR/health-check.sh" tool claude >/dev/null 2>&1; then
    echo "ERROR: meta agent (claude) unavailable" >&2
    rm -f "$analysis_prompt_file" "$response_file"
    return 201
  fi

  # --output-format json 으로 메타 에이전트 호출
  local cmd=(
    claude
    -p "$(cat "$analysis_prompt_file")"
    --model "$claude_model"
    --permission-mode "$claude_perm_mode"
    --output-format json
  )

  if ! claude "${cmd[@]}" > "$response_file" 2>/dev/null; then
    echo "ERROR: meta agent call failed" >&2
    rm -f "$analysis_prompt_file" "$response_file"
    return 1
  fi

  # 4) claude 응답 envelope에서 .result 추출 + code fence 언랩
  local meta_json
  meta_json="$("$LIB_DIR/verdict-extractor.sh" extract "$response_file" 2>/dev/null || true)"

  rm -f "$analysis_prompt_file" "$response_file"

  if [ -z "$meta_json" ]; then
    echo "ERROR: meta agent returned no parseable JSON" >&2
    return 1
  fi

  echo "$meta_json"
}

case "${1:-}" in
  analyze)
    shift
    analyze "$@"
    ;;
  *)
    echo "failure-analyzer.sh — 메타 에이전트 호출"
    echo ""
    echo "사용법:"
    echo "  failure-analyzer.sh analyze <state_dir>"
    exit 1
    ;;
esac
