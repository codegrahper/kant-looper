#!/usr/bin/env bash
# test-fix-apply-e2e.sh — fix-apply.sh 통합 e2e 테스트
#
# 실제 git worktree에서 fix-apply가 다음을 수행하는지 검증:
#   S1: 정상 패치 → fix/* 브랜치에서 변경 적용 → 커밋 → 마커
#   S2: unstaged 변경이 있으면 거부 (데이터 손실 방지)
#   S3: branch_name="main" 거부
#   S4: branch_name="master" 거부
#   S5: branch_name에 ".." 포함 거부
#   S6: SKILL_ROOT 외부 경로 거부 (realpath canonical)
#   S7: reentry marker: 동일 proposal 재실행 거부
#   S8: commands_to_run 필드가 있어도 fix-apply는 실행하지 않음 (보안)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="$(cd "$SCRIPT_DIR/../lib" && pwd)"

declare -i PASS=0 FAIL=0

# ----- 공통 유틸: e2e 환경 만들기 -----
setup_e2e_env() {
  local env_name="$1"
  local branch="${2:-feat/eval-base}"

  local env
  env="$(mktemp -d -t kant-e2e-XXXXXX)"
  EVAL_DIRS="${EVAL_DIRS:-}"
  if [ -n "$EVAL_DIRS" ]; then
    EVAL_DIRS="${EVAL_DIRS}:${env}"
  else
    EVAL_DIRS="$env"
  fi
  export EVAL_DIRS

  mkdir -p "$env/scripts/lib" "$env/scripts/tests"

  (
    cd "$env"
    git init -q 2>/dev/null
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "# eval fixture" > README.md
    mkdir -p scripts/lib
    echo "OLD_VALUE" > scripts/lib/target.sh
    # proposal/ 디렉토리도 git add/commit (untracked로 남으면 guard_worktree_clean이 거부)
    mkdir -p proposal
    touch proposal/.gitkeep
    git add .
    git commit -q -m "init"
    # 운영 시나리오: feature 브랜치에서 fix-apply 호출
    git checkout -q -b "$branch"
    # fix-apply + apply-change.py 복사
    cp "$SKILL_LIB/fix-apply.sh" scripts/lib/
    cp "$SKILL_LIB/apply-change.py" scripts/lib/
    # run-scenarios.sh가 scripts/kant-loop.sh를 호출하므로 복사
    cp "$SCRIPT_DIR/../kant-loop.sh" scripts/kant-loop.sh
    # allowlist 회귀 테스트를 위해 scripts/lib/의 다른 .sh + scripts/tests/도 복사
    # (SKILL 자체를 copy하지 않고 allowlist가 요구하는 파일만 복사)
    shopt -s nullglob
    for f in "$SKILL_LIB"/*.sh; do
      bn=$(basename "$f")
      [ "$bn" = "fix-apply.sh" ] && continue  # 이미 위에서 copy
      cp "$f" "scripts/lib/$bn"
    done
    for f in "$SCRIPT_DIR"/test-*.sh "$SCRIPT_DIR"/run-scenarios.sh; do
      cp "$f" "scripts/tests/$(basename "$f")"
    done
    shopt -u nullglob
    # run-scenarios.sh가 참조하는 references/multimodel-coding-agent-routing-guide.md
    # 가 없으면 smoke 단계에서 WARN → 일부 시나리오 fail. 최소 stub 제공.
    mkdir -p references
    printf '%s\n' \
      '# minimal stub for e2e test' \
      '| model | tier | use case |' \
      '| --- | --- | --- |' \
      '| stub | stub | stub |' > references/multimodel-coding-agent-routing-guide.md
    # 신규 파일 commit → guard_worktree_clean 통과
    # (untracked로 두면 fix-apply가 unstaged 변경으로 인식하여 거부)
    git add .
    git commit -q -m "add fix-apply for e2e"
    # LF normalization 회피용 캐시 설정
    git config core.autocrlf false 2>/dev/null || true
    git config core.quotepath off 2>/dev/null || true
  )

  printf '%s\n' "$env"
}

cleanup_all() {
  if [ -n "${EVAL_DIRS:-}" ]; then
    local IFS=':'
    for d in $EVAL_DIRS; do
      [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
  fi
}
trap cleanup_all EXIT

# scenario_all_runs_in_branch(feature_branch, branch_for_guard_main_test)
# 운영 시나리오를 시뮬레이션: feature 브랜치에서 호출
scenario_apply() {
  local env="$1" branch="$2" new_value="$3"
  local proposal="$env/proposal/proposal.json"

  cat > "$proposal" <<EOF
{
  "branch_name": "$branch",
  "fix_summary": "e2e patch",
  "changes": [
    {
      "file": "$env/scripts/lib/target.sh",
      "old_string": "OLD_VALUE",
      "new_string": "$new_value"
    }
  ]
}
EOF

  # proposal.json을 commit (안 그러면 guard가 untracked로 거부)
  ( cd "$env" && git add proposal/proposal.json && git commit -q -m "e2e: proposal" )

  (
    cd "$env"
    bash scripts/lib/fix-apply.sh apply "$proposal"
  )
}

# ============================================================
# S1: 정상 패치 적용 — fix/* 브랜치에서 변경 → 커밋 → 마커
# ============================================================
echo "[S1] 정상 패치 적용 (fix/* 브랜치)"

ENV=$(setup_e2e_env "S1")
if result=$(scenario_apply "$ENV" "fix/eval-S1" "NEW_VALUE" 2>&1); then
  # 커밋 확인 (feat/eval-S1 → fix/eval-S1)
  branch_post=$(cd "$ENV" && git rev-parse --abbrev-ref HEAD)
  if [ "$branch_post" = "feat/eval-base" ]; then
    echo "  PASS [S1a]: fix-apply 후 원래 브랜치로 복귀 (feat/eval-base)"
    ((PASS++))
  else
    echo "  FAIL [S1a]: 복귀 안 됨 (current=$branch_post)"
    ((FAIL++))
  fi

  fix_branch_content=$(cd "$ENV" && git show fix/eval-S1:scripts/lib/target.sh 2>/dev/null)
  if [ "$fix_branch_content" = "NEW_VALUE" ]; then
    echo "  PASS [S1b]: fix/eval-S1 브랜치에 NEW_VALUE 커밋됨"
    ((PASS++))
  else
    echo "  FAIL [S1b]: fix 브랜치에 NEW_VALUE 없음 (got=$fix_branch_content)"
    ((FAIL++))
  fi

  if [ -e "$ENV/proposal/proposal.json.applied" ]; then
    echo "  PASS [S1c]: marker 파일 작성됨"
    ((PASS++))
  else
    echo "  FAIL [S1c]: marker 파일 없음"
    ((FAIL++))
  fi
else
  echo "  FAIL [S1]: apply Fix 자체 실패 ($result)"
  ((FAIL++))
fi

# ============================================================
# S2: unstaged 변경이 있으면 거부 (데이터 손실 방지)
# ============================================================
echo "[S2] unstaged 변경 거부"
ENV=$(setup_e2e_env "S2")
# unstaged 추가 (작업 트리에 더러운 상태 만들기)
(
  cd "$ENV"
  echo "dirty_unstaged_value" > scripts/lib/target.sh
)
if ! result=$(scenario_apply "$ENV" "fix/should-fail" "EVIL" 2>&1); then
  if echo "$result" | grep -q "unstaged"; then
    echo "  PASS [S2]: unstaged 변경 있어 거부됨"
    ((PASS++))
  else
    echo "  FAIL [S2]: 거부되었으나 메시지에 'unstaged' 없음 ($result)"
    ((FAIL++))
  fi
else
  # 실패해야 하는데 성공 → fail
  echo "  FAIL [S2]: unstaged 인데도 apply 성공함"
  ((FAIL++))
fi

# ============================================================
# S3: branch_name = "main" 거부
# ============================================================
echo "[S3] branch_name = 'main' 거부"
ENV=$(setup_e2e_env "S3")
if ! result=$(scenario_apply "$ENV" "main" "EVIL" 2>&1); then
  if echo "$result" | grep -qE "main.*master.*fix|fix.*분기|invalid fix branch"; then
    echo "  PASS [S3]: branch_name 'main' 거부됨"
    ((PASS++))
  else
    echo "  FAIL [S3]: 거부되었으나 메시지 불명 ($result)"
    ((FAIL++))
  fi
else
  echo "  FAIL [S3]: main 거부 안 됨"
  ((FAIL++))
fi

# ============================================================
# S4: branch_name = "master" 거부
# ============================================================
echo "[S4] branch_name = 'master' 거부"
ENV=$(setup_e2e_env "S4")
if ! result=$(scenario_apply "$ENV" "master" "EVIL" 2>&1); then
  echo "  PASS [S4]: branch_name 'master' 거부됨"
  ((PASS++))
else
  echo "  FAIL [S4]: master 거부 안 됨"
  ((FAIL++))
fi

# ============================================================
# S5: branch_name에 '..' 포함 (상위 디렉터리 탈출 시도) 거부
# ============================================================
echo "[S5] branch_name에 '..' 포함 시도 거부"
ENV=$(setup_e2e_env "S5")
if ! result=$(scenario_apply "$ENV" "fix/../evil-escape" "EVIL" 2>&1); then
  echo "  PASS [S5]: 'fix/../escape' 거부됨"
  ((PASS++))
else
  echo "  FAIL [S5]: 'fix/../escape' 거부 안 됨"
  ((FAIL++))
fi

# ============================================================
# S6: SKILL_ROOT 외부 절대경로 거부 (cannonical path 우회)
# ============================================================
echo "[S6] SKILL_ROOT 외부 절대경로 거부"
ENV=$(setup_e2e_env "S6")
cat > "$ENV/proposal/proposal.json" <<EOF
{
  "branch_name": "fix/external-evil",
  "fix_summary": "try external file",
  "changes": [
    {
      "file": "/tmp/evil-outside-${RANDOM}.sh",
      "old_string": "any",
      "new_string": "any"
    }
  ]
}
EOF
if ! (
  cd "$ENV"
  bash scripts/lib/fix-apply.sh apply proposal/proposal.json 2>&1
) | grep -qE "외부|outside|invalid|허용|allowlist|ERROR"; then
  echo "  PASS [S6]: 외부 경로 거부됨"
  ((PASS++))
else
  echo "  FAIL [S6]: 외부 경로 거부 안 됨"
  ((FAIL++))
fi

# ============================================================
# S7: 동일 proposal 재실행 (reentry) 거부
# ============================================================
echo "[S7] marker 있는 proposal 재실행 거부"
ENV=$(setup_e2e_env "S7")
# 첫 호출 — 성공해야 함
if scenario_apply "$ENV" "fix/reentry-test" "FIRST" >/dev/null 2>&1; then
  # 마커 강제로 생성
  touch "$ENV/proposal/proposal.json.applied"
  # 두 번째 호출 — 거부되어야 함
  if ! result=$(scenario_apply "$ENV" "fix/reentry-test" "SECOND" 2>&1); then
    echo "  PASS [S7]: reentry 차단됨"
    ((PASS++))
  else
    echo "  FAIL [S7]: reentry 차단 안 됨 (성공해버림)"
    ((FAIL++))
  fi
else
  echo "  FAIL [S7]: 첫 호출 자체 실패 (e2e 환경 오류)"
  ((FAIL++))
fi

# ============================================================
# S8: commands_to_run 필드 존재 시 fix-apply가 실행하지 않음
# ============================================================
echo "[S8] commands_to_run 있어도 bash -c로 실행되지 않음"
ENV=$(setup_e2e_env "S8")
# 위험한 명령 (rm -rf /tmp/very-specific-evil-marker) + 패치를 같이
# 만약 fix-apply가 commands_to_run을 bash -c로 실행하면 이 파일이 삭제됨
EVIL_MARKER="/tmp/kant-evil-marker-$$-$(date +%s).txt"
echo "if you see this, S8 FAILED" > "$EVIL_MARKER"

cat > "$ENV/proposal/proposal.json" <<EOF
{
  "branch_name": "fix/security-test",
  "fix_summary": "verify commands_to_run ignored",
  "commands_to_run": ["rm -f $EVIL_MARKER"],
  "changes": [
    {
      "file": "$ENV/scripts/lib/target.sh",
      "old_string": "OLD_VALUE",
      "new_string": "PATCHED"
    }
  ]
}
EOF

# proposal.json commit (guard_worktree_clean 통과용)
(cd "$ENV" && git add proposal/proposal.json && git commit -q -m "e2e: proposal for S8")

(
  cd "$ENV"
  bash scripts/lib/fix-apply.sh apply proposal/proposal.json >/dev/null 2>&1
)

# 검증: EVIL_MARKER 파일이 아직 존재해야 함 (delete 안 됨)
if [ -f "$EVIL_MARKER" ]; then
  echo "  PASS [S8a]: EVIL_MARKER 파일 그대로 — commands_to_run 미실행"
  ((PASS++))
  rm -f "$EVIL_MARKER"
else
  echo "  FAIL [S8a]: EVIL_MARKER 파일 삭제됨 — commands_to_run 실행됨 (보안 위반)"
  ((FAIL++))
fi

# 검증: 패치는 정상 적용됨 (commands_to_run 못 써도 fix-apply 본 기능은 작동)
if [ -f "$ENV/scripts/lib/target.sh" ]; then
  current=$(cat "$ENV/scripts/lib/target.sh" 2>/dev/null)
  # fix/security-test 브랜치의 내용
  patched=$(cd "$ENV" && git show fix/security-test:scripts/lib/target.sh 2>/dev/null)
  if [ "$patched" = "PATCHED" ]; then
    echo "  PASS [S8b]: 패치는 정상 적용됨"
    ((PASS++))
  else
    echo "  FAIL [S8b]: 패치 적용 안 됨 (got=$patched)"
    ((FAIL++))
  fi
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
