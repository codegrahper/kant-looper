#!/bin/bash
# PostToolUse(Bash) 훅 — asyncRewake
#
# "kant-loop.sh run ... --detach" 호출이 성공하면 자동으로
# "kant-loop.sh await <run_id>"를 백그라운드에서 돌리고, 완료(성공/실패/타임아웃)
# 시 클로드를 깨운다. --detach 후 사람이 await를 별도 background Bash로
# 감싸야 했던 수동 2단계를 훅 레벨에서 대체한다.
#
# asyncRewake 계약: 이 스크립트 자신의 종료 코드가 2여야 클로드가 깨어난다.
# kant-loop.sh await의 실제 성공/실패/타임아웃 종료 코드(0/1/2)는 별개이며
# stdout 메시지로만 구분해서 전달한다.

set -u

INPUT="$(cat)"

COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
case "$COMMAND" in
  *kant-loop.sh\ run*--detach*) ;;
  *) exit 0 ;;
esac

STDOUT="$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // empty')"

# kant-loop.sh의 --detach 경로만 찍는 명확한 마커 — run_id: 같은 흔한 형태의
# 우연한 텍스트 일치(예: 이 스크립트를 테스트하는 다른 Bash 호출)를 배제한다.
if ! printf '%s\n' "$STDOUT" | grep -qx 'kant_hook_marker: kant-loop-detach-v1'; then
  exit 0
fi

RUN_ID="$(printf '%s\n' "$STDOUT" | grep -m1 '^run_id:' | sed 's/^run_id: *//')"

if [ -z "$RUN_ID" ]; then
  exit 0
fi

KANT_LOOP="${CLAUDE_PROJECT_DIR:-.}/scripts/kant-loop.sh"
if [ ! -x "$KANT_LOOP" ]; then
  echo "kant-loop-auto-await: kant-loop.sh not found/executable at $KANT_LOOP" >&2
  exit 2
fi

AWAIT_OUTPUT="$("$KANT_LOOP" await "$RUN_ID" --timeout 3600 --interval 5 2>&1)"
AWAIT_RC=$?

case "$AWAIT_RC" in
  0) STATUS="완료" ;;
  1) STATUS="실패" ;;
  2) STATUS="타임아웃" ;;
  *) STATUS="알 수 없음(rc=$AWAIT_RC)" ;;
esac

echo "kant-loop run_id=$RUN_ID $STATUS"
echo "$AWAIT_OUTPUT"
exit 2
