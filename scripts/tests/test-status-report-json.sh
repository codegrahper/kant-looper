#!/usr/bin/env bash
# test-status-report-json.sh — status/report --json 출력 및 기본 출력 회귀 검증

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"

declare -i PASS=0 FAIL=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export KANT_STATE_ROOT="$TMP_ROOT/state"

RH="$(printf '%s' "$SKILL_ROOT" | shasum -a 256 | cut -c1-12)"
RUN_ID="json-test-run"
STATE_DIR="$KANT_STATE_ROOT/$RH/$RUN_ID"
mkdir -p "$STATE_DIR"

printf '%s\n' 'completed' > "$STATE_DIR/result.txt"
printf '%s\n' 'agent/kant/json-test-run' > "$STATE_DIR/branch.txt"
printf '%s\n' '/tmp/worktree "quoted"' > "$STATE_DIR/worktree.txt"
printf '%s\n' 'abc123' > "$STATE_DIR/commit-sha.txt"
printf '%s\n' 'reviewed456' > "$STATE_DIR/reviewed-tree-sha.txt"
printf '%s\n' 'committed789' > "$STATE_DIR/committed-tree-sha.txt"
for n in $(seq 1 12); do printf 'event %s "quoted"\n' "$n"; done > "$STATE_DIR/phase-events.log"
for n in $(seq 1 12); do printf 'safety %s\n' "$n"; done > "$STATE_DIR/safety.log"

assert_pass() {
  local label="$1"
  shift
  if "$@"; then
    echo "  PASS: $label"
    ((PASS++))
  else
    echo "  FAIL: $label"
    ((FAIL++))
  fi
}

echo "[test 1] status JSON은 유효하며 파일 값과 일치한다"
STATUS_JSON="$TMP_ROOT/status.json"
(cd "$SKILL_ROOT" && "$KANT_LOOP" status "$RUN_ID" --json) > "$STATUS_JSON"
assert_pass "status JSON 구문" python3 -m json.tool "$STATUS_JSON"
assert_pass "status 필드 및 최근 10개 이벤트" python3 - "$STATUS_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    data = json.load(stream)
assert data["run_id"] == "json-test-run"
assert data["result"] == "completed"
assert data["branch"] == "agent/kant/json-test-run"
assert data["commit"] == "abc123"
assert data["recent_events"] == [f'event {n} "quoted"' for n in range(3, 13)]
PY

echo "[test 2] report JSON은 유효하며 tree와 safety 값이 일치한다"
REPORT_JSON="$TMP_ROOT/report.json"
(cd "$SKILL_ROOT" && "$KANT_LOOP" report --json "$RUN_ID") > "$REPORT_JSON"
assert_pass "report JSON 구문" python3 -m json.tool "$REPORT_JSON"
assert_pass "report 필드 및 앞 10개 safety 줄" python3 - "$REPORT_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    data = json.load(stream)
assert data["reviewed_tree"] == "reviewed456"
assert data["committed_tree"] == "committed789"
assert data["safety_log"] == [f"safety {n}" for n in range(1, 11)]
assert data["promote_command"].endswith("kant-loop.sh promote agent/kant/json-test-run --target main")
PY

echo "[test 3] --json 없는 기존 텍스트/마크다운 라벨은 유지된다"
STATUS_TEXT="$(cd "$SKILL_ROOT" && "$KANT_LOOP" status "$RUN_ID")"
REPORT_TEXT="$(cd "$SKILL_ROOT" && "$KANT_LOOP" report "$RUN_ID")"
assert_pass "status 기존 라벨" grep -q '^run_id: json-test-run$' <<< "$STATUS_TEXT"
assert_pass "report 기존 제목" grep -q '^# nomad-kant-looper 보고서 — json-test-run$' <<< "$REPORT_TEXT"

echo "[test 4] 없는 필드는 null 또는 빈 배열이고 result 기본값은 running이다"
EMPTY_RUN_ID="json-empty-run"
mkdir -p "$KANT_STATE_ROOT/$RH/$EMPTY_RUN_ID"
EMPTY_STATUS_JSON="$TMP_ROOT/empty-status.json"
EMPTY_REPORT_JSON="$TMP_ROOT/empty-report.json"
(cd "$SKILL_ROOT" && "$KANT_LOOP" status --latest --json) > "$EMPTY_STATUS_JSON"
(cd "$SKILL_ROOT" && "$KANT_LOOP" report "$EMPTY_RUN_ID" --json) > "$EMPTY_REPORT_JSON"
assert_pass "status null/빈 배열" python3 - "$EMPTY_STATUS_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    data = json.load(stream)
assert data["run_id"] == "json-empty-run"
assert data["result"] == "running"
assert data["branch"] is None
assert data["worktree"] is None
assert data["commit"] is None
assert data["failure"] is None
assert data["recent_events"] == []
PY
assert_pass "report null/빈 배열" python3 - "$EMPTY_REPORT_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    data = json.load(stream)
for field in ("branch", "worktree", "commit_sha", "reviewed_tree", "committed_tree", "failure"):
    assert data[field] is None
assert data["safety_log"] == []
PY

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
