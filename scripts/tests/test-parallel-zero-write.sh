#!/usr/bin/env bash
# test-parallel-zero-write.sh — parallel reviewer의 zero-write 안전장치 회귀 방지
#
# scripts/ 전체를 임시 디렉터리에 복사하고 테스트 전용 adapter를 추가한다.
# clean 시나리오와 reviewer 하나가 worktree를 더럽히는 시나리오를 각각
# 실제 _run_mode parallel 경로로 실행해 PARALLEL_WRITE_DETECTED를 검증한다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

declare -i PASS=0 FAIL=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

cp -r "$SKILL_ROOT/scripts" "$TMP_ROOT/scripts"
KANT_LOOP="$TMP_ROOT/scripts/kant-loop.sh"
MOCK_ADAPTER="$TMP_ROOT/scripts/adapters/adapter-mockagent.sh"

cat > "$MOCK_ADAPTER" <<'MOCKEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"

  if [ "$model" = "m2" ] && [ "${MOCK_DISABLE_WRITE:-0}" != "1" ]; then
    echo dirty > "$worktree/dirty-file.txt"
  fi
  echo "PASS|ok"
}

case "${1:-}" in
  call) shift; call "$@" ;;
  health) echo "OK" ;;
  version) echo "mock-1.0" ;;
  *) exit 1 ;;
esac
MOCKEOF
chmod +x "$MOCK_ADAPTER"

TASK="$TMP_ROOT/task.md"
printf '# Task\n\n## 목표\nparallel zero-write test\n' > "$TASK"

setup_repo() {
  local repo="$1" state="$2"
  mkdir -p "$repo" "$state"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  git -C "$repo" commit --allow-empty -qm initial
}

run_parallel() {
  local repo="$1" state="$2" workers="$3"
  KANT_NOTIFY_OSASCRIPT=0 KANT_STATE_ROOT="$TMP_ROOT/kant-state" \
    "$KANT_LOOP" _run_mode parallel "$TASK" "$state" "$repo" '' '' \
    "$workers" '' >/dev/null 2>&1
}

CLEAN_REPO="$TMP_ROOT/clean-repo"
CLEAN_STATE="$TMP_ROOT/clean-state"
setup_repo "$CLEAN_REPO" "$CLEAN_STATE"

clean_rc=0
if run_parallel "$CLEAN_REPO" "$CLEAN_STATE" 'mockagent:m1'; then
  clean_rc=0
else
  clean_rc=$?
fi

echo "[scenario A] reviewer가 쓰지 않으면 pass_no_commit으로 정상 완료해야 한다"
clean_result="$(cat "$CLEAN_STATE/result.txt" 2>/dev/null || echo MISSING)"
if [ "$clean_rc" = "0" ] && [ "$clean_result" = "pass_no_commit" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: exit=$clean_rc result='$clean_result'"
  ((FAIL++))
fi

echo "[scenario A] 정상 완료에는 failure-code.txt가 없어야 한다"
if [ ! -e "$CLEAN_STATE/failure-code.txt" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: failure-code='$(cat "$CLEAN_STATE/failure-code.txt")'"
  ((FAIL++))
fi

DIRTY_REPO="$TMP_ROOT/dirty-repo"
DIRTY_STATE="$TMP_ROOT/dirty-state"
setup_repo "$DIRTY_REPO" "$DIRTY_STATE"

dirty_rc=0
if run_parallel "$DIRTY_REPO" "$DIRTY_STATE" 'mockagent:m1,mockagent:m2,mockagent:m3'; then
  dirty_rc=0
else
  dirty_rc=$?
fi

echo "[scenario B] reviewer 하나가 파일을 써도 PASS verdict를 내면 실행은 실패해야 한다"
if [ "$dirty_rc" -ne 0 ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: dirty reviewer 실행이 exit=0으로 성공함"
  ((FAIL++))
fi

echo "[scenario B] 실패 코드는 정확히 PARALLEL_WRITE_DETECTED여야 한다"
failure_code="$(cat "$DIRTY_STATE/failure-code.txt" 2>/dev/null || echo MISSING)"
if [ "$failure_code" = "PARALLEL_WRITE_DETECTED" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: failure-code='$failure_code'"
  ((FAIL++))
fi

echo "[scenario B] 쓰기 감지 실패가 pass_no_commit으로 둔갑하지 않아야 한다"
dirty_result="$(cat "$DIRTY_STATE/result.txt" 2>/dev/null || echo MISSING)"
if [ "$dirty_result" != "pass_no_commit" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: result='$dirty_result'"
  ((FAIL++))
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
