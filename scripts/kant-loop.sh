#!/usr/bin/env bash
# kant-loop.sh — kant-looper 메인 백엔드
#
# 서브커맨드:
#   preflight TASK.md                          환경 검사 (side-effect 없음)
#   run TASK.md [--quick|--parallel]           모드 디스패치 (기본 = --quick)
#        [--dry-run] [--no-auto-commit] [--detach]
#   status --latest | RUN_ID                   실행 상태
#   await RUN_ID [--timeout N] [--interval N]  완료 블로킹 대기
#   report RUN_ID                              사용자 보고용 markdown 생성
#   promote BRANCH --target TARGET             사용자 명시 실행 (ff-only merge)
#   cleanup [--apply]                          dry-run 기본
#   update-guide                               routing-guide.md 갱신
#
# 안전 약속 (절대 위반 안 됨):
#   - 자동 push 금지
#   - merge commit 금지 (ff-only만, 사용자 명시 호출)
#   - rebase / reset --hard / branch -D 금지
#   - main 직접 커밋 금지
#   - protected paths / forbidden patterns 즉시 차단
#
# bash 3.2 호환 (macOS 기본 bash).

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 경로 상수
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"
REFERENCES_DIR="$SKILL_ROOT/references"

export KANT_SKILL_ROOT="$SKILL_ROOT"
export KANT_LIB_DIR="$LIB_DIR"
export KANT_ADAPTERS_DIR="$ADAPTERS_DIR"

# ---------------------------------------------------------------------------
# 기본 환경값
# ---------------------------------------------------------------------------

STATE_ROOT="${KANT_STATE_ROOT:-$HOME/.claude/state/kant-looper}"
AUTO_COMMIT="${KANT_AUTO_COMMIT:-1}"
BRANCH_PREFIX="${KANT_BRANCH_PREFIX:-agent/kant}"
NOTIFY="${KANT_NOTIFY:-1}"
NOTIFY_OSASCRIPT="${KANT_NOTIFY_OSASCRIPT:-1}"
PROTECTED_PATHS_DEFAULT='.git .env .env.local .env.*.local *.pem *.key *credential* *secret* *password* node_modules dist build __pycache__ .venv'
PROTECTED_PATHS="${PROTECTED_PATHS:-$PROTECTED_PATHS_DEFAULT}"
MAX_FILE_BYTES="${KANT_MAX_FILE_BYTES:-10485760}"

mkdir -p "$STATE_ROOT"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2
}

log_event() {
  local state_dir="$1" event="$2"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $event" >> "$state_dir/phase-events.log"
}

# ---------------------------------------------------------------------------
# repo hash (state dir 분리용)
# ---------------------------------------------------------------------------

repo_hash() {
  local cwd
  cwd="$(pwd)"
  printf '%s' "$cwd" | shasum -a 256 | cut -c1-12
}

# ---------------------------------------------------------------------------
# notify (macOS)
# ---------------------------------------------------------------------------

notify_macos() {
  local title="$1" message="$2"
  if [ "$NOTIFY_OSASCRIPT" = "1" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$message\" with title \"$title\" sound name \"Funk\"" 2>/dev/null || true
  fi
}

emit_terminal_event() {
  local state_dir="$1"
  if [ -n "${KANT_DISPATCH_DB:-}" ]; then
    "$SCRIPT_DIR/dispatcher/record-completion.sh" "$state_dir" "$KANT_DISPATCH_DB" >> "$state_dir/phase-events.log" 2>&1 || log_event "$state_dir" "DISPATCHER_COMPLETION_FAILED"
  fi
  local workflow_id
  workflow_id="$(cat "$state_dir/event-workflow-id.txt" 2>/dev/null || true)"
  [ -n "$workflow_id" ] || return 0

  local step_id agent model phase
  step_id="$(cat "$state_dir/event-step-id.txt" 2>/dev/null || true)"
  agent="$(cat "$state_dir/event-agent.txt" 2>/dev/null || true)"
  model="$(cat "$state_dir/event-model.txt" 2>/dev/null || true)"
  phase="$(cat "$state_dir/event-phase.txt" 2>/dev/null || true)"
  if [ -z "$step_id" ] || [ -z "$agent" ] || [ -z "$model" ] || [ -z "$phase" ]; then
    log_event "$state_dir" "EVENT_EMIT_SKIPPED missing workflow metadata"
    return 0
  fi

  if "$SCRIPT_DIR/event/emit-event.sh" emit \
    --state-dir "$state_dir" \
    --event-root "$STATE_ROOT/events" \
    --workflow-id "$workflow_id" \
    --step-id "$step_id" \
    --agent "$agent" \
    --model "$model" \
    --phase "$phase" >> "$state_dir/phase-events.log" 2>&1; then
    log_event "$state_dir" "EVENT_EMITTED workflow=$workflow_id step=$step_id"
  else
    log_event "$state_dir" "EVENT_EMIT_FAILED workflow=$workflow_id step=$step_id"
  fi
}

# ---------------------------------------------------------------------------
# fail_run
# ---------------------------------------------------------------------------

fail_run() {
  local state_dir="$1" code="$2" message="$3"
  log "FAIL: $code - $message"

  if [ -n "$state_dir" ] && [ -d "$state_dir" ]; then
    printf '%s' "$code" > "$state_dir/failure-code.txt"
    printf '%s' "$message" > "$state_dir/failure-message.txt"
    echo "failed" > "$state_dir/result.txt"
    log_event "$state_dir" "FAIL $code: $message"
    emit_terminal_event "$state_dir"
  fi

  notify_macos "kant-looper: failed" "$code - $message"
  return 1
}

# ---------------------------------------------------------------------------
# run_id 생성
# ---------------------------------------------------------------------------

gen_run_id() {
  local task_slug="${1:-task}"
  local ts
  ts="$(date -u +%Y%m%d-%H%M%S)"
  local rand
  rand="$(printf '%04x' $((RANDOM % 65536)))"
  printf '%s-%s-%s' "$task_slug" "$ts" "$rand"
}

# ---------------------------------------------------------------------------
# TASK.md 검증 + slug 추출
# ---------------------------------------------------------------------------

validate_task_md() {
  local task_md="$1"
  if [ ! -f "$task_md" ]; then
    log "ERROR: task file not found: $task_md"
    return 1
  fi
  if ! grep -qE '^##\s*목표|^##\s*Goal|^##\s*Objective' "$task_md"; then
    log "ERROR: task.md must have '## 목표' or '## Goal' section"
    return 1
  fi
  return 0
}

task_to_slug() {
  local task_md="$1"
  local title
  title="$(head -1 "$task_md" 2>/dev/null | sed -E 's/^#\s*//' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-32)"
  if [ -z "$title" ]; then
    title="task"
  fi
  echo "$title"
}

# ---------------------------------------------------------------------------
# Stage + safety check + commit
# ---------------------------------------------------------------------------

do_safety_check() {
  local worktree="$1"

  # 파이썬 런타임 캐시 정리 (git add -A 전에 수행)
  # $worktree 내부로 한정 — 경로 탈출 방지
  # *.pyc, *.pyo는 find -delete로 직접 삭제, __pycache__는 -exec rm -rf로 재귀 삭제
  find "$worktree" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
  find "$worktree" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true

  # 검사/커밋 전 반드시 스테이징한다. 이게 빠지면 두 가지가 조용히 깨진다:
  #   1) check_forbidden_patterns()가 git diff(--cached 포함)만 보므로,
  #      한 번도 add되지 않은 신규(untracked) 파일 안의 시크릿/키 패턴을 전혀 스캔하지 못한다.
  #   2) do_commit()이 "git diff --cached"로 staged_hash를 계산하고 git commit을 실행하는데,
  #      스테이징된 게 없으면 커밋할 게 없어 COMMIT_FAILED로 조용히 실패한다.
  # (실측: 신규 파일만 생성하는 작업에서 verdict=PASS인데도 커밋이 전부 실패했음)
  (cd "$worktree" && git add -A)

  "$LIB_DIR/safety-check.sh" all "$worktree"
}

# ---------------------------------------------------------------------------
# verdict의 changed_files가 실제 git diff와 일치하는지 교차검증
# ---------------------------------------------------------------------------
# 어댑터(특히 모델이 가벼운 경우)가 도구 호출을 한 번도 안 하고도
# "changed_files": [...] 를 채운 verdict=PASS를 그대로 내놓는 경우가 실측됨
# (opencode/glm-4.7, 파일 쓰기 도구 호출 로그 자체가 없었음). gate-runner는
# 테스트/빌드 설정이 없는 새 프로젝트에서는 no-op으로 통과해버리므로, 이
# 교차검증이 "실제로 무슨 일이 있었는지"를 확인하는 마지막 방어선이다.
#
# 인자: worktree, json_path (verdict JSON 파일 경로)
# 출력 (stdout): 실제로는 없는데 주장된 파일 목록. 없으면 빈 출력.
# 종료 코드: 0 = 일치, 1 = 불일치(주장한 파일이 실제 변경 목록에 없음)

verify_changed_files() {
  local worktree="$1" json_path="$2"

  if [ ! -f "$json_path" ]; then
    return 0
  fi

  local claimed
  claimed="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for f in (d.get("changed_files") or []):
        if isinstance(f, str) and f.strip() and f.strip() != "...":
            print(f.strip())
except Exception:
    pass
' "$json_path" 2>/dev/null)"

  if [ -z "$claimed" ]; then
    return 0
  fi

  local actual
  actual="$(
    cd "$worktree" && {
      git diff --name-only --cached 2>/dev/null
      git diff --name-only 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u
  )"

  local missing=""
  local file
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! printf '%s\n' "$actual" | grep -qxF "$file"; then
      missing="${missing}${file}\n"
    fi
  done <<< "$claimed"

  if [ -n "$missing" ]; then
    printf '%b' "$missing"
    return 1
  fi
  return 0
}

do_commit() {
  local worktree="$1" state_dir="$2" task_summary="$3"

  local staged_hash
  staged_hash="$(cd "$worktree" && git diff --cached --binary | shasum -a 256 | cut -d' ' -f1)"
  echo "$staged_hash" > "$state_dir/final-diff-hash.txt"

  local reviewed_tree
  reviewed_tree="$(cd "$worktree" && git write-tree)"
  echo "$reviewed_tree" > "$state_dir/reviewed-tree-sha.txt"

  local current_branch
  current_branch="$(cd "$worktree" && git rev-parse --abbrev-ref HEAD)"
  if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    fail_run "$state_dir" "MAIN_COMMIT_BLOCKED" "Cannot commit directly to $current_branch"
    return 1
  fi

  cat > "$state_dir/commit-message.txt" <<EOF
chore(kant): $task_summary

Automated-Kant-Loop: $(basename "$state_dir")
Base-Branch: $current_branch
Reviewed-Diff-Hash: $staged_hash
Reviewed-Tree-SHA: $reviewed_tree
EOF

  # 빈 hooksPath + gpgSign=false commit (hooks를 안전한 위치에 만들어 우회)
  local empty_hooks
  empty_hooks="$(mktemp -d)"
  touch "$empty_hooks/.gitkeep"

  (cd "$worktree" && \
    git -c core.hooksPath="$empty_hooks" \
        -c commit.gpgSign=false \
        -c user.name="kant-looper" \
        -c user.email="kant-looper@local" \
        commit -F "$state_dir/commit-message.txt") > "$state_dir/commit.log" 2>&1

  local commit_rc=$?

  # 빈 hooks 임시 디렉터리 정리 (Python shutil로 안전하게)
  if [ -d "$empty_hooks" ]; then
    python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$empty_hooks" 2>/dev/null || true
  fi

  if [ "$commit_rc" != "0" ]; then
    fail_run "$state_dir" "COMMIT_FAILED" "git commit returned $commit_rc. See commit.log"
    return 1
  fi

  local commit_sha
  commit_sha="$(cd "$worktree" && git rev-parse HEAD)"
  local committed_tree
  committed_tree="$(cd "$worktree" && git rev-parse HEAD^{tree})"

  echo "$commit_sha" > "$state_dir/commit-sha.txt"
  echo "$committed_tree" > "$state_dir/committed-tree-sha.txt"

  if [ "$committed_tree" != "$reviewed_tree" ]; then
    fail_run "$state_dir" "TREE_MISMATCH" "committed-tree $committed_tree != reviewed-tree $reviewed_tree"
    return 1
  fi

  echo "completed" > "$state_dir/result.txt"
  log_event "$state_dir" "COMMIT $commit_sha"
  emit_terminal_event "$state_dir"

  notify_macos "kant-looper: completed" "$current_branch @ $commit_sha"

  return 0
}

# ---------------------------------------------------------------------------
# Agent 기본 모델 매핑
# ---------------------------------------------------------------------------

get_default_model() {
  local tool="$1"
  case "$tool" in
    codex)    echo "gpt-5.6-sol" ;;
    opencode) echo "glm-5.2" ;;
    grok)     echo "grok-4.5" ;;
    agy)      echo "gemini-3.5-flash" ;;
    claude)   echo "default" ;;
    *)        echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# Agent + Model 호환성 검증 (CLI 호출 전)
# ---------------------------------------------------------------------------

validate_agent_model_compatibility() {
  local tool="$1" model="$2"
  if [ -z "$tool" ] || [ -z "$model" ]; then
    return 0
  fi

  case "$tool" in
    codex)
      if ! echo "$model" | grep -qE '^gpt-'; then
        echo "ERROR: codex requires gpt-* model, got '$model'" >&2
        return 1
      fi
      ;;
    opencode)
      if ! echo "$model" | grep -qE '^glm-'; then
        case "$model" in
          MiniMax-M3|MiniMax-M2.7) ;;
          *)
            echo "ERROR: opencode requires glm-* or a supported MiniMax model, got '$model'" >&2
            return 1
            ;;
        esac
      fi
      ;;
    grok)
      if ! echo "$model" | grep -qE '^grok-'; then
        echo "ERROR: grok requires grok-* model, got '$model'" >&2
        return 1
      fi
      ;;
    agy)
      if ! echo "$model" | grep -qE '^gemini-'; then
        echo "ERROR: agy requires gemini-* model, got '$model'" >&2
        return 1
      fi
      ;;
    claude)
      if echo "$model" | grep -qE '^MiniMax-'; then
        echo "ERROR: claude does not support MiniMax models" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 단일 호출 (--quick 모드)
# ---------------------------------------------------------------------------

run_quick_mode() {
  local task_md="$1" tool="${2:-}" model="${3:-}" state_dir="$4" worktree="$5"
  local role="${6:-implement}" commit_at_end="${7:-1}"

  # --agent만 지정되고 --model이 없을 때: agent 기본 모델 자동 선택
  if [ -n "$tool" ] && [ -z "$model" ]; then
    model="$(get_default_model "$tool")"
    log "auto model for --agent $tool: $model"
  fi

  if [ -z "$tool" ] && [ -z "$model" ]; then
    tool="codex"
    model="gpt-5.6-terra"
  elif [ -z "$tool" ]; then
    # --model만 지정된 경우
    tool="codex"
  fi

  if ! validate_agent_model_compatibility "$tool" "$model"; then
    fail_run "$state_dir" "INCOMPATIBLE_AGENT_MODEL" "tool=$tool model=$model"
    return 1
  fi

  log "quick mode: $role $tool:$model"
  log_event "$state_dir" "QUICK_CALL role=$role tool=$tool model=$model"

  local prompt_file="$state_dir/prompt-quick-$role.md"
  cat > "$prompt_file" <<EOF
$(cat "$task_md")

---

## 작업 영역 경로 규칙
Current working directory is your worktree root: $worktree
Use only relative paths. Do not recreate the worktree directory.
Examples: calculator.py, DONE.md, codex/, opencode/, grok/, agy/
Forbidden: Desktop/, ~/Desktop/, Users/, C:\
Agents modify only their own workspace. Do not modify other agent folders.

---

역할:
$role 역할만 수행하세요.
$(if [ "$role" = "review" ]; then echo "현재 변경을 읽기 전용으로 검토하세요. 파일을 수정하지 마세요."; fi)

---

## 보고 형식 (반드시 지킬 것)
너의 응답은 아래 JSON 객체로 응답한다. JSON 바깥에 다른 텍스트를 절대 붙이지 마라.

{
  "verdict": "PASS|CHANGES_REQUESTED|BLOCKED|INVALID_OUTPUT",
  "summary": "string",
  "findings": [],
  "changed_files": ["..."],
  "tests_added_or_updated": ["..."],
  "risks": ["..."],
  "notes_for_reviewer": "string"
}

마지막 줄에 <verdict>{PASS|CHANGES_REQUESTED|BLOCKED}</verdict> 태그도 함께 출력한다.

## 중요: 재시도 루프 방지
- 도구를 실행(tool call)한 직후에도 반드시 위에 정의한 JSON 포맷으로 응답을 출력해야 한다.
- 도구 실행 후 응답을 출력하지 않고 끝나지 마라. 반드시 JSON과 <verdict> 태그를 포함한 응답을 작성해야 한다.
- retry loop(재시도 루프)가 발생하지 않도록, 한 번의 구현 후 즉시 위 포맷으로 응답을 출력한다.
EOF

  local adapter="$ADAPTERS_DIR/adapter-${tool}.sh"
  if [ ! -x "$adapter" ]; then
    fail_run "$state_dir" "ADAPTER_MISSING" "adapter not found: $adapter"
    return 1
  fi

  # set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  local output rc=0
  if output="$("$adapter" call "$role" "$prompt_file" "$worktree" "$model" 2>>"$state_dir/phase-events.log")"; then
    rc=0
  else
    rc=$?
  fi

  # 어댑터가 명시적 FAIL: 출력했거나, rc != 0이거나, 출력이 비었으면 fallback_dispatcher로 전환
  if [ -z "$output" ] || [ "$rc" != "0" ] || [[ "$output" == FAIL:* ]]; then
    local failure_mode="${output#FAIL:}"
    [ -z "$failure_mode" ] || [ "$failure_mode" = "$output" ] && failure_mode="INFRA_ERROR"

    log_event "$state_dir" "ADAPTER_FAIL tool=$tool model=$model mode=$failure_mode rc=$rc"

    # fallback_dispatcher로 다른 도구/모델로 전환 시도
    local fallback_result
    fallback_result=$("$LIB_DIR/fallback-dispatcher.sh" run "$tool" "$model" "$failure_mode" "$prompt_file" "$worktree" "$role" 2>>"$state_dir/phase-events.log" || echo "")

    if [ -n "$fallback_result" ] && [[ "$fallback_result" != FAIL:* ]]; then
      log_event "$state_dir" "FALLBACK_USED result=$fallback_result"
      output="$fallback_result"
    else
      fail_run "$state_dir" "QUICK_CALL_FAILED" "$tool:$model mode=$failure_mode exit=$rc (fallback exhausted)"
      return 1
    fi
  fi

  local verdict="${output%%|*}"
  local json_path="${output##*|}"

  log_event "$state_dir" "QUICK_VERDICT verdict=$verdict"

  if [ "$verdict" != "PASS" ]; then
    fail_run "$state_dir" "QUICK_VERDICT_$verdict" "verdict=$verdict not PASS"
    return 1
  fi

  if [ "$role" != "review" ]; then
    local missing_files
    if missing_files="$(verify_changed_files "$worktree" "$json_path")"; then
      :
    else
      log_event "$state_dir" "CHANGED_FILES_MISMATCH: $missing_files"
      fail_run "$state_dir" "CHANGED_FILES_MISMATCH" "verdict claimed changed_files not found in actual git diff: $missing_files"
      return 1
    fi

    if ! do_safety_check "$worktree" > "$state_dir/safety.log" 2>&1; then
      fail_run "$state_dir" "SAFETY_VIOLATION" "see safety.log"
      return 1
    fi

    if ! "$LIB_DIR/gate-runner.sh" run "$worktree" "$state_dir/gates-$role" "01" >> "$state_dir/phase-events.log" 2>&1; then
      fail_run "$state_dir" "GATE_FAILED" "see gates-$role/gate-01.log"
      return 1
    fi
  fi

  if [ "$AUTO_COMMIT" = "1" ] && [ "$commit_at_end" = "1" ]; then
    local task_title
    task_title="$(head -1 "$task_md" | sed 's/^#\s*//')"
    do_commit "$worktree" "$state_dir" "$task_title"
    return $?
  else
    echo "pass_no_commit" > "$state_dir/result.txt"
    emit_terminal_event "$state_dir"
    notify_macos "kant-looper: pass_no_commit" "quick mode, $role $tool:$model"
    return 0
  fi
}

run_quick_chain() {
  local task_md="$1" state_dir="$2" worktree="$3" agent_chain="$4"
  local chain_copy="$agent_chain" stage=0
  local roles=(implement review repair)

  while [ -n "$chain_copy" ]; do
    local pair="${chain_copy%%,*}"
    local tool="${pair%%:*}" model="${pair#*:}"
    [ "$tool" != "$model" ] || { fail_run "$state_dir" "INVALID_CHAIN" "expected tool:model, got $pair"; return 1; }
    [ "$stage" -lt 3 ] || { fail_run "$state_dir" "INVALID_CHAIN" "quick chain must contain exactly three agents"; return 1; }
    run_quick_mode "$task_md" "$tool" "$model" "$state_dir" "$worktree" "${roles[$stage]}" 0 || return 1
    stage=$((stage + 1))
    if [ "$chain_copy" = "$pair" ]; then chain_copy=""; else chain_copy="${chain_copy#*,}"; fi
  done

  [ "$stage" = "3" ] || { fail_run "$state_dir" "INVALID_CHAIN" "quick chain requires implement, review, repair"; return 1; }
  if [ "$AUTO_COMMIT" = "1" ]; then
    local task_title
    task_title="$(head -1 "$task_md" | sed 's/^#\s*//')"
    do_commit "$worktree" "$state_dir" "$task_title"
  else
    echo "pass_no_commit" > "$state_dir/result.txt"
    emit_terminal_event "$state_dir"
  fi
}

# ---------------------------------------------------------------------------
# 병렬 호출 (--parallel 모드)
# ---------------------------------------------------------------------------

run_parallel_mode() {
  local task_md="$1" state_dir="$2" worktree="$3"
  local agent_chain="${4:-}"

  if [ -z "$agent_chain" ]; then
    fail_run "$state_dir" "MISSING_CHAIN" "--parallel 모드는 agent_chain이 필요합니다"
    return 1
  fi
  log "parallel review mode: $agent_chain"
  log_event "$state_dir" "PARALLEL_REVIEW chain=$agent_chain"

  local parallel_dir="$state_dir/parallel"
  mkdir -p "$parallel_dir"

  IFS=',' read -ra pairs <<< "$agent_chain"

  local i=0 pids=()
  for pair in "${pairs[@]}"; do
    IFS=':' read -ra tm <<< "$pair"
    local tool="${tm[0]}"
    local model="${tm[1]}"
    local slice_id=$((i+1))

    local prompt_file="$parallel_dir/prompt-review-$slice_id.md"
    cat > "$prompt_file" <<EOF
$(cat "$task_md")

## 작업 영역 경로 규칙
Current working directory is your worktree root: $worktree
Use only relative paths. Do not recreate the worktree directory.
Examples: calculator.py, DONE.md, codex/, opencode/, grok/, agy/
Forbidden: Desktop/, ~/Desktop/, Users/, C:\
Agents modify only their own workspace. Do not modify other agent folders.

병렬 검토 역할: $tool / 모델: $model / 검토: $slice_id/${#pairs[@]}
현재 변경을 읽기 전용으로 검토하세요. 파일을 수정하지 마세요.

## 보고 형식 (반드시 지킬 것)
너의 응답은 아래 JSON 객체로 응답한다. JSON 바깥에 다른 텍스트를 절대 붙이지 마라.

{
  "verdict": "PASS|CHANGES_REQUESTED|BLOCKED|INVALID_OUTPUT",
  "summary": "string",
  "findings": [],
  "changed_files": ["..."],
  "tests_added_or_updated": ["..."],
  "risks": ["..."],
  "notes_for_reviewer": "string"
}

마지막 줄에 <verdict>{PASS|CHANGES_REQUESTED|BLOCKED}</verdict> 태그도 함께 출력한다.

## 중요: 재시도 루프 방지
- 도구를 실행(tool call)한 직후에도 반드시 위에 정의한 JSON 포맷으로 응답을 출력해야 한다.
- 도구 실행 후 응답을 출력하지 않고 끝나지 마라. 반드시 JSON과 <verdict> 태그를 포함한 응답을 작성해야 한다.
- retry loop(재시도 루프)가 발생하지 않도록, 한 번의 구현 후 즉시 위 포맷으로 응답을 출력한다.
EOF

    (
      local adapter="$ADAPTERS_DIR/adapter-${tool}.sh"
      if [ -x "$adapter" ]; then
        "$adapter" call "review-$slice_id" "$prompt_file" "$worktree" "$model" \
          > "$parallel_dir/result-review-$slice_id.txt" 2>&1
        echo $? > "$parallel_dir/exit-review-$slice_id.txt"
      else
        echo "ADAPTER_MISSING" > "$parallel_dir/result-review-$slice_id.txt"
        echo 1 > "$parallel_dir/exit-review-$slice_id.txt"
      fi
    ) &
    pids+=($!)
    i=$((i+1))
  done

  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local all_pass=1
  local summary=""
  i=0
  for pair in "${pairs[@]}"; do
    IFS=':' read -ra tm <<< "$pair"
    local tool="${tm[0]}"
    local model="${tm[1]}"
    local slice_id=$((i+1))
    local exit_code
    exit_code="$(cat "$parallel_dir/exit-review-$slice_id.txt" 2>/dev/null || echo "1")"
    local result
    result="$(cat "$parallel_dir/result-review-$slice_id.txt" 2>/dev/null || echo "no output")"
    summary="${summary}${tool}:${model} exit=${exit_code} verdict=${result%%|*}
"
    if [ "$exit_code" != "0" ] || [ "${result%%|*}" != "PASS" ]; then
      all_pass=0
    fi
    i=$((i+1))
  done

  if [ "$all_pass" != "1" ]; then
    fail_run "$state_dir" "PARALLEL_REVIEW_FAILED" "one or more reviewers failed:\n$summary\nUse --quick --chain for implementation."
    return 1
  fi

  local changed
  changed="$(git -C "$worktree" status --porcelain --untracked-files=all | grep -Ev '^\?\? (\.kant-looper/|\.omo/run-continuation/|\.codegraph$)' || true)"
  if [ -n "$changed" ]; then
    fail_run "$state_dir" "PARALLEL_WRITE_DETECTED" "parallel review changed the worktree; use --quick --chain for implementation"
    return 1
  fi

  echo "pass_no_commit" > "$state_dir/result.txt"
  emit_terminal_event "$state_dir"
  notify_macos "kant-looper: parallel review passed" "${#pairs[@]} reviewers"
  return 0
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 서브커맨드: preflight
# ---------------------------------------------------------------------------

cmd_preflight() {
  local task_md="${1:-}"

  log "preflight starting..."
  "$LIB_DIR/health-check.sh" preflight "/tmp/kant-preflight.log"
  if [ -n "$task_md" ] && [ -f "$task_md" ]; then
    log "task.md: OK ($(wc -l < "$task_md" | tr -d ' ') lines)"
  fi
  log "preflight done"
  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: run
# ---------------------------------------------------------------------------

cmd_run() {
  local task_md=""
  local mode="quick"
  local dry_run=0
  local no_commit=0
  local detach=0
  local tool=""
  local model=""
  local agent_chain=""
  local workflow_id=""
  local workflow_step=""
  local role="implement"
  local existing_worktree=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --quick) mode="quick" ;;
      --parallel) mode="parallel" ;;
      --full)
        echo "--full HPRAR 모드는 중단되었습니다. --quick 또는 --quick --chain을 사용하세요." >&2
        exit 2
        ;;
      --dry-run) dry_run=1 ;;
      --strict-verify)
        echo "--strict-verify는 중단된 --full 전용 옵션입니다." >&2
        exit 2
        ;;
      --no-auto-commit) no_commit=1; export AUTO_COMMIT=0 ;;
      --detach) detach=1 ;;
      --agent) tool="$2"; shift ;;
      --model) model="$2"; shift ;;
      --chain) agent_chain="$2"; export KANT_AGENT_CHAIN="$2"; shift ;;
      --workflow) workflow_id="$2"; shift ;;
      --step) workflow_step="$2"; shift ;;
      --role) role="$2"; shift ;;
      --existing-worktree) existing_worktree="$2"; shift ;;
      -h|--help) cmd_run_help; exit 0 ;;
      -*) echo "unknown flag: $1" >&2; exit 1 ;;
      *)
        if [ -z "$task_md" ]; then
          task_md="$1"
        else
          echo "multiple task files specified" >&2; exit 1
        fi
        ;;
    esac
    shift
  done

  if [ -z "$task_md" ]; then
    echo "usage: kant-loop.sh run TASK.md [--quick|--parallel]" >&2
    exit 1
  fi

  if [ ! -f "$task_md" ]; then
    echo "task file not found: $task_md" >&2
    exit 1
  fi

  if [ "$mode" = "parallel" ] && [ -z "$agent_chain" ]; then
    echo "--parallel 모드는 --chain tool:model,tool:model,... 을 명시해야 합니다." >&2
    exit 1
  fi

  if [ -n "$workflow_id" ] && [ -z "$workflow_step" ]; then
    echo "--workflow requires --step" >&2
    exit 1
  fi
  if [ -z "$workflow_id" ] && [ -n "$workflow_step" ]; then
    echo "--step requires --workflow" >&2
    exit 1
  fi
  case "$role" in implement|review|repair) ;; *) echo "invalid role: $role" >&2; exit 1 ;; esac

  # --chain 포맷 검증: tool:model,tool:model,...
  if [ -n "$agent_chain" ]; then
    local chain_invalid=0
    local chain_count=0
    local chain_copy="$agent_chain"
    while [ -n "$chain_copy" ]; do
      local segment="${chain_copy%%,*}"
      if ! printf '%s' "$segment" | grep -Eq '^[^:]+:[^:]+$'; then
        echo "invalid chain segment: '$segment' (expected tool:model)" >&2
        chain_invalid=1
        break
      fi
      chain_count=$((chain_count + 1))
      if [ "$chain_copy" = "$segment" ]; then
        chain_copy=""
      else
        chain_copy="${chain_copy#*,}"
      fi
    done
    if [ "$chain_invalid" = "1" ]; then
      exit 1
    fi
    if [ "$mode" = "quick" ] && [ "$chain_count" != "3" ]; then
      echo "--quick --chain은 implement,review,repair 순서의 정확히 3개 tool:model이 필요합니다." >&2
      exit 1
    fi
    if [ "$mode" = "parallel" ] && [ "$chain_count" -gt "4" ]; then
      echo "--parallel은 최대 4개 reviewer만 지원합니다." >&2
      exit 1
    fi
    log "chain specified: $agent_chain"
  fi

  if [ "$dry_run" = "1" ]; then
    local effective_route
    if [ -n "$agent_chain" ]; then
      effective_route="chain:$agent_chain"
    else
      case "$mode" in
        quick)
          effective_route="${tool:-codex}:${model:-gpt-5.6-terra}"
          ;;
      esac
    fi
    local slug
    slug="$(task_to_slug "$task_md")"
    local rh
    rh="$(repo_hash)"
    local run_id
    run_id="$(gen_run_id "$slug")"
    echo "dry-run:"
    echo "  mode: $mode"
    echo "  task: $task_md"
    echo "  agent_chain: ${agent_chain:-}"
    echo "  effective_route: $effective_route"
    echo "  run_id: $run_id"
    echo "  state_dir: $STATE_ROOT/$rh/$run_id"
    echo "  branch: $BRANCH_PREFIX/$run_id"
    exit 0
  fi

  validate_task_md "$task_md"

  local slug
  slug="$(task_to_slug "$task_md")"
  local rh
  rh="$(repo_hash)"
  local run_id
  run_id="$(gen_run_id "$slug")"

  local state_dir="$STATE_ROOT/$rh/$run_id"
  mkdir -p "$state_dir"
  cp "$task_md" "$state_dir/task.md"
  echo "$run_id" > "$state_dir/run-id.txt"

  local branch="$BRANCH_PREFIX/$run_id"
  echo "$branch" > "$state_dir/branch.txt"

  if [ -n "$workflow_id" ]; then
    local event_agent="${tool:-codex}"
    local event_model="$model"
    if [ -z "$event_model" ]; then event_model="$(get_default_model "$event_agent")"; fi
    printf '%s\n' "$workflow_id" > "$state_dir/event-workflow-id.txt"
    printf '%s\n' "$workflow_step" > "$state_dir/event-step-id.txt"
    printf '%s\n' "$event_agent" > "$state_dir/event-agent.txt"
    printf '%s\n' "$event_model" > "$state_dir/event-model.txt"
    printf '%s\n' "$role" > "$state_dir/event-phase.txt"
  fi

  log "run_id=$run_id"
  log "state_dir=$state_dir"
  log "mode=$mode"

  # worktree 생성
  local repo
  repo="$(pwd)"
  local worktree
  if [ -n "$existing_worktree" ]; then
    worktree="$(cd "$existing_worktree" && pwd -P)" || { fail_run "$state_dir" "WORKTREE_NOT_FOUND" "$existing_worktree"; exit 1; }
    branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD)"
    echo "$branch" > "$state_dir/branch.txt"
  else
    worktree="$(create_worktree "$repo" "$branch")"
  fi
  echo "$worktree" > "$state_dir/worktree.txt"

  # worktree 정합성 검증 — 외부 도구가 실제로 격리된 곳에서 실행됨을 실행 전에 보장.
  # 인자 전달 실수 등으로 $repo나 엉뚱한 경로가 worktree로 잘못 넘어가는 사고를 차단.
  local repo_realpath worktree_realpath
  repo_realpath="$(cd "$repo" && pwd -P)"
  worktree_realpath="$(cd "$worktree" && pwd -P)"

  if [ "$repo_realpath" = "$worktree_realpath" ]; then
    fail_run "$state_dir" "WORKTREE_IS_REPO" "worktree resolves to original checkout: $worktree_realpath"
    exit 1
  fi

  if ! git -C "$repo_realpath" worktree list --porcelain | grep -Fx "worktree $worktree_realpath" >/dev/null; then
    fail_run "$state_dir" "UNREGISTERED_WORKTREE" "cwd is not registered in git worktree list: $worktree_realpath"
    exit 1
  fi

  if [ "$detach" = "1" ]; then
    log "detach mode — running in background"
    nohup "$SCRIPT_DIR/kant-loop.sh" _run_mode "$mode" "$task_md" "$state_dir" "$worktree" "$tool" "$model" "$agent_chain" "$role" > "$state_dir/detached.log" 2>&1 &
    local detached_pid=$!
    echo "$detached_pid" > "$state_dir/detached.pid"
    echo "run_id: $run_id"
    echo "state_dir: $state_dir"
    echo "branch: $branch"
    echo "detached_pid: $detached_pid"
    echo ""
    echo "상태 확인:"
    echo "  $SCRIPT_DIR/kant-loop.sh status $run_id"
    exit 0
  fi

  case "$mode" in
    quick)
      if [ -n "$agent_chain" ]; then
        run_quick_chain "$task_md" "$state_dir" "$worktree" "$agent_chain"
      else
        run_quick_mode "$task_md" "$tool" "$model" "$state_dir" "$worktree" "$role" "$([ "$role" = review ] && echo 0 || echo 1)"
      fi
      ;;
    parallel)
      run_parallel_mode "$task_md" "$state_dir" "$worktree" "$agent_chain"
      ;;
  esac
  local rc=$?

  echo ""
  echo "=== 결과 ==="
  echo "run_id: $run_id"
  echo "result: $(cat "$state_dir/result.txt" 2>/dev/null || echo "unknown")"
  echo "branch: $branch"
  if [ -f "$state_dir/commit-sha.txt" ]; then
    echo "commit: $(cat "$state_dir/commit-sha.txt")"
  fi
  if [ -f "$state_dir/failure-code.txt" ]; then
    echo "failure: $(cat "$state_dir/failure-code.txt") - $(cat "$state_dir/failure-message.txt")"
  fi
  echo ""
  echo "보고서: $SCRIPT_DIR/kant-loop.sh report $run_id"
  exit $rc
}

cmd_run_help() {
  cat <<EOF
kant-loop.sh run TASK.md [--quick|--parallel] [options]

옵션:
  --quick                단일 호출 모드 (기본값), 또는 --chain의 순차 체인
  --parallel             읽기 전용 동시 검토 모드 (최대 4명)
  --dry-run              환경 검사만, 실제 실행 X
  --no-auto-commit       검증 PASS여도 commit 안 함 (사용자 결정 대기)
  --detach               백그라운드로 실행
  --agent <tool>         quick 모드에서 사용할 도구 (codex|grok|opencode|agy|claude)
  --model <model>        quick 모드에서 사용할 모델
  --workflow <id>        완료 이벤트용 등록 workflow ID (반드시 --step과 함께)
  --step <id>            완료 이벤트용 현재 workflow step ID
  --role <role>          quick 역할 (implement|review|repair)
  --existing-worktree D  등록된 기존 worktree 재사용 (Supervisor 전용)
  --chain <chain>        tool:model,tool:model,...
                         (--quick은 implement,review,repair 3개 필수; --parallel은 필수)
EOF
}

cmd_workflow() {
  case "${1:-}" in
    start)
      shift
      exec "$SCRIPT_DIR/event/start-workflow.sh" "$@"
      ;;
    *)
      echo "usage: kant-loop.sh workflow start TASK.md --workflow ID [--workflow-file FILE]" >&2
      exit 2
      ;;
  esac
}

create_worktree() {
  local repo="$1" branch="$2"
  local wt_dir="/tmp/kant-worktree-$$"

  # subshell의 stdout/stderr 모두 /dev/null로 보내서 함수 출력이 새 경로만 포함하도록
  if (cd "$repo" && git worktree add -B "$branch" "$wt_dir" >/dev/null 2>&1); then
    :
  elif (cd "$repo" && git worktree add "$wt_dir" >/dev/null 2>&1 && git checkout -B "$branch" >/dev/null 2>&1); then
    :
  else
    return 1
  fi

  echo "$wt_dir"
}

_run_mode() {
  local mode="$1" task_md="$2" state_dir="$3" worktree="$4" tool="$5" model="$6" agent_chain="$7" role="${8:-implement}"
  local rc=0
  case "$mode" in
    quick)
      if [ -n "$agent_chain" ]; then
        run_quick_chain "$task_md" "$state_dir" "$worktree" "$agent_chain" || rc=$?
      else
        run_quick_mode "$task_md" "$tool" "$model" "$state_dir" "$worktree" "$role" "$([ "$role" = review ] && echo 0 || echo 1)" || rc=$?
      fi
      ;;
    parallel)
      run_parallel_mode "$task_md" "$state_dir" "$worktree" "$agent_chain" || rc=$?
      ;;
    *)
      rc=2
      ;;
  esac
  if [ "$rc" != 0 ] && [ ! -f "$state_dir/result.txt" ]; then
    fail_run "$state_dir" "UNSUPPORTED_MODE" "detached worker ended without terminal result: mode=$mode" || true
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# 서브커맨드: status
# ---------------------------------------------------------------------------

cmd_status() {
  local target="${1:-}"
  local rh
  rh="$(repo_hash)"

  if [ "$target" = "--latest" ] || [ -z "$target" ]; then
    local latest
    latest="$(ls -1t "$STATE_ROOT/$rh" 2>/dev/null | head -1 || true)"
    if [ -z "$latest" ]; then
      echo "no runs found"
      exit 1
    fi
    target="$latest"
  fi

  local state_dir="$STATE_ROOT/$rh/$target"
  if [ ! -d "$state_dir" ]; then
    echo "run not found: $target"
    exit 1
  fi

  echo "run_id: $target"
  echo "result: $(cat "$state_dir/result.txt" 2>/dev/null || echo "running")"
  echo "branch: $(cat "$state_dir/branch.txt" 2>/dev/null || echo "n/a")"
  echo "worktree: $(cat "$state_dir/worktree.txt" 2>/dev/null || echo "n/a")"
  if [ -f "$state_dir/commit-sha.txt" ]; then
    echo "commit: $(cat "$state_dir/commit-sha.txt")"
  fi
  if [ -f "$state_dir/failure-code.txt" ]; then
    echo "failure: $(cat "$state_dir/failure-code.txt") - $(cat "$state_dir/failure-message.txt")"
  fi

  echo ""
  echo "phase-events.log 마지막 10줄:"
  tail -10 "$state_dir/phase-events.log" 2>/dev/null || echo "  (no events)"
  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: report
# ---------------------------------------------------------------------------

cmd_report() {
  local run_id="${1:-}"
  local rh
  rh="$(repo_hash)"
  local state_dir="$STATE_ROOT/$rh/$run_id"

  if [ ! -d "$state_dir" ]; then
    echo "run not found: $run_id"
    exit 1
  fi

  cat <<EOF
# kant-looper 보고서 — $run_id

- run_id: $run_id
- 결과: $(cat "$state_dir/result.txt" 2>/dev/null || echo "running")
- 브랜치: $(cat "$state_dir/branch.txt" 2>/dev/null || echo "n/a")
- worktree: $(cat "$state_dir/worktree.txt" 2>/dev/null || echo "n/a")

## commit 정보
- commit_sha: $(cat "$state_dir/commit-sha.txt" 2>/dev/null || echo "n/a")
- reviewed_tree: $(cat "$state_dir/reviewed-tree-sha.txt" 2>/dev/null || echo "n/a")
- committed_tree: $(cat "$state_dir/committed-tree-sha.txt" 2>/dev/null || echo "n/a")

## 안전 검사
$(cat "$state_dir/safety.log" 2>/dev/null | head -10 || echo "  no safety log")

## 실패 정보
$(if [ -f "$state_dir/failure-code.txt" ]; then
  echo "  code: $(cat "$state_dir/failure-code.txt")"
  echo "  message: $(cat "$state_dir/failure-message.txt")"
fi)

## main 병합 (사용자 명시 실행)
\`\`\`bash
$SCRIPT_DIR/kant-loop.sh promote $(cat "$state_dir/branch.txt" 2>/dev/null || echo "<branch>") --target main
\`\`\`
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: promote (사용자 명시 실행)
# ---------------------------------------------------------------------------

cmd_promote() {
  local branch="${1:-}"
  local target=""

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="$2"; shift ;;
      *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
  done

  if [ -z "$branch" ] || [ -z "$target" ]; then
    echo "usage: kant-loop.sh promote BRANCH --target TARGET" >&2
    exit 1
  fi

  local rh
  rh="$(repo_hash)"
  local state_dir
  state_dir="$(find "$STATE_ROOT/$rh" -name "branch.txt" -exec grep -l "$branch" {} \; 2>/dev/null | head -1 | xargs -I {} dirname {})"

  if [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
    echo "ERROR: no state found for branch $branch"
    exit 1
  fi

  local result
  result="$(cat "$state_dir/result.txt" 2>/dev/null || echo "unknown")"
  if [ "$result" != "completed" ]; then
    echo "ERROR: state result is '$result', not 'completed'. promote 불가."
    exit 1
  fi

  local commit_sha
  commit_sha="$(cat "$state_dir/commit-sha.txt")"
  local branch_head
  branch_head="$(git rev-parse "$branch" 2>/dev/null || echo "")"
  if [ "$commit_sha" != "$branch_head" ]; then
    echo "ERROR: commit-sha $commit_sha != branch HEAD $branch_head"
    exit 1
  fi

  local reviewed_tree
  reviewed_tree="$(cat "$state_dir/reviewed-tree-sha.txt")"
  local committed_tree
  committed_tree="$(cat "$state_dir/committed-tree-sha.txt")"
  if [ "$reviewed_tree" != "$committed_tree" ]; then
    echo "ERROR: reviewed-tree != committed-tree"
    exit 1
  fi

  log "promoting $branch → $target (ff-only)"
  git merge --ff-only "$branch"

  local rc=$?
  if [ "$rc" = "0" ]; then
    notify_macos "kant-looper: promoted" "$branch → $target"
    log "promote 성공"
  else
    log "promote 실패 (exit=$rc)"
  fi
  exit $rc
}

# ---------------------------------------------------------------------------
# 서브커맨드: cleanup (안전한 Python wrapper 사용)
# ---------------------------------------------------------------------------

cmd_cleanup() {
  local apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      *) shift; continue ;;
    esac
    shift
  done

  local rh
  rh="$(repo_hash)"
  local keep_days=14

  log "cleanup (apply=$apply, keep=$keep_days days)"

  local dir
  for dir in "$STATE_ROOT/$rh"/*; do
    [ -d "$dir" ] || continue
    local name
    name="$(basename "$dir")"
    local mtime
    mtime="$(stat -f%m "$dir" 2>/dev/null || stat -c%Y "$dir" 2>/dev/null || echo 0)"
    local age_seconds=$(( $(date +%s) - mtime ))
    local age_days=$(( age_seconds / 86400 ))

    local result
    result="$(cat "$dir/result.txt" 2>/dev/null || echo "running")"

    if [ "$age_days" -lt "$keep_days" ]; then
      echo "KEEP (recent): $name (${age_days}d, $result)"
      continue
    fi

    case "$result" in
      completed)
        if [ "$apply" = "1" ]; then
          # Python으로 안전하게 정리
          python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$dir" 2>/dev/null || true
          echo "REMOVED: $name (completed, ${age_days}d)"
        else
          echo "WOULD REMOVE: $name (completed, ${age_days}d)"
        fi
        ;;
      failed|blocked)
        echo "MANUAL_REVIEW: $name ($result, ${age_days}d)"
        ;;
      *)
        echo "KEEP (running): $name ($result, ${age_days}d)"
        ;;
    esac
  done

  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: update-guide
# ---------------------------------------------------------------------------

cmd_update_guide() {
  local external_guide="/Users/drumqube/Downloads/multimodel-coding-agent-routing-guide.md"
  local internal_guide="$REFERENCES_DIR/multimodel-coding-agent-routing-guide.md"

  if [ ! -f "$external_guide" ]; then
    echo "ERROR: 외부 가이드 없음: $external_guide"
    exit 1
  fi

  if [ ! -f "$internal_guide" ]; then
    echo "ERROR: 내부 가이드 없음: $internal_guide"
    exit 1
  fi

  echo "외부 vs 내부 가이드 diff:"
  if command -v diff >/dev/null 2>&1; then
    diff "$external_guide" "$internal_guide" | head -50
  fi

  echo ""
  echo "복사하시겠습니까? (외부 → 내부) [y/N]"
  read -r answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    cp "$external_guide" "$internal_guide"
    echo "갱신 완료"
  else
    echo "취소됨"
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: await (블로킹 완료 대기 — 하네스 자동 알림 연동)
# ---------------------------------------------------------------------------

cmd_await() {
  local target=""

  local timeout=3600
  local interval=5

  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)
        [ $# -ge 2 ] || { echo "ERROR: --timeout requires value" >&2; exit 1; }
        timeout="$2"
        shift 2
        ;;
      --interval)
        [ $# -ge 2 ] || { echo "ERROR: --interval requires value" >&2; exit 1; }
        interval="$2"
        shift 2
        ;;
      -h|--help)
        cat <<EOF
usage: kant-loop.sh await RUN_ID [--timeout SECONDS] [--interval SECONDS]

블로킹 대기: run-id의 result.txt가 완료 값을 쓸 때까지 폴링.
완료 시 status 요약을 출력하고 종료.

옵션:
  --timeout N    최대 대기 초 (기본 3600)
  --interval N   폴링 간격 초 (기본 5)

종료 코드:
  0  성공 (result=completed|pass_no_commit|pass)
  1  실패 (result=failed 또는 run-id 미존재)
  2  타임아웃
EOF
        exit 0
        ;;
      *)
        if [ -z "$target" ]; then
          target="$1"
          shift
        else
          echo "ERROR: unknown argument: $1" >&2
          exit 1
        fi
        ;;
    esac
  done

  if [ -z "$target" ]; then
    echo "usage: kant-loop.sh await RUN_ID [--timeout SECONDS] [--interval SECONDS]" >&2
    exit 1
  fi

  case "$timeout" in
    ''|*[!0-9]*) echo "ERROR: --timeout must be a positive integer, got: $timeout" >&2; exit 1 ;;
  esac
  case "$interval" in
    ''|*[!0-9]*) echo "ERROR: --interval must be a positive integer, got: $interval" >&2; exit 1 ;;
  esac
  if [ "$timeout" -le 0 ]; then echo "ERROR: --timeout must be > 0" >&2; exit 1; fi
  if [ "$interval" -le 0 ]; then echo "ERROR: --interval must be > 0" >&2; exit 1; fi

  local rh
  rh="$(repo_hash)"
  local state_dir="$STATE_ROOT/$rh/$target"
  if [ ! -d "$state_dir" ]; then
    echo "ERROR: run not found: $target" >&2
    exit 1
  fi

  local elapsed=0
  local result=""
  while [ "$elapsed" -lt "$timeout" ]; do
    result="$(cat "$state_dir/result.txt" 2>/dev/null || echo "")"
    if [ -n "$result" ] && [ "$result" != "running" ] && [ "$result" != "unknown" ]; then
      ( cmd_status "$target" ) 2>&1
      case "$result" in
        completed|pass_no_commit|pass) exit 0 ;;
        failed|*)                      exit 1 ;;
      esac
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "TIMEOUT: run-id $target 아직 완료 안 됨 (elapsed=${elapsed}s, timeout=${timeout}s)" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# 메인 dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
  preflight)
    shift
    cmd_preflight "$@"
    ;;
  run)
    shift
    cmd_run "$@"
    ;;
  workflow)
    shift
    cmd_workflow "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  await)
    shift
    cmd_await "$@"
    ;;
  report)
    shift
    cmd_report "$@"
    ;;
  promote)
    shift
    cmd_promote "$@"
    ;;
  cleanup)
    shift
    cmd_cleanup "$@"
    ;;
  update-guide)
    shift
    cmd_update_guide "$@"
    ;;
  _run_mode)
    shift
    _run_mode "$@"
    ;;
  -h|--help|help|"")
    cat <<EOF
kant-loop.sh — kant-looper 메인 백엔드

서브커맨드:
  preflight [TASK.md]                환경 검사 (사이드 이펙트 없음)
  run TASK.md [--quick|--parallel] [options]
                                     작업 실행 (기본 = --quick)
                                     --dry-run, --no-auto-commit, --detach
                                     --agent, --model, --chain
  workflow start TASK.md --workflow ID
                                     supervisor + root quick 호출을 자동 시작
  status --latest | RUN_ID           실행 상태 조회
  await RUN_ID [--timeout N] [--interval N]
                                     완료까지 블로킹 대기 (하네스 백그라운드 알림 연동)
  report RUN_ID                      보고서 markdown 생성
  promote BRANCH --target TARGET     사용자 명시 ff-only merge
  cleanup [--apply]                  14일 지난 state 정리 (dry-run 기본)
  update-guide                       외부 가이드 → 내부 가이드 갱신

skill 위치: $SKILL_ROOT
state 위치: $STATE_ROOT
EOF
    exit 0
    ;;
  *)
    echo "unknown subcommand: $1" >&2
    echo "도움말: $SCRIPT_DIR/kant-loop.sh --help" >&2
    exit 1
    ;;
esac
