#!/usr/bin/env bash
# test-parallel-role-purity.sh — parallel reviewer role에 slice_id가 섞이는 회귀 방지
#
# scripts/ 전체를 임시 디렉터리에 복사하고, 복사본에 테스트 전용 adapter를
# 추가한다. mock adapter는 자신이 받은 role을 모델별 파일에 기록하므로,
# 병렬 worker 수와 slice_id가 달라도 role이 정확히 "review"인지 검증할 수 있다.

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
  local parallel_dir
  parallel_dir="$(cd "$(dirname "$prompt_file")" && pwd)"

  printf '%s\n' "$role" > "$parallel_dir/received-role-${model}.txt"
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

REPO="$TMP_ROOT/repo"
STATE="$TMP_ROOT/state"
TASK="$TMP_ROOT/task.md"
mkdir -p "$REPO" "$STATE"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" commit --allow-empty -qm initial
printf '# Task\n\n## 목표\nparallel role purity test\n' > "$TASK"

run_rc=0
if KANT_NOTIFY_OSASCRIPT=0 KANT_STATE_ROOT="$TMP_ROOT/kant-state" \
  "$KANT_LOOP" _run_mode parallel "$TASK" "$STATE" "$REPO" '' '' \
  'mockagent:m1,mockagent:m2,mockagent:m3' '' >/dev/null 2>&1; then
  run_rc=0
else
  run_rc=$?
fi

echo "[test 1] 모든 parallel worker는 slice_id 없는 순수한 review role을 받아야 한다"
roles_ok=1
for model in m1 m2 m3; do
  role_file="$STATE/parallel/received-role-${model}.txt"
  if [ ! -f "$role_file" ]; then
    echo "  FAIL: $model worker의 role 기록이 없음"
    roles_ok=0
    continue
  fi
  received_role="$(cat "$role_file")"
  if [ "$received_role" != "review" ]; then
    echo "  FAIL: $model worker가 role='$received_role'을 받음 (expected: review)"
    roles_ok=0
  fi
done
if [ "$roles_ok" = "1" ]; then echo "  PASS"; ((PASS++)); else ((FAIL++)); fi

echo "[test 2] 전부 PASS이고 worktree 변경이 없으면 parallel 모드는 정상 완료해야 한다"
result="$(cat "$STATE/result.txt" 2>/dev/null || echo MISSING)"
if [ "$run_rc" = "0" ] && [ "$result" = "pass_no_commit" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: exit=$run_rc result='$result'"
  ((FAIL++))
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
