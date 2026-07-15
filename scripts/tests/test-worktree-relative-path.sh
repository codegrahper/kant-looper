#!/usr/bin/env bash
# test-worktree-relative-path.sh — worktree relative path prompt validation tests
#
# Tests:
# 1. All prompts contain the relative path guidance section
# 2. No prompts contain forbidden absolute path patterns

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"

# 색상
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

pass() { echo "${GREEN}PASS${NC}: $1"; ((PASSED++)); }
fail() { echo "${RED}FAIL${NC}: $1"; ((FAILED++)); }

# ---------------------------------------------------------------------------
# Helper: extract prompt sections from kant-loop.sh
# ---------------------------------------------------------------------------

# Extract quick mode prompt
extract_quick_prompt() {
  awk '/^run_quick_mode\(\)/,/^run_/' "$KANT_LOOP" | \
    awk '/cat > "$prompt_file"/,/^EOF$/'
}

# Extract full mode plan prompt
extract_plan_prompt() {
  awk '/# \(1\) plan/,/adapter.*call.*plan/' "$KANT_LOOP" | \
    awk '/cat > "$plan_prompt"/,/^EOF$/'
}

# Extract implement prompt
extract_impl_prompt() {
  awk '/# \(2\) implement/,/adapter.*call.*implement/' "$KANT_LOOP" | \
    awk '/cat > "$impl_prompt"/,/^EOF$/'
}

# Extract review prompt
extract_review_prompt() {
  awk '/# \(4\) review/,/adapter.*call.*review/' "$KANT_LOOP" | \
    awk '/cat > "$review_prompt"/,/^EOF$/'
}

# Extract parallel prompt
extract_parallel_prompt() {
  awk '/cat > "$prompt_file"/,/^EOF$/' "$KANT_LOOP" | head -20
}

# ---------------------------------------------------------------------------
# Test 1: All prompt templates contain path guidance
# ---------------------------------------------------------------------------

REQUIRED_PATH_RULES=(
  "Current working directory is your worktree root"
  "Use only relative paths"
  "Do not recreate the worktree directory"
  "Forbidden:"
  "Desktop/"
  "~/Desktop/"
  "Users/"
  "Agents modify only their own workspace"
)

echo "=== Path guidance in prompts ==="

# Check that all required path rules appear in kant-loop.sh
for rule in "${REQUIRED_PATH_RULES[@]}"; do
  if grep -qF "$rule" "$KANT_LOOP" 2>/dev/null; then
    pass "prompt contains: $rule"
  else
    fail "prompt missing: $rule"
  fi
done

# ---------------------------------------------------------------------------
# Test 2: Prompt should NOT contain actual worktree path references
# ---------------------------------------------------------------------------

echo ""
echo "=== Forbidden absolute path check ==="

# The worktree path variable ($worktree) should be used in the guidance text
# But actual paths like Desktop/, Users/, etc. should only appear in "Forbidden:" context

# Check that if Desktop/ appears, it's in a Forbidden context
desktop_lines=$(grep -n 'Desktop/' "$KANT_LOOP" 2>/dev/null | grep -v 'Forbidden:' | grep -v '#.*Desktop' || true)
if [ -z "$desktop_lines" ]; then
  pass "Desktop/ only in Forbidden context"
else
  fail "Desktop/ appears outside Forbidden context:"
  echo "$desktop_lines" | while read -r line; do
    echo "  $line"
  done
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo "=== Results ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

[ "$FAILED" -eq 0 ]
