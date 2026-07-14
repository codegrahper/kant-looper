#!/usr/bin/env bash
# test-fix-apply-redesign.sh — PR B 리뷰 반영한 fix-apply.sh 재설계 회귀 테스트
#
# 시나리오:
# S1: apply-fix는 모델이 만든 free-form 셸 명령을 실행하지 않는다
# S2: fix/* 외 브랜치 거부 (main, master, 다른 prefix)
# S3: 작업 디렉터리에 기존 변경이 있으면 apply_fix 거부
# S4: Python 인터프레터는 JSON 인자만 받음 (python -c 금지)
# S5: claude 중복 실행 없음
# S6: repo-relative path, BASH_SOURCE 안전

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_LIB="$SKILL_ROOT/scripts/lib"
FIX_APPLY="$SKILL_LIB/fix-apply.sh"

declare -i PASS=0 FAIL=0

# ============================================================
# S1 — 모델이 만든 free-form 셸 명령은 실행되지 않는다
# ============================================================
echo "[S1] fix-apply.sh는 모델이 만든 셸 명령을 그대로 실행하지 않는다"

if grep -Eqn 'bash[[:space:]]-c[[:space:]]+"?\$cmd' "$FIX_APPLY" 2>/dev/null; then
  echo "  FAIL: 'bash -c \"\$cmd\"' 패턴이 코드에 남아있음"
  ((FAIL++))
else
  echo "  PASS: bash -c 패턴 없음"
  ((PASS++))
fi

# commands_to_run 인터페이스 — 정적 키로 모델에 권하지 않음
if grep -qnE '\.get\("commands_to_run' "$SKILL_LIB/failure-analyzer.sh" 2>/dev/null || \
   grep -qnE '"commands_to_run":[[:space:]]*\[' "$SKILL_LIB/failure-analyzer.sh" 2>/dev/null; then
  echo "  FAIL: 'commands_to_run' 활성 인터페이스가 존재"
  ((FAIL++))
else
  echo "  PASS: 'commands_to_run' 활성 인터페이스 제거됨"
  ((PASS++))
fi

# ============================================================
# S2 — fix/* prefix만 허용 (main, master 명시 거부)
# ============================================================
echo "[S2] fix/* prefix만 허용 + main/master 명시적 거부"

if grep -qE 'main\|master' "$FIX_APPLY" 2>/dev/null && \
   grep -qE 'main.*return 1|master.*return 1' "$FIX_APPLY" 2>/dev/null; then
  echo "  PASS: main, master 거부 코드 명시"
  ((PASS++))
else
  echo "  FAIL: main/master 거부 코드가 없음"
  ((FAIL++))
fi

if grep -qE 'fix/\[A-Za-z0-9' "$FIX_APPLY" 2>/dev/null; then
  echo "  PASS: fix/* prefix 검증 코드 존재"
  ((PASS++))
else
  echo "  FAIL: fix/* prefix 명시 검증 없음"
  ((FAIL++))
fi

# ============================================================
# S3 — 작업 트리에 기존 변경이 있으면 apply_fix 거부
# ============================================================
echo "[S3] 작업 트리에 기존 변경이 있으면 apply_fix 거부"

if grep -qE 'git[[:space:]]status.*--porcelain' "$FIX_APPLY" 2>/dev/null || \
   grep -qE 'ls-files[[:space:]]+--others' "$FIX_APPLY" 2>/dev/null; then
  echo "  PASS: unstaged/untracked 검사 코드 존재"
  ((PASS++))
else
  echo "  FAIL: 작업 디렉터리 clean 검증 코드 없음"
  ((FAIL++))
fi

if grep -qE 'git[[:space:]]+add[[:space:]]+-A\b' "$FIX_APPLY" 2>/dev/null; then
  echo "  FAIL: 'git add -A' 사용 — 모든 변경 커밋 위험"
  ((FAIL++))
else
  echo "  PASS: 'git add -A' 미사용"
  ((PASS++))
fi

# ============================================================
# S4 — Python 인터프레터는 JSON 인자만 받음 (python -c 금지)
# ============================================================
echo "[S4] Python -c로 JSON 보간 안 됨"

if grep -Eqn 'python3?[[:space:]]-c[[:space:]]+".*\$[a-z]' "$FIX_APPLY" 2>/dev/null; then
  echo "  FAIL: 'python3 -c \"... \$변수...\"' 인라인 보간 존재"
  ((FAIL++))
else
  echo "  PASS: python -c 보간 없음"
  ((PASS++))
fi

if [ -f "$SKILL_LIB/apply-change.py" ]; then
  echo "  PASS: apply-change.py 존재 (정적 스크립트)"
  ((PASS++))
else
  echo "  FAIL: apply-change.py 없음"
  ((FAIL++))
fi

# ============================================================
# S5 — claude 중복 실행 없음
# ============================================================
echo "[S5] claude \${cmd[@]} 중복 호출 없음 (in failure-analyzer.sh)"

FAIL_ANALYZER="$SKILL_LIB/failure-analyzer.sh"
if [ -f "$FAIL_ANALYZER" ]; then
  # cmd 배열의 첫 원소가 claude이면 안 됨
  cmd_block="$(awk '
    /cmd=\(/ {
      in_block = 1
    }
    in_block {
      print
      if (/\)/) exit
    }
  ' "$FAIL_ANALYZER")"

  if echo "$cmd_block" | grep -Eq 'claude'; then
    echo "  FAIL: cmd 배열의 첫 원소가 'claude' → 중복 호출 가능"
    ((FAIL++))
  else
    echo "  PASS: cmd 배열이 claude로 시작하지 않음"
    ((PASS++))
  fi

  # 호출 라인에서도 'claude ${cmd[@]}' 형태면 중복
  if grep -Eqn 'claude[[:space:]]+"?\$\{?cmd' "$FAIL_ANALYZER" 2>/dev/null; then
    echo "  FAIL: 호출 라인 'claude \${cmd[@]}' — 중복 claude 호출"
    ((FAIL++))
  else
    echo "  PASS: 호출 라인에서 claude 중복 없음"
    ((PASS++))
  fi
else
  echo "  SKIP: failure-analyzer.sh 없음"
fi

# ============================================================
# S6 — 저장소 상대 경로, BASH_SOURCE 안전
# ============================================================
echo "[S6] BASH_SOURCE [0] 안전성"

if grep -Eqn 'BASH_SOURCE\[[0-9]+\]:-?' "$FIX_APPLY" 2>/dev/null; then
  echo "  PASS: BASH_SOURCE [...]:- 기본값 사용"
  ((PASS++))
else
  echo "  FAIL: BASH_SOURCE이 set -u 환경에서 unbound 가능"
  ((FAIL++))
fi

if grep -qE '/Users/[a-z]+/' "$FIX_APPLY" 2>/dev/null; then
  echo "  FAIL: 절대경로 (/Users/...) 의존"
  ((FAIL++))
else
  echo "  PASS: 절대경로 의존 없음"
  ((PASS++))
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
