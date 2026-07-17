#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Final

MAX_EVENT_BYTES: Final = 131_072


@dataclass(frozen=True, slots=True)
class Event:
    path: Path
    event_id: str
    workflow_id: str
    run_id: str
    step_id: str
    status: str
    agent: str
    model: str
    phase: str
    worktree: Path
    result_file: Path
    report_file: Path
    state_dir: Path
    attempt: int


@dataclass(frozen=True, slots=True)
class Step:
    step_id: str
    agent: str
    model: str
    phase: str


@dataclass(frozen=True, slots=True)
class Workflow:
    steps: tuple[Step, ...]
    max_attempts: int


class EventError(Exception):
    pass


def string_field(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 1024:
        raise EventError(f"invalid {field}")
    return value


def integer_field(value: object, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise EventError(f"invalid {field}")
    return value


def mapping_field(value: object, field: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise EventError(f"invalid {field}")
    return value


def parse_event(path: Path) -> Event:
    if path.stat().st_size > MAX_EVENT_BYTES:
        raise EventError("event exceeds size limit")
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise EventError("invalid JSON") from error
    root = mapping_field(raw, "event")
    if root.get("schema_version") != 1 or root.get("event_type") != "agent.completed":
        raise EventError("unsupported event schema")
    source = mapping_field(root.get("source"), "source")
    artifacts = mapping_field(root.get("artifacts"), "artifacts")
    return Event(
        path=path,
        event_id=string_field(root.get("event_id"), "event_id"),
        workflow_id=string_field(root.get("workflow_id"), "workflow_id"),
        run_id=string_field(root.get("run_id"), "run_id"),
        step_id=string_field(root.get("step_id"), "step_id"),
        status=string_field(root.get("status"), "status"),
        agent=string_field(source.get("agent"), "source.agent"),
        model=string_field(source.get("model"), "source.model"),
        phase=string_field(source.get("phase"), "source.phase"),
        worktree=Path(string_field(artifacts.get("worktree"), "artifacts.worktree")),
        result_file=Path(string_field(artifacts.get("result_file"), "artifacts.result_file")),
        report_file=Path(string_field(artifacts.get("report_file"), "artifacts.report_file")),
        state_dir=Path(string_field(artifacts.get("state_dir"), "artifacts.state_dir")),
        attempt=integer_field(root.get("attempt"), "attempt"),
    )


def load_workflow(path: Path, workflow_id: str) -> Workflow:
    raw = json.loads(path.read_text(encoding="utf-8"))
    root = mapping_field(raw, "workflow config")
    workflows = mapping_field(root.get("workflows"), "workflows")
    workflow = mapping_field(workflows.get(workflow_id), "workflow")
    raw_steps = workflow.get("steps")
    if not isinstance(raw_steps, list):
        raise EventError("workflow steps missing")
    steps: list[Step] = []
    for raw_step in raw_steps:
        item = mapping_field(raw_step, "workflow step")
        steps.append(Step(
            step_id=string_field(item.get("id"), "step.id"),
            agent=string_field(item.get("agent"), "step.agent"),
            model=string_field(item.get("model"), "step.model"),
            phase=string_field(item.get("phase"), "step.phase"),
        ))
    if not steps:
        raise EventError("workflow has no steps")
    return Workflow(steps=tuple(steps), max_attempts=integer_field(workflow.get("max_attempts"), "workflow.max_attempts"))


def current_step(event: Event, workflow: Workflow) -> Step:
    for step in workflow.steps:
        if step.step_id == event.step_id:
            return step
    raise EventError("event step is not configured")


def next_step(event: Event, workflow: Workflow) -> Step | None:
    for index, step in enumerate(workflow.steps):
        if step.step_id == event.step_id:
            return workflow.steps[index + 1] if index + 1 < len(workflow.steps) else None
    raise EventError("event step is not configured")


def registered_worktree(repo: Path, worktree: Path) -> bool:
    if not worktree.is_dir() or worktree.resolve() == repo.resolve():
        return False
    completed = subprocess.run(
        ["git", "-C", str(repo), "worktree", "list", "--porcelain"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return completed.returncode == 0 and f"worktree {worktree.resolve()}" in completed.stdout.splitlines()


def task_file(event_root: Path, event: Event, step: Step) -> Path:
    path = event_root / "tasks" / f"{event.event_id}-{step.step_id}.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join((
            "# Workflow task",
            "", "## Goal", f"Continue the workflow after the prior {event.phase} phase in the supplied worktree.",
            "", "## Workflow", f"- Workflow ID: {event.workflow_id}",
            f"- Previous run: {event.run_id}", f"- Previous agent: {event.agent}:{event.model}",
            f"- Current phase: {step.phase}", "", "## Inputs",
            f"- Worktree: {event.worktree}", f"- Result: {event.result_file}", f"- Report: {event.report_file}",
            "", "## Constraints", *( ("Review only. Do not modify files.",) if step.phase == "review" else ("Perform the assigned workflow phase and validate the result.",) ), "",
        )), encoding="utf-8"
    )
    return path


def dispatch(event_root: Path, event: Event, step: Step, task: Path, repo: Path, kant_loop: Path, dry_run: bool, attempt: int) -> None:
    if not registered_worktree(repo, event.worktree):
        raise EventError("worktree is not a registered non-primary worktree")
    if dry_run:
        return
    environment = os.environ.copy()
    environment["KANT_EVENT_PHASE"] = step.phase
    environment["KANT_WORKFLOW_ATTEMPT"] = str(attempt)
    completed = subprocess.run(
        [str(kant_loop), "run", str(task), "--quick", "--agent", step.agent,
         "--model", step.model, "--workflow", event.workflow_id, "--step", step.step_id, "--role", step.phase,
         "--existing-worktree", str(event.worktree), "--no-auto-commit", "--detach"],
        cwd=repo, env=environment, check=False, capture_output=True, text=True, timeout=60,
    )
    if completed.returncode != 0:
        raise EventError(f"successor dispatch failed: {completed.stderr[-400:]}")


def verify_event(event: Event, database: Path) -> str:
    dispatcher = Path(__file__).parents[1] / "dispatcher" / "dispatcher.py"
    envelope = {
        "event": "task.completed",
        "task_id": event.run_id,
        "agent": event.agent,
        "attempt": event.attempt + 1,
        "exit_code": 0 if event.status == "success" else 1,
        "stop_reason": event.status,
        "result_file": str(event.result_file),
        "stdout_file": str(event.state_dir / "detached.log"),
        "stderr_file": str(event.state_dir / "phase-events.log"),
        "task_file": str(event.state_dir / "task.md"),
        "model": event.model,
        "workspace": str(event.worktree),
        "timestamp": "1970-01-01T00:00:00+00:00",
    }
    with tempfile.TemporaryDirectory(prefix="kant-supervisor-") as directory:
        path = Path(directory) / "completion.json"
        path.write_text(json.dumps(envelope), encoding="utf-8")
        received = subprocess.run([sys.executable, str(dispatcher), "receive", "--db", str(database), "--event-file", str(path)], check=False, capture_output=True, text=True, timeout=60)
        if received.returncode != 0:
            raise EventError("dispatcher receipt failed")
        verified = subprocess.run([sys.executable, str(dispatcher), "verify", "--db", str(database), "--task-id", event.run_id], check=False, capture_output=True, text=True, timeout=180)
    if verified.returncode != 0:
        raise EventError("dispatcher verification failed")
    return verified.stdout.strip()


def move(path: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    shutil.move(str(path), str(destination / path.name))


def recover(event_root: Path, seconds: int) -> None:
    processing = event_root / "processing"
    if not processing.exists():
        return
    cutoff = time.time() - seconds
    for path in processing.glob("*.json"):
        if path.stat().st_mtime <= cutoff:
            move(path, event_root / "pending")


def process(event_root: Path, event_path: Path, workflow_file: Path, repo: Path, kant_loop: Path, database: Path, dry_run: bool) -> bool:
    processing = event_root / "processing" / event_path.name
    processing.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.replace(event_path, processing)
    except FileNotFoundError:
        return False
    try:
        event = parse_event(processing)
        workflow = load_workflow(workflow_file, event.workflow_id)
        verified = verify_event(event, database)
        if verified != "PASSED":
            step = current_step(event, workflow)
            if event.attempt < workflow.max_attempts:
                retry_task = event.state_dir / "task.md"
                if not retry_task.is_file():
                    raise EventError("retry task is missing")
                dispatch(event_root, event, step, retry_task, repo, kant_loop, dry_run, event.attempt + 1)
            move(processing, event_root / "failed")
            return True
        step = next_step(event, workflow)
        if step is not None:
            dispatch(event_root, event, step, task_file(event_root, event, step), repo, kant_loop, dry_run, 0)
        move(processing, event_root / "completed")
        return True
    except (EventError, OSError, subprocess.SubprocessError, json.JSONDecodeError):
        move(processing, event_root / "dead-letter")
        return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event-root", type=Path, required=True)
    parser.add_argument("--workflow-file", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--kant-loop", type=Path, default=Path(__file__).parents[1] / "kant-loop.sh")
    parser.add_argument("--db", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--recovery-seconds", type=int, default=600)
    parser.add_argument("--max-events", type=int)
    args = parser.parse_args()
    database = args.db or args.event_root / "supervisor" / "tasks.sqlite3"
    processed = 0
    while True:
        recover(args.event_root, args.recovery_seconds)
        pending = args.event_root / "pending"
        pending.mkdir(parents=True, exist_ok=True)
        for event_path in sorted(pending.glob("*.json")):
            processed += int(process(args.event_root, event_path, args.workflow_file, args.repo, args.kant_loop, database, args.dry_run))
            if args.max_events is not None and processed >= args.max_events:
                return 0
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
