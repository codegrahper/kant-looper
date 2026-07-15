#!/usr/bin/env bash
# test-routing-ssot-sync.sh — 하드코딩 라우팅 ↔ SSOT 동기화 회귀 검증 (Phase 5)
#
# Phase 5의 보수적 버전: 하드코딩 상수를 제거하지 않고, SSOT가 코드와
# 정합한 상태를 유지하는지 회귀 검증한다. SSOT가 drift하면 테스트가
# 실패하여 운영자에게 알린다.
#
# 검증 대상:
#   각 라우트(tiny/standard/hard/huge/visual/review) primary가
#   hardcode 모드와 SSOT 모드에서 동일한 tool:model 반환
#   각 대표 primary에 대해 fallback chain이 동일한 순서/내용
#
# Phase 5는 hardcode 제거를 포함하지 않는다. 이 단계는 Phase 4 안정
# 운영 기간 후 이바가 명시적으로 승인할 때 reserved.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_LIB="$SKILL_ROOT/scripts/lib"
ROUTING_PARSER="$SKILL_LIB/routing-parser.sh"
FALLBACK_DISPATCHER="$SKILL_LIB/fallback-dispatcher.sh"
SSOT_JSON="$SKILL_ROOT/routing-ssot/routing-ssot.json"

declare -i PASS=0 FAIL=0

[ -f "$ROUTING_PARSER" ] || { echo "FAIL: $ROUTING_PARSER not found"; exit 1; }
[ -f "$FALLBACK_DISPATCHER" ] || { echo "FAIL: $FALLBACK_DISPATCHER not found"; exit 1; }
[ -f "$SSOT_JSON" ] || { echo "FAIL: $SSOT_JSON not found (run validate-routing-ssot.py)"; exit 1; }

mkdir -p /tmp/kant-p5-sync
TASKS_DIR="/tmp/kant-p5-sync"
mkdir -p "$TASKS_DIR"

ROUTES="tiny standard hard huge visual review"
write_task() {
  local route="$1"
  case "$route" in
    tiny)    printf '# Tiny\n## 목표\n테스트 작성 추가.\n' ;;
    standard) printf '# Std\n## 목표\n함수 구현.\n' ;;
    hard)    printf '# Hard\n## 목표\n여러 모듈 통합 수정.\n' ;;
    huge)    printf '# Huge\n## 목표\n전체 코드베이스 리팩터.\n' ;;
    visual)  printf '# Visual\n## 목표\nUI 컴포넌트.\n' ;;
    review)  printf '# Review\n## 목표\n리뷰.\n' ;;
  esac
}

for route in $ROUTES; do
  write_task "$route" > "$TASKS_DIR/${route}.md"
done

# ─────────────────────────────────────────
echo "[test 1] 6 라우트 primary hardcode↔ssot 동기화"

all_match=1
for route in $ROUTES; do
  task_file="$TASKS_DIR/${route}.md"
  hardcode_out=$(KANT_ROUTING_SOURCE=hardcode scripts/lib/routing-parser.sh match "$task_file" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)
  ssot_out=$(KANT_ROUTING_SOURCE=ssot scripts/lib/routing-parser.sh match "$task_file" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)
  if [ "$hardcode_out" != "$ssot_out" ]; then
    echo "  MISMATCH route=$route hardcode='$hardcode_out' ssot='$ssot_out'"
    all_match=0
  fi
done
if [ "$all_match" -eq 1 ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 2] codex/gpt-5.6-terra fallback chain 동기화"

hardcode_chain=$(KANT_ROUTING_SOURCE=hardcode scripts/lib/fallback-dispatcher.sh chain codex gpt-5.6-terra 2>/dev/null)
ssot_chain=$(KANT_ROUTING_SOURCE=ssot scripts/lib/fallback-dispatcher.sh chain codex gpt-5.6-terra 2>/dev/null)
if [ "$hardcode_chain" = "$ssot_chain" ] && [ -n "$hardcode_chain" ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: hardcode='$hardcode_chain' ssot='$ssot_chain'"
  ((FAIL++))
fi

# ─────────────────────────────────────────
echo "[test 3] 모든 SSOT chain 끝이 claude 안전망"

all_safe=1
while IFS= read -r route_json; do
  route_name=$(echo "$route_json" | python3 -c "import sys,json; print(list(json.load(sys.stdin).items())[0][0])")
  chain=$(echo "$route_json" | python3 -c "
import sys,json
d=list(json.load(sys.stdin).items())[0][1]
chain=d.get('fallbacks', [])
if not chain: print('NONE')
elif chain[-1]=='claude|anthropic/claude-default': print('SAFE')
else: print('UNSAFE:'+chain[-1])
" 2>/dev/null)
  if [ "$chain" != "SAFE" ]; then
    echo "  UNSAFE route=$route_name chain=$chain"
    all_safe=0
  fi
done < <(python3 -c "
import json
with open('$SSOT_JSON') as f:
    d = json.load(f)
for name, r in d.get('routes',{}).items():
    if r.get('status') in ('retired', 'proposed'):
        continue
    print(json.dumps({name: r}))
")
if [ "$all_safe" -eq 1 ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 4] hardcode routing 기본 종료 상태 유지"

unset_out=$(scripts/lib/routing-parser.sh match "$TASKS_DIR/standard.md" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)
ssot_explicit=$(KANT_ROUTING_SOURCE=ssot scripts/lib/routing-parser.sh match "$TASKS_DIR/standard.md" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)
hardcode_explicit=$(KANT_ROUTING_SOURCE=hardcode scripts/lib/routing-parser.sh match "$TASKS_DIR/standard.md" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)
if [ "$unset_out" = "$hardcode_explicit" ] && [ "$unset_out" != "$ssot_explicit" -o "$unset_out" = "$ssot_explicit" ]; then
  if [ "$unset_out" = "$hardcode_explicit" ]; then
    echo "  PASS"
    ((PASS++))
  else
    echo "  FAIL: unset='$unset_out' hardcode='$hardcode_explicit'"
    ((FAIL++))
  fi
else
  echo "  FAIL: unset='$unset_out' hardcode='$hardcode_explicit' ssot='$ssot_explicit'"
  ((FAIL++))
fi

rm -rf /tmp/kant-p5-sync

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]