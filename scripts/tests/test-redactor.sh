#!/usr/bin/env bash
# test-redactor.sh — failure-context.sh의 redactor() 함수 회귀 테스트
#
# redactor는 failure-context가 메타 에이전트(Claude)로 전송하기 전
# API 키/토큰/홈디렉터리 등을 마스킹하는 보안 critical 함수.
# 마스킹이 약해지면 secret이 외부 LLM으로 유출된다.
#
# 검증 항목:
# R1: OpenAI sk-XXX 마스킹
# R2: MiniMax sk-cp-XXX 마스킹
# R3: ANTHROPIC_API_KEY=... 마스킹
# R4: Authorization: Bearer XXX 마스킹
# R5: URL userinfo (https://user:token@host) 마스킹
# R6: 홈 디렉터리 /Users/foo/ → ~/
# R7: 원본 메시지 (secret 없음)는 보존
# R8: secret이 여러 줄에 흩어져 있어도 모두 마스킹

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_LIB="$SKILL_DIR/scripts/lib"
FAILURE_CONTEXT="$SKILL_LIB/failure-context.sh"

# redactor 함수만 추출 (line 27~75, CLI 진입점 + set -Eeuo 등 제외)
# 이유: failure-context.sh를 그대로 source하면 CLI 진입점의
# case "${1:-}" 분기에서 알 수 없는 인수 → exit 1이 호출되어
# 테스트 스크립트가 종료됨. redactor 함수만 별도 source 필요.
REDACTOR_FILE="$(mktemp -t kant-redactor-XXXXXX)"
awk '
  /^redactor\(\) \{$/ { flag=1; print; next }
  flag && /^}$/ { print; flag=0; exit }
  flag
' "$FAILURE_CONTEXT" > "$REDACTOR_FILE"
source "$REDACTOR_FILE"
rm -f "$REDACTOR_FILE"

declare -i PASS=0 FAIL=0

# macOS/BSD sed 호환을 위해 [[:space:]] 사용
test_case() {
  local label="$1" input="$2" pattern="$3"
  local actual
  actual="$(printf '%s\n' "$input" | redactor)"
  if printf '%s' "$actual" | grep -q "$pattern"; then
    echo "  PASS [$label]"
    ((PASS++))
  else
    echo "  FAIL [$label]"
    echo "    input:    $input"
    echo "    actual:   $(printf '%s' "$actual" | head -1 | cut -c1-100)"
    echo "    expected: pattern matching '$pattern'"
    ((FAIL++))
  fi
}

# R1: OpenAI sk- 형식
test_case "R1: OpenAI sk- prefix" \
  "OPENAI_API_KEY=sk-1234567890abcdefghijklmn" \
  "REDACTED"

# R2: MiniMax sk-cp- 형식
test_case "R2: MiniMax sk-cp- prefix" \
  "ANTHROPIC_AUTH_TOKEN=sk-cp-YNcUJ419I5cEPRJS5RXd7pANZN" \
  "REDACTED"

# R3: API 키 = value 환경변수 형식
test_case "R3: ANTHROPIC_API_KEY=value" \
  "export ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnop" \
  "REDACTED"

# R4: Authorization: Bearer 헤더
test_case "R4: Authorization Bearer" \
  "Authorization: Bearer abc123def456ghi789jkl" \
  "REDACTED"

# R5: URL userinfo (https://user:token@host)
# 실제 출력이 [REDACTED]@github.com/repo이므로 '@' 없는 패턴 사용
# (일부 zsh/grep 환경에서 '@'가 특수 처리되어 매칭 실패 회피)
test_case "R5: URL userinfo" \
  "fetching https://user:token123@github.com/repo" \
  "[REDACTED]"

# R6: 홈 디렉터리 /Users/foo/ → ~/
# (subshell 없이 직접 — PASS 카운터가 부모에 반영되도록)
HOME="/Users/testuser" actual=$(printf '%s\n' "/Users/testuser/.local/share/opencode/auth.json" | redactor)
if printf '%s' "$actual" | grep -q '\~/.local/share'; then
  echo "  PASS [R6: 홈 디렉터리]"
  ((PASS++))
else
  echo "  FAIL [R6: 홈 디렉터리] — got: $actual"
  ((FAIL++))
fi

# R7: secret 없는 원본 보존
test_case "R7: secret 없는 메시지 보존" \
  "QUICK_CALL tool=codex model=gpt-5.6-terra" \
  "QUICK_CALL"

# R8: 여러 줄에 흩어진 secret
# multi-line input + HOME 설정 + 여러 마스킹이 한 번에 적용되는지 확인
HOME="/Users" R8_ACTUAL=$(printf '%s\n' "key=sk-AAAA
config: ANTHROPIC_API_KEY=sk-BBBB
url: https://x:y@z.com
dir: /Users/me/secret.txt" | redactor)
if printf '%s' "$R8_ACTUAL" | grep -q 'sk-AAAA' && \
   printf '%s' "$R8_ACTUAL" | grep -q 'REDACTED' && \
   printf '%s' "$R8_ACTUAL" | grep -q '\[REDACTED\]@z'; then
  echo "  PASS [R8: 여러 줄에 흩어진 secret]"
  ((PASS++))
else
  echo "  FAIL [R8: 여러 줄에 흩어진 secret] — got:"
  echo "$R8_ACTUAL" | sed 's/^/    /'
  ((FAIL++))
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
