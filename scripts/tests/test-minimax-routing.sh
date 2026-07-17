#!/usr/bin/env bash
# test-minimax-routing.sh — MiniMax model routing validation tests
#
# Tests:
# 1. model-selector.sh: MiniMax models under opencode, not claude
# 2. adapter-opencode.sh: MiniMax normalization to provider/model format
# 3. adapter-claude.sh: MiniMax models are rejected before Claude is called

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
MODEL_SELECTOR="$SKILL_ROOT/scripts/lib/model-selector.sh"
ADAPTER_OPENCODE="$SKILL_ROOT/scripts/adapters/adapter-opencode.sh"
ADAPTER_CLAUDE="$SKILL_ROOT/scripts/adapters/adapter-claude.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# 색상
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "${GREEN}PASS${NC}: $label"
    PASSED=$((PASSED + 1))
  else
    echo "${RED}FAIL${NC}: $label"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qxF "$needle"; then
    echo "${GREEN}PASS${NC}: $label"
    PASSED=$((PASSED + 1))
  else
    echo "${RED}FAIL${NC}: $label"
    echo "  expected '$needle' to be in: $haystack"
    FAILED=$((FAILED + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! printf '%s' "$haystack" | grep -qxF "$needle"; then
    echo "${GREEN}PASS${NC}: $label"
    PASSED=$((PASSED + 1))
  else
    echo "${RED}FAIL${NC}: $label"
    echo "  expected '$needle' NOT to be in: $haystack"
    FAILED=$((FAILED + 1))
  fi
}

MINIMAX_MODELS=(
  "MiniMax-M3"
  "MiniMax-M2.7"
  "MiniMax-M2.7-highspeed"
)

# ----------------------------------------------------------------------------
# Test 1: model-selector.sh — MiniMax models under opencode, not claude
# ----------------------------------------------------------------------------

echo "=== model-selector.sh tests ==="

opencode_models="$("$MODEL_SELECTOR" list-models opencode 2>/dev/null || true)"
claude_models="$("$MODEL_SELECTOR" list-models claude 2>/dev/null || true)"

for model in "${MINIMAX_MODELS[@]}"; do
  assert_contains "opencode supports $model" "$model" "$opencode_models"
  assert_not_contains "claude does NOT list $model" "$model" "$claude_models"

  validation="$("$MODEL_SELECTOR" validate opencode "$model" 2>/dev/null || true)"
  assert_eq "opencode validates $model" "OK" "$validation"

  if "$MODEL_SELECTOR" validate claude "$model" >/dev/null 2>&1; then
    echo "${RED}FAIL${NC}: claude should NOT validate $model"
    FAILED=$((FAILED + 1))
  else
    echo "${GREEN}PASS${NC}: claude rejects $model"
    PASSED=$((PASSED + 1))
  fi
done

# ----------------------------------------------------------------------------
# Test 2: adapter-opencode.sh — MiniMax model normalization
# ----------------------------------------------------------------------------

echo ""
echo "=== adapter-opencode.sh MiniMax normalization tests ==="

MOCK_BIN="$TMPDIR/bin"
WORKTREE="$TMPDIR/worktree"
PROMPT_FILE="$TMPDIR/prompt.txt"
MOCK_OPENCODE_MODEL="$TMPDIR/opencode-model"
MOCK_CLAUDE_CALLED="$TMPDIR/claude-called"
mkdir -p "$MOCK_BIN" "$WORKTREE"
printf '%s\n' 'Return a PASS verdict.' > "$PROMPT_FILE"

cat > "$MOCK_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --version)
    echo "opencode test stub"
    ;;
  run)
    shift
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-m" ]; then
        printf '%s' "$2" > "$KANT_TEST_OPENCODE_MODEL"
        break
      fi
      shift
    done
    printf '%s\n' '{"type":"text","part":{"text":"{\"verdict\":\"PASS\"}"}}'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$MOCK_BIN/opencode"

run_opencode_normalization() {
  local model="$1"
  rm -f "$MOCK_OPENCODE_MODEL"

  if ! PATH="$MOCK_BIN:$PATH" \
    KANT_TEST_OPENCODE_MODEL="$MOCK_OPENCODE_MODEL" \
    KANT_MINIMAX_OPENCODE_PROVIDER="minimax" \
    KANT_TIMEOUT_PLAN=1 \
    "$ADAPTER_OPENCODE" call plan "$PROMPT_FILE" "$WORKTREE" "$model" \
    > "$TMPDIR/opencode-output" 2> "$TMPDIR/opencode-error"; then
    return 1
  fi

  [ -f "$MOCK_OPENCODE_MODEL" ] || return 1
  printf '%s' "$(<"$MOCK_OPENCODE_MODEL")"
}

for model in "${MINIMAX_MODELS[@]}"; do
  if normalized_model="$(run_opencode_normalization "$model")"; then
    assert_eq "adapter-opencode normalizes $model" "minimax/$model" "$normalized_model"
  else
    echo "${RED}FAIL${NC}: adapter-opencode should normalize $model"
    FAILED=$((FAILED + 1))
  fi
done

# ----------------------------------------------------------------------------
# Test 4: adapter-claude.sh — MiniMax models are rejected
# ----------------------------------------------------------------------------

echo ""
echo "=== adapter-claude.sh MiniMax rejection tests ==="

cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --version)
    echo "claude test stub"
    ;;
  *)
    printf '%s' "called" > "$KANT_TEST_CLAUDE_CALLED"
    ;;
esac
EOF
chmod +x "$MOCK_BIN/claude"

for model in "${MINIMAX_MODELS[@]}"; do
  rm -f "$MOCK_CLAUDE_CALLED"
  if PATH="$MOCK_BIN:$PATH" \
    KANT_TEST_CLAUDE_CALLED="$MOCK_CLAUDE_CALLED" \
    ANTHROPIC_API_KEY="test-key" \
    "$ADAPTER_CLAUDE" call plan "$PROMPT_FILE" "$WORKTREE" "$model" \
    > "$TMPDIR/claude-output" 2> "$TMPDIR/claude-error"; then
    echo "${RED}FAIL${NC}: adapter-claude should reject $model"
    FAILED=$((FAILED + 1))
  else
    claude_error="$(<"$TMPDIR/claude-error")"
    assert_contains \
      "adapter-claude reports MiniMax rejection for $model" \
      "ERROR: MiniMax models are available only through the OpenCode agent." \
      "$claude_error"

    if [ -e "$MOCK_CLAUDE_CALLED" ]; then
      claude_invocation="called"
    else
      claude_invocation="not-called"
    fi
    assert_eq "adapter-claude does not invoke Claude for $model" "not-called" "$claude_invocation"
  fi
done

# ----------------------------------------------------------------------------
# Test 5: claude:default sentinel — "default" is valid for claude, MiniMax is not
# ----------------------------------------------------------------------------

echo ""
echo "=== claude:default sentinel validation ==="

if "$MODEL_SELECTOR" validate claude "default" >/dev/null 2>&1; then
  echo "${GREEN}PASS${NC}: claude validates 'default'"
  PASSED=$((PASSED + 1))
else
  echo "${RED}FAIL${NC}: claude should validate 'default'"
  FAILED=$((FAILED + 1))
fi

# ----------------------------------------------------------------------------
# Test 6: Provider-qualified MiniMax inputs rejected for Claude
# ----------------------------------------------------------------------------

echo ""
echo "=== provider-qualified MiniMax rejection for Claude ==="

QUALIFIED_MODEL="minimax/MiniMax-M3"
rm -f "$MOCK_CLAUDE_CALLED"
if PATH="$MOCK_BIN:$PATH" \
  KANT_TEST_CLAUDE_CALLED="$MOCK_CLAUDE_CALLED" \
  ANTHROPIC_API_KEY="test-key" \
  "$ADAPTER_CLAUDE" call plan "$PROMPT_FILE" "$WORKTREE" "$QUALIFIED_MODEL" \
  > "$TMPDIR/claude-qualified-output" 2> "$TMPDIR/claude-qualified-error"; then
  echo "${RED}FAIL${NC}: adapter-claude should reject provider-qualified $QUALIFIED_MODEL"
  FAILED=$((FAILED + 1))
else
  claude_error="$(<"$TMPDIR/claude-qualified-error")"
  assert_contains \
    "adapter-claude rejects provider-qualified $QUALIFIED_MODEL" \
    "ERROR: MiniMax models are available only through the OpenCode agent." \
    "$claude_error"
fi

# ----------------------------------------------------------------------------
# Test 7: adapter-claude.sh does NOT pass --model when model=default
# ----------------------------------------------------------------------------

echo ""
echo "=== adapter-claude.sh omits --model for default sentinel ==="

MOCK_CLAUDE_ARGS="$TMPDIR/claude-args"
cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  echo "claude test stub"
  exit 0
fi

printf '%s\n' "$*" > "$KANT_TEST_CLAUDE_ARGS"
printf '%s\n' '{"result":"{\"verdict\":\"PASS\",\"summary\":\"ok\",\"findings\":[]}"}'
EOF
chmod +x "$MOCK_BIN/claude"

rm -f "$MOCK_CLAUDE_ARGS"
if PATH="$MOCK_BIN:$PATH" \
  KANT_TEST_CLAUDE_ARGS="$MOCK_CLAUDE_ARGS" \
  ANTHROPIC_API_KEY="test-key" \
  "$ADAPTER_CLAUDE" call plan "$PROMPT_FILE" "$WORKTREE" "default" \
  > "$TMPDIR/claude-default-output" 2>/dev/null; then
  if [ -f "$MOCK_CLAUDE_ARGS" ]; then
    claude_args="$(<"$MOCK_CLAUDE_ARGS")"
    if echo "$claude_args" | grep -q -- "--model"; then
      echo "${RED}FAIL${NC}: adapter-claude should NOT pass --model for default"
      FAILED=$((FAILED + 1))
    else
      echo "${GREEN}PASS${NC}: adapter-claude omits --model for default"
      PASSED=$((PASSED + 1))
    fi
    if echo "$claude_args" | grep -q -- "default"; then
      echo "${RED}FAIL${NC}: adapter-claude should NOT pass 'default' as argument"
      FAILED=$((FAILED + 1))
    else
      echo "${GREEN}PASS${NC}: adapter-claude does not pass 'default' as argument"
      PASSED=$((PASSED + 1))
    fi
  else
    echo "${RED}FAIL${NC}: Claude mock was not called"
    FAILED=$((FAILED + 1))
  fi
else
  echo "${RED}FAIL${NC}: adapter-claude call failed unexpectedly"
  FAILED=$((FAILED + 1))
fi

# ----------------------------------------------------------------------------
# Test C: All provider-qualified MiniMax rejected for Claude
# ----------------------------------------------------------------------------

echo ""
echo "=== All provider-qualified MiniMax rejected for Claude ==="

QUALIFIED_CLAUDE_TESTS=(
  "minimax/MiniMax-M3"
  "custom-minimax/MiniMax-M3"
  "company-gateway/MiniMax-M2.7"
  "anything/MiniMax-M2.7-highspeed"
  "opencode:minimax/MiniMax-M3"
)

for qualified_model in "${QUALIFIED_CLAUDE_TESTS[@]}"; do
  rm -f "$MOCK_CLAUDE_CALLED"
  if PATH="$MOCK_BIN:$PATH" \
    KANT_TEST_CLAUDE_CALLED="$MOCK_CLAUDE_CALLED" \
    ANTHROPIC_API_KEY="test-key" \
    "$ADAPTER_CLAUDE" call plan "$PROMPT_FILE" "$WORKTREE" "$qualified_model" \
    > "$TMPDIR/claude-qualified-${qualified_model##*/}-output" 2> "$TMPDIR/claude-qualified-${qualified_model##*/}-error"; then
    echo "${RED}FAIL${NC}: adapter-claude should reject $qualified_model"
    FAILED=$((FAILED + 1))
  else
    claude_error="$(<"$TMPDIR/claude-qualified-${qualified_model##*/}-error")"
    if echo "$claude_error" | grep -q "MiniMax models are available only through the OpenCode agent"; then
      echo "${GREEN}PASS${NC}: adapter-claude rejects $qualified_model with correct error"
      PASSED=$((PASSED + 1))
    else
      echo "${RED}FAIL${NC}: adapter-claude rejected $qualified_model but wrong error"
      FAILED=$((FAILED + 1))
    fi

    if [ -e "$MOCK_CLAUDE_CALLED" ]; then
      echo "${RED}FAIL${NC}: Claude was called for $qualified_model"
      FAILED=$((FAILED + 1))
    else
      echo "${GREEN}PASS${NC}: Claude was not called for $qualified_model"
      PASSED=$((PASSED + 1))
    fi
  fi
done

# ----------------------------------------------------------------------------
# Test E: Fallback regression — no claude|MiniMax-M3 or claude:MiniMax-M3 in code
# ----------------------------------------------------------------------------

echo ""
echo "=== Fallback regression: claude|MiniMax-M3 not in scripts ==="

FALLBACK_CHECK=$(grep -rnE 'claude[:|]MiniMax-M3' \
  "$SKILL_ROOT/scripts" \
  --exclude='*.log' \
  --exclude='*.json' \
  2>/dev/null | grep -v 'test-minimax-routing.sh' || true)

if [ -n "$FALLBACK_CHECK" ]; then
  echo "${RED}FAIL${NC}: Found claude|MiniMax-M3 in scripts:"
  echo "$FALLBACK_CHECK" | while read -r line; do
    echo "  $line"
  done
  FAILED=$((FAILED + 1))
else
  echo "${GREEN}PASS${NC}: No claude|MiniMax-M3 found in scripts"
  PASSED=$((PASSED + 1))
fi

# Verify claude|default and claude:default exist in fallback chains
FALLBACK_DEFAULT_CHECK=$(grep -rnE 'claude[:|]default' \
  "$SKILL_ROOT/scripts/lib/fallback-dispatcher.sh" \
  2>/dev/null || true)

if [ -z "$FALLBACK_DEFAULT_CHECK" ]; then
  echo "${RED}FAIL${NC}: claude|default not found in fallback-dispatcher.sh"
  FAILED=$((FAILED + 1))
else
  echo "${GREEN}PASS${NC}: claude|default found in fallback chains"
  PASSED=$((PASSED + 1))
fi

# ----------------------------------------------------------------------------
# Results
# ----------------------------------------------------------------------------

echo ""
echo "=== Results ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
