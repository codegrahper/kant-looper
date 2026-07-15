#!/usr/bin/env bash
# test-ssot-shadow.sh — SSOT 섀도우 모드 검증 (Phase 3/5)
#
# 검증 대상:
#   ssot-shadow.sh 함수 정의 (ssot_shadow_check_env, ssot_shadow_observe)
#   ssot_loader.py 서브커맨드 응답 (route-for-task, chain-for-route, health)
#   KANT_SHADOW_MODE=off → 로그 파일 생성 안 됨 (fail-safe)
#   KANT_SHADOW_MODE=on  → 로그 파일 생성됨
#   로더 크래시 → 조용히 무시됨 (|| true 전파)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_LIB="$SKILL_ROOT/scripts/lib"
SHADOW_LIB="$SKILL_LIB/ssot-shadow.sh"
SSOT_LOADER="$SKILL_LIB/ssot_loader.py"
SSOT_YAML="$SKILL_ROOT/routing-ssot/routing-ssot.yaml"

declare -i PASS=0 FAIL=0

# ─────────────────────────────────────────
# 대상 파일 존재 확인
# ─────────────────────────────────────────
for f in "$SHADOW_LIB" "$SSOT_LOADER" "$SSOT_YAML"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: file not found: $f"
    exit 1
  fi
done

# ─────────────────────────────────────────
# Test 1 — ssot-shadow.sh 함수 정의 존재
# ─────────────────────────────────────────
echo "[test 1] ssot-shadow.sh 함수 정의 존재"

source "$SHADOW_LIB"

if type ssot_shadow_check_env &>/dev/null && type ssot_shadow_observe &>/dev/null; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: required functions not defined"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 2 — KANT_SHADOW_MODE 미설정 → check_env 실패
# ─────────────────────────────────────────
echo "[test 2] KANT_SHADOW_MODE 미설정 → check_env return 1"

unset KANT_SHADOW_MODE
if ssot_shadow_check_env; then
  echo "  FAIL: check_env should return 1 when KANT_SHADOW_MODE unset"
  ((FAIL++))
else
  echo "  PASS"
  ((PASS++))
fi

# ─────────────────────────────────────────
# Test 3 — KANT_SHADOW_MODE=on → check_env 성공
# ─────────────────────────────────────────
echo "[test 3] KANT_SHADOW_MODE=on → check_env return 0"

KANT_SHADOW_MODE=on
if ssot_shadow_check_env; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: check_env should return 0 when KANT_SHADOW_MODE=on"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 4 — 섀도우 OFF → 로그 파일 생성 안 됨
# ─────────────────────────────────────────
echo "[test 4] 섀도우 OFF → 로그 파일 미생성 (fail-safe)"

unset KANT_SHADOW_MODE
TEST_LOG="/tmp/test-ssot-shadow-off-$$.log"
rm -f "$TEST_LOG"
export KANT_SHADOW_LOG="$TEST_LOG"

ssot_shadow_observe "test-intent" "standard" "codex:gpt-5.6-terra" "test"

if [ -f "$TEST_LOG" ]; then
  echo "  FAIL: log file created when shadow OFF: $TEST_LOG"
  ((FAIL++))
  rm -f "$TEST_LOG"
else
  echo "  PASS"
  ((PASS++))
fi

# ─────────────────────────────────────────
# Test 5 — 섀도우 ON → 로그 파일 생성됨
# ─────────────────────────────────────────
echo "[test 5] 섀도우 ON → 로그 파일 생성"

KANT_SHADOW_MODE=on
TEST_LOG="/tmp/test-ssot-shadow-on-$$.log"
rm -f "$TEST_LOG"
export KANT_SHADOW_LOG="$TEST_LOG"

ssot_shadow_observe "test-intent" "standard" "codex:gpt-5.6-terra" "test-pass"

if [ -f "$TEST_LOG" ] && [ -s "$TEST_LOG" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: log file not created or empty"
  ((FAIL++))
fi
rm -f "$TEST_LOG"

# ─────────────────────────────────────────
# Test 6 — ssot_loader.py health 서브커맨드
# ─────────────────────────────────────────
echo "[test 6] ssot_loader.py health 응답"

health_output="$(python3 "$SSOT_LOADER" health 2>/dev/null || true)"
health_status="$(printf '%s' "$health_output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")"

if [ "$health_status" = "ok" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: health status='$health_status' output='$health_output'"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 7 — ssot_loader.py route-for-task 응답
# ─────────────────────────────────────────
echo "[test 7] ssot_loader.py route-for-task standard 응답"

route_output="$(python3 "$SSOT_LOADER" route-for-task --intent="implement" --complexity="standard" 2>/dev/null || true)"
route_ssot="$(printf '%s' "$route_output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ssot_route',''))" 2>/dev/null || echo "")"

if [ "$route_ssot" = "standard_repo" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: ssot_route='$route_ssot' (expected standard_repo)"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 8 — 로더 크래시 → 조용히 무시됨
# ─────────────────────────────────────────
echo "[test 8] 로더 크래시 (존재하지 않는 라우트) → 조용히 무시"

KANT_SHADOW_MODE=on
TEST_LOG="/tmp/test-ssot-shadow-crash-$$.log"
rm -f "$TEST_LOG"
export KANT_SHADOW_LOG="$TEST_LOG"

ssot_shadow_observe "test-intent" "NONEXISTENT_ROUTE_XYZ" "codex:test" "test" 2>/dev/null

if [ ! -s "$TEST_LOG" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: log written despite invalid route"
  ((FAIL++))
fi
rm -f "$TEST_LOG"

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
