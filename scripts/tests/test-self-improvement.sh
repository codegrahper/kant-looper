#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"
SAFETY_CHECK="$SKILL_ROOT/scripts/lib/safety-check.sh"

PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/kant-self-improvement-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

scan_repo="$tmp_root/scan-repo"
mkdir -p "$scan_repo/scripts/tests" "$scan_repo/scripts/lib" "$scan_repo/references/postmortems" "$scan_repo/state"
cp "$KANT_LOOP" "$scan_repo/scripts/kant-loop.sh"
cat > "$scan_repo/scripts/tests/test-all.sh" <<'EOF'
#!/usr/bin/env bash
LABELS=("synthetic regression")
echo "  ✗ FAIL: synthetic regression (1 failures)"
exit 1
EOF
cat > "$scan_repo/references/postmortems/sample.md" <<'EOF'
# Sample

## 후속 조치 후보

- [ ] 첫 줄 항목
      둘째 줄 설명
- [x] 완료 항목
EOF
git -C "$scan_repo" init -q
git -C "$scan_repo" config user.email "test@example.invalid"
git -C "$scan_repo" config user.name "Kant Test"
git -C "$scan_repo" add .
git -C "$scan_repo" commit -qm init

before_status="$(git -C "$scan_repo" status --porcelain)"
scan_output="$(cd "$scan_repo" && KANT_STATE_ROOT="$scan_repo/state" bash scripts/kant-loop.sh self-scan)"
after_status="$(git -C "$scan_repo" status --porcelain)"

if printf '%s\n' "$scan_output" | grep -qE '^\[SCAN-1\] source=scripts/tests/test-all\.sh:[0-9]+$'; then
  pass "self-scan reports test-all failure with source line"
else
  fail "self-scan test failure record missing: $scan_output"
fi

if printf '%s\n' "$scan_output" | grep -qF '[SCAN-2] source=references/postmortems/sample.md:5' && \
   printf '%s\n' "$scan_output" | grep -qF '첫 줄 항목 둘째 줄 설명'; then
  pass "self-scan reports multiline unchecked postmortem item"
else
  fail "self-scan postmortem record missing: $scan_output"
fi

if [ "$before_status" = "$after_status" ]; then
  pass "self-scan leaves git status unchanged"
else
  fail "self-scan changed git status"
fi

protected_repo="$tmp_root/protected-repo"
mkdir -p "$protected_repo/scripts/lib"
git -C "$protected_repo" init -q
git -C "$protected_repo" config user.email "test@example.invalid"
git -C "$protected_repo" config user.name "Kant Test"
cp "$SAFETY_CHECK" "$protected_repo/scripts/lib/safety-check.sh"
printf '%s\n' '#!/usr/bin/env bash' > "$protected_repo/scripts/lib/health-check.sh"
git -C "$protected_repo" add .
git -C "$protected_repo" commit -qm init
printf '%s\n' '# modified' >> "$protected_repo/scripts/lib/safety-check.sh"

if protected_output="$(bash "$SAFETY_CHECK" paths "$protected_repo" 2>&1)"; then
  fail "safety-check allowed its protected file"
elif printf '%s\n' "$protected_output" | grep -qF 'scripts/lib/safety-check.sh'; then
  pass "safety-check blocks protected safety-check.sh diff"
else
  fail "safety-check failed without protected path evidence: $protected_output"
fi

git -C "$protected_repo" checkout -q -- scripts/lib/safety-check.sh
printf '%s\n' '# modified' >> "$protected_repo/scripts/lib/health-check.sh"
if protected_output="$(bash "$SAFETY_CHECK" paths "$protected_repo" 2>&1)"; then
  fail "safety-check allowed protected health-check.sh"
elif printf '%s\n' "$protected_output" | grep -qF 'scripts/lib/health-check.sh'; then
  pass "safety-check blocks protected health-check.sh diff"
else
  fail "health-check protection failed without path evidence: $protected_output"
fi

dispatch_repo="$tmp_root/dispatch-repo"
git clone -q "$SKILL_ROOT" "$dispatch_repo"
cp "$KANT_LOOP" "$dispatch_repo/scripts/kant-loop.sh"
cp "$SAFETY_CHECK" "$dispatch_repo/scripts/lib/safety-check.sh"
cat > "$dispatch_repo/scripts/tests/test-all.sh" <<'EOF'
#!/usr/bin/env bash
LABELS=("synthetic dispatch backlog")
echo "  ✗ FAIL: synthetic dispatch backlog (1 failures)"
exit 1
EOF
cat > "$dispatch_repo/scripts/adapters/adapter-codex.sh" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "call" ]; then
  worktree="$4"
  changed="$worktree/scripts/kant-loop.sh.changed"
  if [ "${5:-}" = "gpt-5.6-luna" ]; then
    printf '%s\n' '# forbidden mutation' >> "$worktree/scripts/lib/safety-check.sh"
    changed_files='["scripts/lib/safety-check.sh"]'
  elif [ "${5:-}" = "gpt-5.6-terra" ]; then
    sed 's/if \[ "$current_branch" = "main" \] || \[ "$current_branch" = "master" \]; then/if [ "$current_branch" = "main" ]; then/' "$worktree/scripts/kant-loop.sh" > "$changed"
    mv "$changed" "$worktree/scripts/kant-loop.sh"
    changed_files='["scripts/kant-loop.sh"]'
  else
    sed 's/log "promote 성공"/log "promote 완료"/' "$worktree/scripts/kant-loop.sh" > "$changed"
    mv "$changed" "$worktree/scripts/kant-loop.sh"
    changed_files='["scripts/kant-loop.sh"]'
  fi
  verdict_file="${TMPDIR:-/tmp}/kant-fake-verdict-$$.json"
  printf '%s\n' "{\"verdict\":\"PASS\",\"summary\":\"synthetic\",\"findings\":[],\"changed_files\":$changed_files}" > "$verdict_file"
  echo "PASS|$verdict_file"
  exit 0
fi
exit 0
EOF
cat > "$dispatch_repo/scripts/lib/gate-runner.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$dispatch_repo/scripts/adapters/adapter-codex.sh" "$dispatch_repo/scripts/lib/gate-runner.sh"
git -C "$dispatch_repo" config user.email "test@example.invalid"
git -C "$dispatch_repo" config user.name "Kant Test"
git -C "$dispatch_repo" add scripts/kant-loop.sh scripts/lib/safety-check.sh scripts/tests/test-all.sh scripts/adapters/adapter-codex.sh scripts/lib/gate-runner.sh
git -C "$dispatch_repo" commit -qm fixtures

dispatch_state="$tmp_root/dispatch-state"
mkdir -p "$dispatch_state"
set +e
dispatch_output="$(cd "$dispatch_repo" && KANT_STATE_ROOT="$dispatch_state" KANT_NOTIFY_OSASCRIPT=0 bash scripts/kant-loop.sh self-dispatch SCAN-1 --agent codex --model gpt-5.6-sol 2>&1)"
dispatch_rc=$?

task_path="$(printf '%s\n' "$dispatch_output" | sed -n 's/^generated_task: //p' | head -1)"
if [ -f "$task_path" ] && \
   grep -qF '## 유지 조건 (자기개선 자동화 — 항상 적용)' "$task_path" && \
   grep -qF '`scripts/lib/safety-check.sh`' "$task_path" && \
   grep -qF '`scripts/lib/health-check.sh`' "$task_path" && \
   grep -qF '`cmd_promote()` 전체' "$task_path"; then
  pass "self-dispatch generates TASK.md with fixed safety conditions"
else
  fail "generated TASK.md safety conditions missing: $task_path"
fi

if [ "$dispatch_rc" -ne 0 ] && printf '%s\n' "$dispatch_output" | grep -qF 'verdict: SELF_IMPROVEMENT_VIOLATION'; then
  pass "self-dispatch reclassifies protected function change"
else
  fail "self-dispatch did not report SELF_IMPROVEMENT_VIOLATION: $dispatch_output"
fi

dispatch_branch="$(printf '%s\n' "$dispatch_output" | sed -n 's/^branch: //p' | tail -1)"
if [ -n "$dispatch_branch" ] && git -C "$dispatch_repo" rev-parse "$dispatch_branch" >/dev/null 2>&1; then
  pass "violation branch and commit remain for human review"
else
  fail "violation branch was not preserved"
fi

set +e
guard_output="$(cd "$dispatch_repo" && KANT_STATE_ROOT="$dispatch_state" KANT_NOTIFY_OSASCRIPT=0 bash scripts/kant-loop.sh self-dispatch SCAN-1 --agent codex --model gpt-5.6-terra 2>&1)"
guard_rc=$?

if [ "$guard_rc" -ne 0 ] && printf '%s\n' "$guard_output" | grep -qF 'verdict: SELF_IMPROVEMENT_VIOLATION'; then
  pass "self-dispatch reclassifies do_commit branch guard change"
else
  fail "self-dispatch missed do_commit branch guard change: $guard_output"
fi

set +e
protected_dispatch_output="$(cd "$dispatch_repo" && KANT_STATE_ROOT="$dispatch_state" KANT_NOTIFY_OSASCRIPT=0 bash scripts/kant-loop.sh self-dispatch SCAN-1 --agent codex --model gpt-5.6-luna 2>&1)"
protected_dispatch_rc=$?

protected_dispatch_branch="$(printf '%s\n' "$protected_dispatch_output" | sed -n 's/^branch: //p' | tail -1)"
if [ "$protected_dispatch_rc" -ne 0 ] && \
   printf '%s\n' "$protected_dispatch_output" | grep -qF 'verdict: SAFETY_VIOLATION' && \
   [ "$(git -C "$dispatch_repo" rev-list --count HEAD.."$protected_dispatch_branch" 2>/dev/null)" = "0" ]; then
  pass "self-dispatch commit path blocks protected file before commit"
else
  fail "protected file reached commit path: $protected_dispatch_output"
fi

echo "=== self-improvement tests ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

[ "$FAILED" -eq 0 ]
