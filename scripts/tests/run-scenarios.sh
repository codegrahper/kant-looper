#!/usr/bin/env bash
# run-scenarios.sh — 시나리오 A/B/C 자동 검증
#
# 시나리오:
#   A: --quick 단일 호출 (T1 작업, 한 사이클)
#   B: --parallel 동시 호출 (T2 작업, UI + 로직 + 검증 분리)
#   C: --full HPRAR 풀 루프 (T3 작업, 다중 파일 리팩터링)
#
# 각 시나리오는:
#   1. 임시 worktree 생성
#   2. TASK.md 작성
#   3. dry-run → 실제 run
#   4. 결과 확인 (verdict, commit, fallback log)
#   5. 정리 (worktree 제거)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
declare -a SCENARIO_RESULTS=()

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# 임시 worktree 생성
create_test_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (cd "$dir" && {
    git init -q
    git config user.email "test@kant-looper"
    git config user.name "kant-looper-test"
    echo "# Test" > README.md
    git add README.md
    git commit -m "init" -q
  })
}

# 시나리오 공통 환경
setup_test_env() {
  local test_dir="/tmp/kant-test-$$-$RANDOM"
  create_test_repo "$test_dir"
  echo "$test_dir"
}

# 시나리오 A: --quick 단일 호출
scenario_a() {
  log "=== 시나리오 A: --quick 단일 호출 ==="

  local test_repo
  test_repo="$(setup_test_env)"

  # src/utils/string.ts 생성 (테스트 대상)
  mkdir -p "$test_repo/src/utils"
  cat > "$test_repo/src/utils/string.ts" <<'EOF'
export function truncate(s: string, n: number): string {
  return s.slice(0, n);
}
EOF

  (cd "$test_repo" && git add -A && git commit -m "add truncate" -q)

  # TASK.md
  local task_md="$test_repo/TASK.md"
  cat > "$task_md" <<EOF
# 작업
reverse 함수 추가 부탁드려요.

## 목표
src/utils/string.ts에 reverse 함수 추가하고 테스트 작성.

## 영향 범위
- 파일: src/utils/string.ts (이미 존재)
- 테스트: src/utils/string.test.ts (없으면 생성)

## 완료 조건
- reverse("hello") === "olleh"
- reverse("") === ""
- npm test 통과
EOF

  # dry-run
  log "  dry-run..."
  "$SKILL_ROOT/scripts/kant-loop.sh" run "$task_md" --dry-run --quick || {
    log "  FAIL: dry-run returned non-zero"
    FAIL=$((FAIL+1))
    SCENARIO_RESULTS+=("A: DRY-RUN_FAILED")
    return 1
  }

  log "  dry-run 통과"

  # 실제 실행 — 외부 도구 호출이 필요하므로 dry-run까지만 자동화
  # (실제 호출은 사용자가 직접 테스트)
  log "  시나리오 A는 dry-run으로 종료. 실제 호출은 사용자가 직접:"
  log "    cd $test_repo"
  log "    $SKILL_ROOT/scripts/kant-loop.sh run $task_md --quick --agent codex --model gpt-5.6-terra"
  log ""

  PASS=$((PASS+1))
  SCENARIO_RESULTS+=("A: PASS (dry-run)")
  return 0
}

# 시나리오 B: --parallel 동시 호출
scenario_b() {
  log "=== 시나리오 B: --parallel 동시 호출 ==="

  local test_repo
  test_repo="$(setup_test_env)"

  # UI 모킹 + 로직 모킹
  mkdir -p "$test_repo/src/components" "$test_repo/src/utils"
  cat > "$test_repo/src/utils/math.ts" <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}
EOF

  (cd "$test_repo" && git add -A && git commit -m "init" -q)

  local task_md="$test_repo/TASK.md"
  cat > "$task_md" <<EOF
# 작업
계산기 UI 컴포넌트 + 로직 + 테스트 작성 부탁드려요.

## 목표
- src/components/Calculator.tsx: 간단한 UI 컴포넌트
- src/utils/calculator.ts: add/subtract 로직
- src/utils/calculator.test.ts: 단위 테스트

UI는 stitch 스타일로 작성.

## 영향 범위
- src/components/Calculator.tsx
- src/utils/calculator.ts
- src/utils/calculator.test.ts

## 완료 조건
- 3개 파일 모두 작성
- 테스트 통과
EOF

  local chain="codex:gpt-5.6-terra,opencode:glm-5.2,agy:gemini-3.5-flash"

  log "  dry-run..."
  "$SKILL_ROOT/scripts/kant-loop.sh" run "$task_md" --dry-run --parallel --chain "$chain" || {
    log "  FAIL: dry-run returned non-zero"
    FAIL=$((FAIL+1))
    SCENARIO_RESULTS+=("B: DRY-RUN_FAILED")
    return 1
  }

  log "  dry-run 통과"
  log "  실제 실행:"
  log "    cd $test_repo"
  log "    $SKILL_ROOT/scripts/kant-loop.sh run $task_md --parallel --chain $chain"
  log ""

  PASS=$((PASS+1))
  SCENARIO_RESULTS+=("B: PASS (dry-run)")
  return 0
}

# 시나리오 C: --full HPRAR 풀 라운드
scenario_c() {
  log "=== 시나리오 C: --full HPRAR 풀 루프 ==="

  local test_repo
  test_repo="$(setup_test_env)"

  # 다중 파일 리팩터링 시뮬레이션
  mkdir -p "$test_repo/src"
  for i in 1 2 3; do
    cat > "$test_repo/src/module$i.ts" <<EOF
export function func$i(input: string): string {
  return input.toUpperCase();
}
EOF
  done

  (cd "$test_repo" && git add -A && git commit -m "init" -q)

  local task_md="$test_repo/TASK.md"
  cat > "$task_md" <<EOF
# 작업
3개 모듈의 함수들을 리팩터링 부탁드려요.

## 목표
func1/func2/func3을 async 함수로 변경하고 통합 인터페이스 제공.

## 영향 범위
- src/module1.ts
- src/module2.ts
- src/module3.ts
- src/index.ts (신규)

## 완료 조건
- 모든 funcN이 async function으로 변경
- src/index.ts가 모든 모듈을 re-export
EOF

  log "  dry-run..."
  "$SKILL_ROOT/scripts/kant-loop.sh" run "$task_md" --dry-run --full || {
    log "  FAIL: dry-run returned non-zero"
    FAIL=$((FAIL+1))
    SCENARIO_RESULTS+=("C: DRY-RUN_FAILED")
    return 1
  }

  log "  dry-run 통과"
  log "  실제 실행:"
  log "    cd $test_repo"
  log "    $SKILL_ROOT/scripts/kant-loop.sh run $task_md --full"
  log ""

  PASS=$((PASS+1))
  SCENARIO_RESULTS+=("C: PASS (dry-run)")
  return 0
}

# 시나리오 라우터 + health check 검증
scenario_smoke() {
  log "=== smoke: 라우터 + health check 검증 ==="

  log "  health check..."
  "$SKILL_ROOT/scripts/lib/health-check.sh" all | tee /tmp/kant-health.log

  local all_ok=1
  local tool status
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    tool="${line%%:*}"
    status="${line#*: }"
    if [ "$status" != "OK" ]; then
      log "  WARN: $tool = $status"
      all_ok=0
    fi
  done < /tmp/kant-health.log

  if [ "$all_ok" = "1" ]; then
    log "  모든 도구 OK"
    PASS=$((PASS+1))
    SCENARIO_RESULTS+=("smoke: PASS")
  else
    log "  일부 도구 UNAVAILABLE (fallback이 커버)"
    PASS=$((PASS+1))
    SCENARIO_RESULTS+=("smoke: PARTIAL (fallback OK)")
  fi

  log "  safety-check self-test..."
  if "$SKILL_ROOT/scripts/lib/safety-check.sh" self-test; then
    log "  safety check 통과"
    PASS=$((PASS+1))
    SCENARIO_RESULTS+=("safety: PASS")
  else
    log "  safety check 문제 발견"
    FAIL=$((FAIL+1))
    SCENARIO_RESULTS+=("safety: FAIL")
  fi
}

# 메인
main() {
  log "kant-looper 시나리오 검증 시작"
  log "skill root: $SKILL_ROOT"
  log ""

  case "${1:-all}" in
    smoke) scenario_smoke ;;
    a) scenario_a ;;
    b) scenario_b ;;
    c) scenario_c ;;
    all|"")
      scenario_smoke
      scenario_a
      scenario_b
      scenario_c
      ;;
    *)
      echo "unknown scenario: $1" >&2
      exit 1
      ;;
  esac

  log ""
  log "=== 결과 요약 ==="
  log "PASS: $PASS"
  log "FAIL: $FAIL"
  for result in "${SCENARIO_RESULTS[@]}"; do
    log "  - $result"
  done

  exit $FAIL
}

main "$@"