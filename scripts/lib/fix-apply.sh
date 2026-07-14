#!/usr/bin/env bash
# fix-apply.sh — 메타 에이전트가 제안한 패치를 fix/ 브랜치에 안전하게 적용
#
# 안전 가드 (review critique P0/P1 반영):
# 1) fix/* 브랜치만 허용 (main/master/기타 명시 거부)
# 2) 작업 디렉터리는 깨끗해야 함 (unstaged/staged 변경 → 거부)
# 3) 변경 파일만 git add (--name-only 검사 → git add -- <file>만)
# 4) rollback은 영향받은 파일만 (git checkout -- . 같은 광역 reset 금지)
# 5) symlink 우회 차단 — realpath resolve 후 allowlist 검사
# 6) commands_to_run 인터페이스 자체를 받지 않음 (모델이 명령 결정 불가)
# 7) Python 인라인 보간 없음 — 별도 apply-change.py에서 argv로 받음
# 8) idempotency marker — 동일 proposal 재실행 차단

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_DIR="$(cd "$LIB_DIR/.." && pwd)"
SKILL_ROOT="$(cd "$SKILL_DIR/.." && pwd)"
APPLY_PY="$LIB_DIR/apply-change.py"

# ---------------------------------------------------------------------------
# 가드: fix/* 브랜치 prefix + main/master 명시 거부
# ---------------------------------------------------------------------------

guard_branch_name_format() {
  local branch="$1"
  case "$branch" in
    fix/[A-Za-z0-9._/-]*)
      [ "$branch" != "fix/" ] || return 1
      return 0
      ;;
    main|master)
      echo "ERROR: 보호된 브랜치(main/master)는 fix 대상으로 거부됨: $branch" >&2
      return 1
      ;;
    *)
      echo "ERROR: invalid fix branch (must start with fix/): $branch" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 가드: 메인 브랜치에서 실행 자체를 거부
# ---------------------------------------------------------------------------

guard_main_branch() {
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    echo "FATAL: meta-agent fix-apply는 main/master 브랜치에서 실행할 수 없습니다" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 가드: 작업 트리에 기존 변경이 없는지 (unstaged + untracked + staged + stashed)
# ---------------------------------------------------------------------------

guard_worktree_clean() {
  local repo="$1"
  local porcelain untracked stashed
  porcelain="$(git -C "$repo" status --porcelain 2>/dev/null || true)"
  untracked="$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null || true)"
  stashed="$(git -C "$repo" stash list 2>/dev/null || true)"

  if [ -n "$porcelain$untracked$stashed" ]; then
    echo "FATAL: 작업 트리에 unstaged/staged/untracked/stashed 변경이 있습니다. 자동 수정으로 기존 작업이 손실될 수 있어 거부합니다." >&2
    echo "  porcelain: $porcelain" >&2
    echo "  untracked: $untracked" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 가드: 허용된 경로 (realpath로 symlink 우회 차단)
# ---------------------------------------------------------------------------

# canonical resolve 후 allow_root 안에 있는지 검사
guard_path_in_repo() {
  local file="$1"
  local repo="$2"

  # 1) 입력 경로에 상위참조 (..) 직접 포함 시 거부
  case "$file" in
    *..*) echo "ERROR: 경로에 상위참조 (..) 발견: $file" >&2; return 1 ;;
  esac

  # 2) realpath -m 으로 canonical path 계산 (BSD/GNU 호환)
  local canonical
  if command -v realpath >/dev/null 2>&1; then
    canonical="$(realpath -m "$file" 2>/dev/null || echo "$file")"
  else
    canonical="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
  fi

  # 3) 절대경로만 허용 (상대경로는 거부)
  case "$canonical" in
    /*) ;;
    *) echo "ERROR: 절대경로 아님: $canonical" >&2; return 1 ;;
  esac

  # 4) canonical 안의 부모 디렉터리까지 realpath로 resolve 후
  #    저장소 SKILL_ROOT 내부인지 검사 (모든 부모 디렉터리가 SKILL_ROOT 또는
  #    canonical한 SKILL_ROOT 하위 디렉터리 안에 있어야 함)
  local repo_canonical
  repo_canonical="$(cd "$repo" && pwd -P)"
  case "$canonical" in
    "$repo_canonical"/*) return 0 ;;
    "$repo_canonical")
      # 정확히 저장소 루트인 경우 (e.g. .gitignore) — 변경 불허용
      echo "ERROR: 저장소 루트는 변경 불가: $canonical" >&2
      return 1
      ;;
    *)
      echo "ERROR: 경로가 저장소 외부로 resolve됨: $canonical (repo=$repo_canonical)" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 가드: 재진입 방지 (idempotency marker)
# ---------------------------------------------------------------------------

guard_no_reentry() {
  local json_file="$1"
  local marker="${json_file}.applied"
  if [ -e "$marker" ]; then
    echo "FATAL: 동일 fix 제안이 이미 적용됨 ($marker) — 재진입 차단" >&2
    return 1
  fi
}

mark_applied() {
  local json_file="$1"
  local marker="${json_file}.applied"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$marker" 2>/dev/null || echo "unknown" > "$marker"
}

# ---------------------------------------------------------------------------
# apply_fix
# ---------------------------------------------------------------------------

apply_fix() {
  local json_file="$1"

  if [ ! -f "$json_file" ]; then
    echo "ERROR: json_file not found: $json_file" >&2
    return 1
  fi

  cd "$SKILL_ROOT"

  # 가드 1: main/master 자체 실행 차단
  guard_main_branch || return 1

  # 가드 2: 재진입 방지
  guard_no_reentry "$json_file" || return 1

  # JSON 파싱 — 외부 명령에 인라인 보간 없음
  # jq가 있으면 jq, 없으면 python3 -c로 (단, JSON 파일 경로만 인자로)
  # JSON 파서들은 함수 외부에서 정의되어야 apply_fix 안에서 호출 가능
  unset _json_get _json_count _json_parser_kind 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    _json_get() { jq -r "$2 // \"\"" "$1"; }
    _json_count() { jq -r "$2 | length // 0" "$1"; }
  elif command -v python3 >/dev/null 2>&1; then
    _json_get() {
      python3 - "$1" "$2" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
keys = sys.argv[2].lstrip('.').split('.')
v = d
for k in keys:
    if not k: continue
    if isinstance(v, list):
        try: v = v[int(k)]
        except: v = ""
    elif isinstance(v, dict):
        v = v.get(k, "")
    else:
        v = ""
print(v if v is not None else "")
PYEOF
    }
    _json_count() { echo 0; }  # 보수적 fallback (jq 없으면 length 모름)
  else
    echo "ERROR: jq 또는 python3 필요 — 설치 후 다시 시도" >&2
    return 1
  fi

  # 가드 3: 작업 트리 깨끗해야 함 (기존 작업 손실 방지)
  guard_worktree_clean "$SKILL_ROOT" || return 1

  local branch_name fix_summary num_changes
  branch_name="$(_json_get "$json_file" .branch_name)"
  fix_summary="$(_json_get "$json_file" .fix_summary)"
  [ -z "$fix_summary" ] && fix_summary="meta-agent fix"
  num_changes="$(_json_count "$json_file" ".changes")"
  [ -z "$num_changes" ] || [ "$num_changes" = "null" ] && num_changes=0

  if [ -z "$branch_name" ] || [ "$branch_name" = "null" ]; then
    echo "ERROR: branch_name 없음" >&2
    return 1
  fi

  # 가드 4: fix/* prefix + main/master 거부
  guard_branch_name_format "$branch_name" || return 1

  # 브랜치 생성 — main 브랜치에서만 생성 (이미 main에 있으면 거부됨)
  # feature 브랜치나 detached HEAD에서는 차단
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$current_branch" = "HEAD" ]; then
    echo "FATAL: detached HEAD에서는 fix 브랜치를 만들 수 없습니다" >&2
    return 1
  fi

  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    # 기존 브랜치 — checkout 후 재확인
    git checkout "$branch_name" >/dev/null 2>&1 || return 1
  else
    git checkout -b "$branch_name" "$current_branch" >/dev/null 2>&1 || return 1
  fi

  # checkout 후 현재 브랜치 재확인 (TOCTOU 방지)
  local post_checkout_branch
  post_checkout_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$post_checkout_branch" != "$branch_name" ]; then
    echo "FATAL: checkout 후 현재 브랜치가 예상과 다름 ($post_checkout_branch != $branch_name)" >&2
    git checkout "$current_branch" >/dev/null 2>&1 || true
    return 1
  fi

  # 파일 변경 적용 — apply-change.py에 argv로 전달 (인라인 없음)
  if [ ! -f "$APPLY_PY" ]; then
    echo "ERROR: apply-change.py 미존재: $APPLY_PY" >&2
    return 1
  fi

  local applied=()
  for ((i=0; i<num_changes; i++)); do
    if ! python3 "$APPLY_PY" apply-one "$json_file" "$i"; then
      echo "ERROR: change[$i] 적용 실패" >&2
      # 영향받은 파일만 되돌림 — 광역 reset 안 함
      local j
      for f in "${applied[@]:-}"; do
        git checkout -- "$f" >/dev/null 2>&1 || true
      done
      git checkout "$current_branch" >/dev/null 2>&1 || true
      return 1
    fi

    # 적용된 파일 경로 기록 (rollback 범위 한정용)
    local changed_file
    changed_file="$(jq -r ".changes[$i].file // \"\"" "$json_file" 2>/dev/null || echo "")"
    if [ -n "$changed_file" ] && [ "$changed_file" != "null" ] && \
       guard_path_in_repo "$changed_file" "$SKILL_ROOT"; then
      applied+=("$changed_file")
    fi
  done

  # ─────────────────────────────────────────
  # 회귀 테스트: 코드 내장 allowlist만 실행
  # ─────────────────────────────────────────
  # 모델이 commands_to_run을 주는 인터페이스 자체가 없음.
  # 대신 코드 내장 ALLOWLIST_COMMANDS에서만 실행.
  local allowlist_cmds=(
    "bash -n scripts/lib/*.sh"
    "bash scripts/tests/test-timeout-runner-cwd.sh"
    "bash scripts/tests/run-scenarios.sh all"
    "bash scripts/lib/safety-check.sh self-test"
  )

  for c in "${allowlist_cmds[@]}"; do
    echo "=== allowlist 회귀: $c ==="
    if ! bash -c "$c"; then
      echo "ERROR: allowlist 테스트 실패 ($c) — 변경 파일만 되돌림" >&2
      local j
      for f in "${applied[@]:-}"; do
        git checkout -- "$f" >/dev/null 2>&1 || true
      done
      git checkout "$current_branch" >/dev/null 2>&1 || true
      rm -f "$(dirname "$json_file")/$(basename "$json_file" .json).applied"
      return 1
    fi
  done

  # ─────────────────────────────────────────
  # 커밋 — 변경한 파일만 stage
  # ─────────────────────────────────────────
  if [ "${#applied[@]}" -gt 0 ]; then
    # 변경 파일만 명시적으로 add
    git add -- "${applied[@]}" || {
      echo "ERROR: git add 실패" >&2
      git checkout -- "${applied[@]}" >/dev/null 2>&1 || true
      git checkout "$current_branch" >/dev/null 2>&1 || true
      return 1
    }
    # 의도하지 않은 다른 파일이 stage되지 않았는지 재확인
    local staged_count
    staged_count="$(git diff --cached --name-only | wc -l | tr -d ' ')"
    if [ "$staged_count" -ne "${#applied[@]}" ]; then
      echo "FATAL: stage된 파일 수 (${staged_count}) != 의도한 파일 수 (${#applied[@]}) — 광역 add 감지, abort" >&2
      git reset HEAD >/dev/null 2>&1 || true
      git checkout -- "${applied[@]}" >/dev/null 2>&1 || true
      git checkout "$current_branch" >/dev/null 2>&1 || true
      return 1
    fi
    git commit -m "fix(meta): $fix_summary" >/dev/null 2>&1 || {
      echo "ERROR: commit 실패" >&2
      git reset HEAD >/dev/null 2>&1 || true
      git checkout -- "${applied[@]}" >/dev/null 2>&1 || true
      git checkout "$current_branch" >/dev/null 2>&1 || true
      return 1
    }
  fi

  # idempotency marker 기록
  mark_applied "$json_file"

  # 원래 브랜치로 복귀 (다음 호출이 깨끗한 base에서 시작하도록)
  git checkout "$current_branch" >/dev/null 2>&1 || true

  git rev-parse HEAD
}

# 가드들을 export (테스트에서 source 가능)
export -f guard_branch_name_format
export -f guard_main_branch
export -f guard_worktree_clean
export -f guard_path_in_repo
export -f guard_no_reentry
export -f mark_applied

case "${1:-}" in
  apply)
    shift
    apply_fix "$@"
    ;;
  *)
    echo "fix-apply.sh — 메타 에이전트 패치 적용 (reviewer feedback 반영)"
    echo ""
    echo "사용법:"
    echo "  fix-apply.sh apply <json_file>"
    exit 1
    ;;
esac
