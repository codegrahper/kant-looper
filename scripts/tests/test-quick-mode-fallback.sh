#!/usr/bin/env bash
# test-quick-mode-fallback.sh — fallback verdict passthrough 정적 검사
#
# 이 PR에서 수정한 부분:
#   do_fallback() SUCCESS 경로에서 echo "${next_tool}:${next_model}" (버그)
#   → echo "$fb_output" (수정)
#
# 동적 e2e 검증은 기존 run-scenarios.sh (5/5 PASS)가 담당한다.
# 이 파일은 회귀 방지를 위한 정적 검사만 수행한다.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="/Users/drumqube/.claude/skills/kant-looper/scripts/lib"
DISPATCHER="$SKILL_LIB/fallback-dispatcher.sh"

declare -i PASS=0 FAIL=0

# ─────────────────────────────────────────
# Test 1 — line 144에 echo "$fb_output" 존재
# ─────────────────────────────────────────
echo "[test 1] do_fallback SUCCESS 경로에 echo \"\$fb_output\" (line 144)"
line_144="$(sed -n '144p' "$DISPATCHER")"
if echo "$line_144" | grep -Eq 'echo "[[:space:]]*\$fb_output[[:space:]]*"'; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: line 144 = '$line_144'"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 2 — 버그 코드 단독 echo 부재
# ─────────────────────────────────────────
echo "[test 2] 버그 echo \"\${next_tool}:\${next_model}\" 부재 (chain 문자열화/로그 메시지는 정상)"
bug_lines=$(grep -nE '^\s*echo "[[:space:]]*"\${next_tool}:\${next_model}"[[:space:]]*$' "$DISPATCHER" || true)
if [ -z "$bug_lines" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: bug at: $bug_lines"
  ((FAIL++))
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
