#!/usr/bin/env bash
# test-await.sh — kant-loop.sh await 서브커맨드 검증
#
# 검증 대상:
#   await RUN_ID: result.txt 폴링 → 완료 시 cmd_status 요약 출력
#   종료 코드 체계: completed/pass_no_commit → 0 / failed → 1 / timeout → 2
#   --timeout, --interval 옵션 파싱 (양의 정수 검증)
#   존재하지 않는 run-id → exit 1, 명확한 에러
#   결과 미작성 중간에 외부에서 completed 쓰기 → await가 폴링으로 감지해 exit 0
#   기존 run/status/--detach 동작 회귀 없음 (await는 순수 추가)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"

declare -i PASS=0 FAIL=0

[ -f "$KANT_LOOP" ] || { echo "FAIL: $KANT_LOOP not found"; exit 1; }

TEST_ROOT="/tmp/kant-await-test-$$"
export KANT_STATE_ROOT="$TEST_ROOT"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

RH=$(printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-12)

setup_run() {
  local rid="$1" result="$2"
  local sd="$TEST_ROOT/$RH/$rid"
  mkdir -p "$sd"
  [ -n "$result" ] && echo "$result" > "$sd/result.txt"
  echo "agent/kant/$rid" > "$sd/branch.txt"
  echo "/tmp/wt-$rid" > "$sd/worktree.txt"
  if [ "$result" = "completed" ]; then
    echo "deadbeef$rid" > "$sd/commit-sha.txt"
  fi
  if [ "$result" = "failed" ]; then
    echo "QUICK_CALL_FAILED" > "$sd/failure-code.txt"
    echo "boom-$rid" > "$sd/failure-message.txt"
  fi
}

# ─────────────────────────────────────────
echo "[test 1] 존재하지 않는 run-id → exit 1, 명확한 에러"

output=$("$KANT_LOOP" await "no-such-run-xyz" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$output" | grep -q "run not found: no-such-run-xyz"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc output='$output'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 2] result=completed → exit 0, status 요약"

setup_run "run-completed" "completed"
output=$("$KANT_LOOP" await "run-completed" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -q "run_id: run-completed" && printf '%s' "$output" | grep -q "result: completed" && printf '%s' "$output" | grep -q "commit: deadbeef"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc"; printf '%s\n' "$output" | head -5; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 3] result=pass_no_commit → exit 0"

setup_run "run-pass-nc" "pass_no_commit"
output=$("$KANT_LOOP" await "run-pass-nc" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -q "result: pass_no_commit"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc"; printf '%s\n' "$output" | head -5; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 4] result=failed → exit 1, failure-code 출력"

setup_run "run-failed" "failed"
output=$("$KANT_LOOP" await "run-failed" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$output" | grep -q "result: failed" && printf '%s' "$output" | grep -q "failure: QUICK_CALL_FAILED"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc"; printf '%s\n' "$output" | head -5; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 5] result.txt 미작성 + 짧은 --timeout → exit 2"

RID_TIMEOUT="run-timeout"
mkdir -p "$TEST_ROOT/$RH/$RID_TIMEOUT"
start=$(date +%s)
output=$("$KANT_LOOP" await "$RID_TIMEOUT" --timeout 2 --interval 1 2>&1)
rc=$?
end=$(date +%s)
elapsed=$((end - start))
if [ "$rc" -eq 2 ] && printf '%s' "$output" | grep -q "TIMEOUT" && [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 4 ]; then echo "  PASS (${elapsed}s)"; ((PASS++)); else echo "  FAIL: rc=$rc elapsed=${elapsed}s"; printf '%s\n' "$output" | head -3; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 6] --timeout 비정수 → exit 1"

output=$("$KANT_LOOP" await "run-completed" --timeout abc 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$output" | grep -q "must be a positive integer"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc"; printf '%s\n' "$output" | head -3; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 7] --interval 0 → exit 1"

output=$("$KANT_LOOP" await "run-completed" --interval 0 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$output" | grep -q "must be > 0"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc"; printf '%s\n' "$output" | head -3; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 8] 인자 없음 → exit 1, usage"

output=$("$KANT_LOOP" await 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$output" | grep -q "usage: kant-loop.sh await"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc"; printf '%s\n' "$output" | head -3; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 9] --help → exit 0, 옵션 설명"

output=$("$KANT_LOOP" await --help 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -q "usage: kant-loop.sh await" && printf '%s' "$output" | grep -q -- "--timeout N"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc"; printf '%s\n' "$output" | head -3; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 10] 라이브 폴링: 중간에 completed 쓰기 → await 감지 exit 0"

RID_LIVE="run-live"
SD_LIVE="$TEST_ROOT/$RH/$RID_LIVE"
mkdir -p "$SD_LIVE"
(
  sleep 3
  echo "completed" > "$SD_LIVE/result.txt"
  echo "agent/kant/$RID_LIVE" > "$SD_LIVE/branch.txt"
) &
WRITER_PID=$!
start=$(date +%s)
output=$("$KANT_LOOP" await "$RID_LIVE" --timeout 30 --interval 1 2>&1)
rc=$?
end=$(date +%s)
elapsed=$((end - start))
wait $WRITER_PID 2>/dev/null
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -q "result: completed" && [ "$elapsed" -ge 3 ] && [ "$elapsed" -le 6 ]; then echo "  PASS (${elapsed}s)"; ((PASS++)); else echo "  FAIL: rc=$rc elapsed=${elapsed}s"; printf '%s\n' "$output" | head -5; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 11] 기존 status 서브커맨드 회귀 — 동일 run-id에서 정상 동작"

existing=$(scripts/kant-loop.sh status "run-completed" 2>&1)
rc_e=$?
if [ "$rc_e" -eq 0 ] && printf '%s' "$existing" | grep -q "run_id: run-completed" && printf '%s' "$existing" | grep -q "commit: deadbeef"; then echo "  PASS"; ((PASS++)); else echo "  FAIL: rc=$rc_e"; printf '%s\n' "$existing" | head -3; ((FAIL++)); fi

rm -rf "$TEST_ROOT"

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]