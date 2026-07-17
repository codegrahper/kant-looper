#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
usage: emit-event.sh emit --state-dir DIR --event-root DIR --workflow-id ID \
       --step-id ID --agent AGENT --model MODEL --phase PHASE
EOF
}

require_value() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    echo "missing required value: $name" >&2
    exit 2
  fi
}

emit() {
  local state_dir="" event_root="" workflow_id="" step_id="" agent="" model="" phase=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --state-dir) state_dir="$2"; shift ;;
      --event-root) event_root="$2"; shift ;;
      --workflow-id) workflow_id="$2"; shift ;;
      --step-id) step_id="$2"; shift ;;
      --agent) agent="$2"; shift ;;
      --model) model="$2"; shift ;;
      --phase) phase="$2"; shift ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
  done

  require_value state_dir "$state_dir"
  require_value event_root "$event_root"
  require_value workflow_id "$workflow_id"
  require_value step_id "$step_id"
  require_value agent "$agent"
  require_value model "$model"
  require_value phase "$phase"

  local run_id result branch worktree report_file status attempt
  run_id="$(cat "$state_dir/run-id.txt")"
  result="$(cat "$state_dir/result.txt")"
  branch="$(cat "$state_dir/branch.txt" 2>/dev/null || true)"
  worktree="$(cat "$state_dir/worktree.txt" 2>/dev/null || true)"
  report_file="$state_dir/report.md"
  attempt="${KANT_WORKFLOW_ATTEMPT:-0}"
  require_value run_id "$run_id"
  require_value result "$result"

  case "$result" in
    completed|pass|pass_no_commit) status="success" ;;
    failed|timeout|cancelled|invalid_output|supervisor_error) status="failed" ;;
    *) echo "non-terminal result: $result" >&2; exit 2 ;;
  esac

  local pending tmp event_file
  pending="$event_root/pending"
  mkdir -p "$pending" "$event_root/processing" "$event_root/completed" "$event_root/failed" "$event_root/dead-letter" "$event_root/tasks" "$event_root/supervisor/locks"
  event_file="$pending/evt-$run_id.json"
  if [ -e "$event_file" ]; then
    echo "event already exists: $event_file"
    return 0
  fi
  tmp="$(mktemp "$pending/.evt-$run_id.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  python3 - "$tmp" "$run_id" "$status" "$workflow_id" "$step_id" "$agent" "$model" "$phase" "$state_dir" "$state_dir/result.txt" "$report_file" "$worktree" "$branch" "$attempt" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    path,
    run_id,
    status,
    workflow_id,
    step_id,
    agent,
    model,
    phase,
    state_dir,
    result_file,
    report_file,
    worktree,
    branch,
    attempt,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "event_id": f"evt-{run_id}",
    "event_type": "agent.completed",
    "created_at": datetime.now(timezone.utc).isoformat(),
    "workflow_id": workflow_id,
    "run_id": run_id,
    "step_id": step_id,
    "source": {"agent": agent, "model": model, "phase": phase},
    "status": status,
    "artifacts": {
        "state_dir": state_dir,
        "result_file": result_file,
        "report_file": report_file,
        "worktree": worktree,
        "branch": branch,
    },
    "attempt": int(attempt),
    "max_attempts": 2,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
    handle.write("\n")
PY
  if ln "$tmp" "$event_file" 2>/dev/null; then
    rm -f "$tmp"
    trap - RETURN
    echo "event emitted: $event_file"
  else
    echo "event already exists: $event_file"
  fi
}

case "${1:-}" in
  emit) shift; emit "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
