#!/usr/bin/env bash
# test-all.sh — 모든 회귀 테스트 한 번에 실행
#
# 사용법:
#   scripts/tests/test-all.sh           # 모든 테스트 실행
#   scripts/tests/test-all.sh --quick   # 빠른 검증만 (safety-check만)
#   scripts/tests/test-all.sh --list   # 실행 대상 나열

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 실행 대상 정의 (출력 순서대로)
TESTS=(
  "bash scripts/lib/safety-check.sh self-test"
  "bash scripts/tests/test-quick-mode-fallback.sh"
  "bash scripts/tests/test-fix-apply-redesign.sh"
  "bash scripts/tests/test-fix-apply-guards.sh"
  "bash scripts/tests/test-meta-agent-loop.sh"
  "bash scripts/tests/test-meta-aware-routing.sh"
  "bash scripts/tests/test-minimax-routing.sh"
  "bash scripts/tests/test-agent-default-models.sh"
  "bash scripts/tests/test-claude-health-subscription.sh"
  "bash scripts/tests/test-worktree-relative-path.sh"
  "bash scripts/tests/test-timeout-runner-cwd.sh"
  "bash scripts/tests/test-redactor.sh"
  "bash scripts/tests/test-python-cache-cleanup.sh"
  "bash scripts/tests/test-fix-apply-e2e.sh"
  "bash scripts/tests/test-ssot-shadow.sh"
  "bash scripts/tests/test-routing-source-ssot.sh"
  "bash scripts/tests/test-routing-ssot-sync.sh"
  "bash scripts/tests/test-await.sh"
  "bash scripts/tests/test-self-improvement.sh"
)

LABELS=(
  "safety-check (전체 모듈 lint)"
  "PR A: do_fallback verdict"
  "PR B: fix-apply redesign (P0/P1)"
  "PR B: fix-apply guards"
  "PR B: meta-agent 모듈"
  "meta-aware-routing (메타 에이전트 판단 기반 라우팅)"
  "minimax-routing"
  "agent-default-models (Bug #1 fix)"
  "claude-health-subscription (구독 로그인 인식)"
  "worktree-relative-path (Bug #2 fix)"
  "timeout-runner cwd"
  "PR B: redactor (secret 마스킹)"
  "python-cache-cleanup (커밋 전 pycache 정리)"
  "fix-apply e2e (git 통합)"
  "ssot-shadow (Phase 3 비침해 관찰)"
  "routing-source-ssot (Phase 4 토글)"
  "routing-ssot-sync (Phase 5 hardcode↔SSOT drift 감지)"
  "await 서브커맨드 (--detach 완료 블로킹 대기)"
  "self-improvement scan/dispatch safety"
)

# e2e 테스트는 격리 환경 의존성 (full SKILL) — 경고만 표시
E2E_TESTS=("scripts/tests/test-fix-apply-e2e.sh")

usage() {
  cat <<EOF
usage: $(basename "$0") [options]

옵션:
  (없음)        모든 테스트 실행
  --quick        빠른 검증만 (safety-check)
  --list         실행 대상만 나열
  --no-e2e       e2e 테스트 제외 (full SKILL env 필요)
  --help         이 도움말

종료 코드:
  0  모든 테스트 PASS
  1  하나 이상 FAIL
  2  사용법 오류
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --list)
    for i in "${!TESTS[@]}"; do printf "  [%d] %s — %s\n" "$((i+1))" "${TESTS[$i]}" "${LABELS[$i]}"; done
    exit 0 ;;
esac

declare -i TOTAL_PASS=0 TOTAL_FAIL=0
declare -a RESULTS=()

run_test() {
  local label="$1" cmd="$2"
  printf "[%s] %s\n" "$(date -u +%H:%M:%S)" "$label"

  local out
  if out="$(cd "$SKILL_DIR" && eval "$cmd" 2>&1)"; then
    local p
    p="$(printf '%s\n' "$out" | grep -cE '^\s*PASS\b|^=== .* (PASS|ok) ===$')"
    if [ "$p" -gt 0 ]; then
      RESULTS+=("PASS: $label")
      ((TOTAL_PASS++))
      printf "       ✓ %d assertions\n" "$p"
    else
      RESULTS+=("PASS: $label")
      ((TOTAL_PASS++))
      printf "       ✓\n"
    fi
  else
    local f
    f="$(printf '%s\n' "$out" | grep -cE '^\s*FAIL\b|^=== .* FAIL ===$')"
    RESULTS+=("FAIL: $label (${f:-0} failures)")
    ((TOTAL_FAIL++))
    printf "       ✗ FAILED — last 5 lines:\n"
    printf '%s\n' "$out" | tail -5 | sed 's/^/         /'
  fi
  printf '\n'
}

# 옵션 처리
declare -a RUN_TESTS=() RUN_LABELS=()
for i in "${!TESTS[@]}"; do
  test_path="${TESTS[$i]}"
  # --no-e2e: e2e 제외
  if [ "${1:-}" = "--no-e2e" ]; then
    case "$test_path" in
      *test-fix-apply-e2e.sh) continue ;;
    esac
  fi
  # --quick: safety-check만
  if [ "${1:-}" = "--quick" ]; then
    case "$test_path" in
      *safety-check*) : ;;
      *) continue ;;
    esac
  fi
  RUN_TESTS+=("$test_path")
  RUN_LABELS+=("${LABELS[$i]}")
done

# 잘못된 옵션
case "${1:-}" in
  ""|--all|--quick|--no-e2e) : ;;
  *) usage; exit 2 ;;
esac

if [ "${#RUN_TESTS[@]}" -eq 0 ]; then
  echo "(선택한 옵션으로 실행할 테스트가 없습니다)"
  exit 0
fi

echo "kant-looper 전체 회귀 테스트"
echo "  (SKILL_ROOT=$SKILL_DIR)"
echo "  $(printf '%s' "${RUN_TESTS[@]}" | wc -w | tr -d ' ') tests selected"
printf '\n'

for i in "${!RUN_TESTS[@]}"; do
  run_test "${RUN_LABELS[$i]}" "${RUN_TESTS[$i]}"
done

echo "================================"
printf "PASS: %d\n" "$TOTAL_PASS"
printf "FAIL: %d\n" "$TOTAL_FAIL"
echo "================================"

if [ "$TOTAL_FAIL" -gt 0 ]; then
  printf '\n[실패 항목]\n'
  for r in "${RESULTS[@]}"; do
    case "$r" in
      FAIL:*) printf "  ✗ %s\n" "$r" ;;
    esac
  done
  exit 1
fi
exit 0
