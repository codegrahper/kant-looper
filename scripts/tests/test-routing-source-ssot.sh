#!/usr/bin/env bash
# test-routing-source-ssot.sh — KANT_ROUTING_SOURCE=ssot 토글 검증 (Phase 4)
#
# 검증 대상:
#   KANT_ROUTING_SOURCE 미설정/비-ssot → ssot_resolve_* 함수 return 1
#   KANT_ROUTING_SOURCE=ssot + 좋은 입력 → tool:model/chain 반환
#   _get_route_candidate SSOT 모드 ssot_primary 우선 사용
#   get_fallback_chain SSOT 모드 ssot_chain 우선 사용
#   hardcode↔ssot 전환 즉시 복귀 가능
#   safety net 변환: claude:claude-default → claude:default

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_LIB="$SKILL_ROOT/scripts/lib"
SHADOW_LIB="$SKILL_LIB/ssot-shadow.sh"
ROUTING_PARSER="$SKILL_LIB/routing-parser.sh"
FALLBACK_DISPATCHER="$SKILL_LIB/fallback-dispatcher.sh"

declare -i PASS=0 FAIL=0

for f in "$SHADOW_LIB" "$ROUTING_PARSER" "$FALLBACK_DISPATCHER"; do
  [ -f "$f" ] || { echo "FAIL: file not found: $f"; exit 1; }
done

mkdir -p /tmp/kant-p4-test
TASK="/tmp/kant-p4-test/TASK.md"
cat > "$TASK" <<'EOF'
# Test Task
## 목표
Test standard routing.
EOF

# ─────────────────────────────────────────
echo "[test 1] KANT_ROUTING_SOURCE 미설정 → ssot_resolve_route_primary return 1"

unset KANT_ROUTING_SOURCE
KANT_SHADOW_MODE=on bash -c "
  source '$SHADOW_LIB'
  if ssot_resolve_route_primary 'standard' 2>/dev/null; then
    echo 'UNEXPECTED_SUCCESS'
  fi
" | grep -q UNEXPECTED_SUCCESS
if [ $? -ne 0 ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 2] KANT_ROUTING_SOURCE=ssot → ssot_resolve_route_primary 반환"

result=$(KANT_SHADOW_MODE=on KANT_ROUTING_SOURCE=ssot bash -c "
  source '$SHADOW_LIB'
  ssot_resolve_route_primary 'standard'
" 2>/dev/null)
if [ "$result" = "codex:gpt-5.6-terra" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: got '$result'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 3] hardcode 모드 routing-parser match 기존 동작 유지"

result=$(scripts/lib/routing-parser.sh match "$TASK" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)
if [ "$result" = "codex:gpt-5.6-terra" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: got '$result'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 4] SSOT 모드 routing-parser match 동일 결과"

result=$(KANT_ROUTING_SOURCE=ssot scripts/lib/routing-parser.sh match "$TASK" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)
if [ "$result" = "codex:gpt-5.6-terra" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: got '$result'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 5] hardcode fallback chain 형식 확인"

result=$(scripts/lib/fallback-dispatcher.sh chain codex gpt-5.6-terra 2>/dev/null)
expected="codex:gpt-5.6-luna,opencode:glm-5.2,agy:gemini-3.5-flash,claude:default"
if [ "$result" = "$expected" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: got '$result'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 6] SSOT fallback chain 동일 결과 및 safety net 변환"

result=$(KANT_ROUTING_SOURCE=ssot scripts/lib/fallback-dispatcher.sh chain codex gpt-5.6-terra 2>/dev/null)
if [ "$result" = "$expected" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: got '$result'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 7] SSOT 모드 후 hardcode 모드 즉시 복귀"

result=$(KANT_ROUTING_SOURCE=ssot scripts/lib/fallback-dispatcher.sh chain codex gpt-5.6-terra 2>/dev/null)
post_result=$(scripts/lib/fallback-dispatcher.sh chain codex gpt-5.6-terra 2>/dev/null)
if [ "$post_result" = "$expected" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: post='$post_result'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 8] claude:claude-default → claude:default safety net 변환"

result=$(KANT_SHADOW_MODE=on KANT_ROUTING_SOURCE=ssot bash -c "
  source '$SHADOW_LIB'
  ssot_resolve_chain_by_tool_model 'codex' 'gpt-5.6-luna'
" 2>/dev/null | tr ',' '\n' | grep '^claude:' | head -1)
if [ "$result" = "claude:default" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: got '$result'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 9] SSOT 모드 chain-for-primary 서브커맨드 JSON"

out=$(python3 "$SKILL_LIB/ssot_loader.py" chain-for-primary --tool codex --model gpt-5.6-terra 2>/dev/null)
route=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('route',''))" 2>/dev/null)
if [ "$route" = "standard_repo" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: got '$route'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 10] SSOT 모드 매칭 안 되는 primary → error JSON"

out=$(python3 "$SKILL_LIB/ssot_loader.py" chain-for-primary --tool codex --model NONEXISTENT 2>&1)
if echo "$out" | grep -q '"error"'; then echo "  PASS"; ((PASS++)); else echo "  FAIL: got '$out'"; ((FAIL++)); fi

rm -rf /tmp/kant-p4-test

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]