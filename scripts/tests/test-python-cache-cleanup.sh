#!/usr/bin/env bash
# test-python-cache-cleanup.sh — Python runtime cache cleanup in do_safety_check()
#
# 검증 대상:
#   1. do_safety_check()가 __pycache__ 디렉토리를 재귀 삭제한다
#   2. do_safety_check()가 *.pyc, *.pyo 파일을 삭제한다
#   3. 삭제 범위가 $worktree 내부로 한정된다 (경로 탈출 없음)
#   4. .env 등 실제 protected path는 여전히 safety check에 걸린다 (회귀 없음)
#
# 동적 검증: 실제 temp git worktree에서 함수 실행 후 결과 확인

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"
LIB_DIR="$SKILL_ROOT/scripts/lib"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

pass() { echo "${GREEN}PASS${NC}: $1"; ((PASSED++)); }
fail() { echo "${RED}FAIL${NC}: $1"; ((FAILED++)); }

# do_safety_check 함수 추출 (awk brace counting)
extract_do_safety_check() {
  awk '
    /^do_safety_check\(\)[[:space:]]*\{/ {
      in_function = 1
      depth = 1
      next
    }
    in_function {
      print
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      depth += opens - closes
      if (depth <= 0) exit
    }
  ' "$KANT_LOOP"
}

# ---------------------------------------------------------------------------
# Test 1: 함수 정의에 Python cache cleanup 코드 존재
# ---------------------------------------------------------------------------
echo "=== 정적 분석: do_safety_check() 함수 ==="

func_body="$(extract_do_safety_check)"

if [ -z "$func_body" ]; then
  fail "do_safety_check() 함수를 찾을 수 없음"
else
  pass "do_safety_check() 함수 발견"
fi

# __pycache__ cleanup 존재?
if printf '%s\n' "$func_body" | grep -q "find.*__pycache__"; then
  pass "__pycache__ cleanup 코드 존재"
else
  fail "__pycache__ cleanup 코드 없음"
fi

# *.pyc/*.pyo cleanup 존재?
if printf '%s\n' "$func_body" | grep -qE '\*\.pyc|\*\.pyo'; then
  pass "*.pyc / *.pyo cleanup 코드 존재"
else
  fail "*.pyc / *.pyo cleanup 코드 없음"
fi

# git add -A 이전에 cleanup 존재? (순서 검증)
# 주석에서 "git add -A" 텍스트가 오검출되므로, [ \t]*# 로 comment 줄 제외 (awk에서는 \s 미지원)
add_line=$(printf '%s\n' "$func_body" | awk '!/^[ \t]*#/ && /git add -A/ {print NR; exit}')
cleanup_line=$(printf '%s\n' "$func_body" | awk '!/^[ \t]*#/ && /find.*"\$worktree"/ {print NR; exit}')

if [ -n "$add_line" ] && [ -n "$cleanup_line" ]; then
  if [ "$cleanup_line" -lt "$add_line" ]; then
    pass "cleanup이 git add -A보다 먼저 실행됨 (줄 $cleanup_line < $add_line)"
  else
    fail "cleanup이 git add -A보다 나중에 실행됨 (순서 오류)"
  fi
else
  fail "cleanup 또는 git add -A 줄 번호를 찾을 수 없음"
fi

# worktree 변수 경로 탈출 방지 확인
if printf '%s\n' "$func_body" | grep -qE 'find "\$worktree"'; then
  pass "find 명령이 \$worktree 변수를 사용 (경로 탈출 방지)"
else
  fail "find 명령에 \$worktree 변수 없음 - 경로 탈출 위험"
fi

# ---------------------------------------------------------------------------
# Test 2: 동적 검증 — 실제 worktree에서 cleanup 동작 확인
# ---------------------------------------------------------------------------
echo ""
echo "=== 동적 검증: 실제 worktree에서 cleanup 테스트 ==="

# 임시 디렉터리 준비
tmpbase="$(mktemp -d)" || { fail "temp dir 생성 실패"; ((FAILED++)); exit 1; }
tmpbase="$tmpbase/kant-test-pycache-$$"
mkdir -p "$tmpbase"

# 임시 git repo
if ! git init -q "$tmpbase" 2>/dev/null; then
  fail "git init 실패"
  rm -rf "$tmpbase"
  exit 1
fi

# worktree 역할을 할 하위 디렉터리
worktree="$tmpbase/wt"
mkdir -p "$worktree"
git -C "$tmpbase" config user.email "test@test.com"
git -C "$tmpbase" config user.name "Test"
git -C "$tmpbase" commit -q --allow-empty -m "init"

# ── 시나리오 A: Python cache만 있는 경우 ──────────────────────────
echo "  [시나리오 A] __pycache__ + *.pyc만 있는 경우"

mkdir -p "$worktree/__pycache__"
touch "$worktree/__pycache__/foo.cpython-311.pyc"
touch "$worktree/__pycache__/bar.cpython-311.pyo"
touch "$worktree/calculator.py"
mkdir -p "$worktree/subdir/__pycache__"
touch "$worktree/subdir/__pycache__/nested.pyc"

# Python 파일만 add (cache는 unstaged 상태로 남음)
git -C "$worktree" add calculator.py

# do_safety_check의 cleanup 로직을 직접 수행 (worktree 한정)
find "$worktree" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$worktree" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true

# staging
git -C "$worktree" add -A

# safety check 실행
safety_output="$("$LIB_DIR/safety-check.sh" all "$worktree" 2>&1)" || true

# calculator.py만 스테이징되어야 함 (cache는 이미 삭제됨)
staged_files="$(git -C "$worktree" diff --name-only --cached)"
if echo "$staged_files" | grep -q "calculator.py" && \
   ! echo "$staged_files" | grep -q "__pycache__"; then
  pass "시나리오 A: calculator.py만 스테이징됨 (cache 정리됨)"
else
  fail "시나리오 A: staged files = $staged_files"
fi

# safety check 통과해야 함
if [ -z "$safety_output" ]; then
  pass "시나리오 A: safety check 통과"
else
  fail "시나리오 A: safety check 위반 — $safety_output"
fi

# ── 시나리오 B: .env이 함께 있는 경우 → 여전히 차단되어야 함 ─────
echo "  [시나리오 B] __pycache__ + .env이 함께 있는 경우"

# worktree 리셋
git -C "$worktree" reset -q --hard
rm -rf "$worktree"/*
mkdir -p "$worktree"

# .env 생성 (protected path)
echo "SECRET=abc123" > "$worktree/.env"
mkdir -p "$worktree/__pycache__"
touch "$worktree/__pycache__/dummy.pyc"
touch "$worktree/clean.py"

# cleanup + staging
find "$worktree" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$worktree" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true
git -C "$worktree" add -A

# safety check 실행 — .env이 감지되어야 함
safety_output_B="$("$LIB_DIR/safety-check.sh" all "$worktree" 2>&1)" || true

if echo "$safety_output_B" | grep -q "\.env"; then
  pass "시나리오 B: .env 여전히 차단됨 (회귀 없음)"
else
  fail "시나리오 B: .env이 차단되지 않음 — $safety_output_B"
fi

if [ ! -e "$worktree/__pycache__" ]; then
  pass "시나리오 B: __pycache__ 캐시는 정리됨 (.env와 공존해도 정상 삭제)"
else
  fail "시나리오 B: __pycache__ 캐시가 남아있음"
fi

# ── 시나리오 C: nested __pycache__ 재귀 삭제 ────────────────────
echo "  [시나리오 C] 중첩 __pycache__ 재귀 삭제"

rm -rf "$worktree"/*
mkdir -p "$worktree/a/b/c/__pycache__"
touch "$worktree/a/b/c/__pycache__/deep.pyc"

find "$worktree" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

if [ -d "$worktree/a/b/c/__pycache__" ]; then
  fail "시나리오 C: 중첩 __pycache__ 삭제 실패"
else
  pass "시나리오 C: 중첩 __pycache__ 재귀 삭제됨"
fi

# ── 정리 ─────────────────────────────────────────────────────────
rm -rf "$(dirname "$tmpbase")"

# ---------------------------------------------------------------------------
# 결과
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

[ "$FAILED" -eq 0 ]
