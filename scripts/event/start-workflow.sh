#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP_BIN="${KANT_LOOP_BIN:-$ROOT/scripts/kant-loop.sh}"
STATE_ROOT="${KANT_STATE_ROOT:-$HOME/.claude/state/kant-looper}"

usage() {
  echo "usage: start-workflow.sh TASK.md --workflow ID [--workflow-file FILE] [--repo DIR]" >&2
}

task_file="${1:-}"
[ -n "$task_file" ] || { usage; exit 2; }
shift
workflow_id=""
workflow_file="$ROOT/config/dispatch-routes.json"
repo="$(pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --workflow) workflow_id="$2"; shift ;;
    --workflow-file) workflow_file="$2"; shift ;;
    --repo) repo="$2"; shift ;;
    *) usage; exit 2 ;;
  esac
  shift
done

[ -f "$task_file" ] || { echo "task file not found: $task_file" >&2; exit 2; }
[ -f "$workflow_file" ] || { echo "workflow file not found: $workflow_file" >&2; exit 2; }
[ -n "$workflow_id" ] || { echo "--workflow is required" >&2; exit 2; }

route="$(python3 - "$workflow_file" "$workflow_id" <<'PY'
import json
import sys

path, workflow_id = sys.argv[1:]
try:
    workflow = json.loads(open(path, encoding="utf-8").read())["workflows"][workflow_id]
    step = workflow["steps"][0]
    values = (step["id"], step["agent"], step["model"], step["phase"])
    if not all(isinstance(value, str) and value for value in values):
        raise ValueError("invalid root step")
except (OSError, KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid workflow {workflow_id}: {error}")
print("\t".join(values))
PY
)"
IFS=$'\t' read -r step_id agent model phase <<EOF
$route
EOF

event_root="$STATE_ROOT/events"
supervisor_dir="$event_root/supervisor"
pid_file="$supervisor_dir/supervisor.pid"
db="$supervisor_dir/tasks.sqlite3"
mkdir -p "$supervisor_dir"
if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
  echo "supervisor already running: $(cat "$pid_file")" >&2
  exit 1
fi
rm -f "$pid_file"
nohup python3 "$SCRIPT_DIR/supervisor.py" \
  --event-root "$event_root" \
  --workflow-file "$workflow_file" \
  --repo "$repo" \
  --db "$db" \
  --kant-loop "$KANT_LOOP_BIN" \
  > "$supervisor_dir/supervisor.log" 2>&1 &
supervisor_pid=$!
printf '%s\n' "$supervisor_pid" > "$pid_file"

if ! KANT_STATE_ROOT="$STATE_ROOT" KANT_WORKFLOW_ATTEMPT=0 "$KANT_LOOP_BIN" run "$task_file" --quick --agent "$agent" --model "$model" --workflow "$workflow_id" --step "$step_id" --role "$phase" --no-auto-commit --detach; then
  kill "$supervisor_pid" 2>/dev/null || true
  rm -f "$pid_file"
  exit 1
fi
echo "workflow: $workflow_id"
echo "supervisor_pid: $supervisor_pid"
echo "event_root: $event_root"
