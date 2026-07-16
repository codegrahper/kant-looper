#!/usr/bin/env bash
# test-claude-health-subscription.sh — claude health must accept subscription (OAuth) login
#
# Regression guard:
#   When the claude CLI is signed in via OAuth subscription (no API key, no
#   credentials.json), health_check_tool claude must still return 0.
#   The previous behavior required either ~/.claude/credentials.json or
#   $ANTHROPIC_API_KEY, which caused every fallback chain's final safety net
#   to look dead.
#
# Tests:
#   S1 — credentials.json absent + ANTHROPIC_API_KEY absent + mock claude --version OK → rc=0
#   S2 — credentials.json absent + ANTHROPIC_API_KEY present + mock --version OK → rc=0
#   S3 — command -v claude returns non-zero (no claude binary in PATH) → rc=1
#   S4 — claude --version exits non-zero → rc=1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HEALTH_CHECK="$SKILL_ROOT/scripts/lib/health-check.sh"

# 색상
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

pass() { echo "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }

# ----------------------------------------------------------------------------
# Mock claude binary
# ----------------------------------------------------------------------------

MOCK_ROOT="$(mktemp -d -t claude-health-mock-XXXXXX)"
MOCK_BIN="$MOCK_ROOT/bin"
mkdir -p "$MOCK_BIN"

make_claude_mock() {
  local mode="$1"
  cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  --version)
    if [ "$mode" = "ok" ]; then
      echo "claude test stub 1.2.3"
      exit 0
    else
      echo "claude --version failed" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: mock claude invoked with unexpected args: \$*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$MOCK_BIN/claude"
}

# ----------------------------------------------------------------------------
# Helper — run health-check under controlled HOME and PATH
# ----------------------------------------------------------------------------

run_health_claude() {
  local mode="$1"
  local isolated_home="$2"
  local api_key="${3:-}"

  make_claude_mock "$mode"

  if [ -n "$api_key" ]; then
    ( cd /tmp && \
      HOME="$isolated_home" \
      PATH="$MOCK_BIN:$PATH" \
      ANTHROPIC_API_KEY="$api_key" \
      "$HEALTH_CHECK" tool claude )
  else
    ( cd /tmp && \
      HOME="$isolated_home" \
      PATH="$MOCK_BIN:$PATH" \
      "$HEALTH_CHECK" tool claude )
  fi
}

# ----------------------------------------------------------------------------
# S1 — Subscription-only (no credentials.json, no API key) → rc=0
# ----------------------------------------------------------------------------

echo "=== S1: subscription login (no credentials.json, no API key) ==="

ISOLATED_HOME="$MOCK_ROOT/home1"
mkdir -p "$ISOLATED_HOME"
# Explicitly ensure no credentials.json and no API key in env
unset ANTHROPIC_API_KEY

if run_health_claude "ok" "$ISOLATED_HOME" ""; then
  pass "claude health OK in subscription-only mode"
else
  fail "claude health FAILED in subscription-only mode (rc=$?)"
  echo "  HOME=$ISOLATED_HOME"
  echo "  expected: rc=0"
fi

# Defense in depth — confirm no credentials.json exists in isolated HOME
if [ -f "$ISOLATED_HOME/.claude/credentials.json" ]; then
  fail "credentials.json unexpectedly present in isolated HOME (test setup bug)"
else
  pass "isolated HOME has no credentials.json (test setup correct)"
fi

# ----------------------------------------------------------------------------
# S2 — Subscription + API key → rc=0 (existing path must not regress)
# ----------------------------------------------------------------------------

echo ""
echo "=== S2: subscription login with API key also set ==="

ISOLATED_HOME2="$MOCK_ROOT/home2"
mkdir -p "$ISOLATED_HOME2"

if run_health_claude "ok" "$ISOLATED_HOME2" "test-key-do-not-use"; then
  pass "claude health OK when ANTHROPIC_API_KEY is also set"
else
  fail "claude health FAILED when ANTHROPIC_API_KEY is set (rc=$?)"
fi

# ----------------------------------------------------------------------------
# S3 — claude binary absent → rc=1 (existing behavior)
# ----------------------------------------------------------------------------

echo ""
echo "=== S3: no claude binary in PATH ==="

ISOLATED_HOME3="$MOCK_ROOT/home3"
mkdir -p "$ISOLATED_HOME3"

# Use an empty mock dir so PATH doesn't contain claude
EMPTY_BIN="$MOCK_ROOT/empty-bin"
mkdir -p "$EMPTY_BIN"

(
  cd /tmp && \
  HOME="$ISOLATED_HOME3" \
  PATH="$EMPTY_BIN:/usr/bin:/bin" \
  "$HEALTH_CHECK" tool claude
)
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "claude health correctly reports missing binary (rc=1)"
else
  fail "claude health unexpected rc when binary missing (rc=$rc, expected 1)"
fi

# ----------------------------------------------------------------------------
# S4 — claude --version fails → rc=1 (existing behavior)
# ----------------------------------------------------------------------------

echo ""
echo "=== S4: claude --version returns non-zero ==="

ISOLATED_HOME4="$MOCK_ROOT/home4"
mkdir -p "$ISOLATED_HOME4"

if run_health_claude "fail-version" "$ISOLATED_HOME4" ""; then
  fail "claude health unexpectedly OK when --version fails"
else
  pass "claude health correctly rejects failing --version"
fi

# ----------------------------------------------------------------------------
# Cleanup + results
# ----------------------------------------------------------------------------

rm -rf "$MOCK_ROOT"

echo ""
echo "=== Results ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

[ "$FAILED" -eq 0 ]