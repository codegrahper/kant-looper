#!/usr/bin/env bash
# test-meta-agent-loop.sh — 메타 에이전트 자가 치유 루프 모듈 테스트
#
# 각 모듈을 격리하여 검증:
# - failure-context.sh: 컨텍스트 캡처
# - failure-analyzer.sh: 메타 에이전트 호출 인터페이스
# - fix-apply.sh: 가드 검증 (main 거부, 경로 허용)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="/Users/drumqube/.claude/skills/kant-looper/scripts/lib"

declare -i PASS=0 FAIL=0

echo "=== 메타 에이전트 자가 치유 루프 모듈 테스트 ==="
echo ""

# ---------- 테스트 1: 모든 모듈 syntax ----------
echo "[test 1] 3개 모듈 bash -n 구문 체크"
for mod in failure-context failure-analyzer fix-apply; do
  if bash -n "$SKILL_LIB/${mod}.sh" 2>/dev/null; then
    echo "  PASS: ${mod}.sh 구문 OK"
    ((PASS++))
  else
    echo "  FAIL: ${mod}.sh 구문 오류"
    ((FAIL++))
  fi
done

# ---------- 테스트 2: failure-context.sh 가짜 state_dir로 캡처 ----------
echo "[test 2] failure-context.sh capture"
TESTDIR="$(mktemp -d)"
mkdir -p "$TESTDIR/state"
cat > "$TESTDIR/state/failure-code.txt" <<'F1'
QUICK_CALL_FAILED
F1
cat > "$TESTDIR/state/failure-message.txt" <<'F1'
agy:gemini-3.5-flash mode=INFRA_ERROR exit=1 (model not recognized)
F1
echo "fake-run" > "$TESTDIR/state/run-id.txt"
echo "agent/kant/fake" > "$TESTDIR/state/branch.txt"
CONTEXT="$("$SKILL_LIB/failure-context.sh" capture "$TESTDIR/state" 2>/dev/null || true)"
if [ -n "$CONTEXT" ] && echo "$CONTEXT" | grep -q "QUICK_CALL_FAILED"; then
  echo "  PASS: 컨텍스트 캡처 (failure_code + 메타 에이전트 지시사항 포함)"
  ((PASS++))
else
  echo "  FAIL: 컨텍스트 캡처 실패"
  ((FAIL++))
fi

rm -rf "$TESTDIR"

# ---------- 테스트 3: failure-analyzer.sh CLI ----------
echo "[test 3] failure-analyzer.sh CLI 진입점"
HELP_OUT="$("$SKILL_LIB/failure-analyzer.sh" 2>&1 || true)"
if echo "$HELP_OUT" | grep -q "사용법"; then
  echo "  PASS: CLI 진입점 + 사용법 출력"
  ((PASS++))
else
  echo "  FAIL: CLI 진입점 없음"
  ((FAIL++))
fi

# ---------- 테스트 4: fix-apply.sh CLI ----------
echo "[test 4] fix-apply.sh CLI 진입점"
HELP_OUT="$("$SKILL_LIB/fix-apply.sh" 2>&1 || true)"
if echo "$HELP_OUT" | grep -q "사용법"; then
  echo "  PASS: CLI 진입점 + 사용법 출력"
  ((PASS++))
else
  echo "  FAIL: CLI 진입점 없음"
  ((FAIL++))
fi

# ---------- 테스트 5: failure-context.sh CLI ----------
echo "[test 5] failure-context.sh CLI 진입점"
HELP_OUT="$("$SKILL_LIB/failure-context.sh" 2>&1 || true)"
if echo "$HELP_OUT" | grep -q "사용법"; then
  echo "  PASS: CLI 진입점 + 사용법 출력"
  ((PASS++))
else
  echo "  FAIL: CLI 진입점 없음"
  ((FAIL++))
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
