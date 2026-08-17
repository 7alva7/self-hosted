# Shared helpers for smoke scenarios. Sourced, not executed.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"
BASE_URL="${BASE_URL:-http://localhost:8080}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  [ "$actual" = "$expected" ] || fail "$msg (got '$actual', want '$expected')"
}

# wait_for <timeout-sec> <description> <command...>
wait_for() {
  local timeout="$1" desc="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || fail "timed out after ${timeout}s waiting for: $desc"
    sleep 1
  done
}

# api <method> <path> [extra curl args...]
api() {
  local method="$1" path="$2"
  shift 2
  curl --fail-with-body -sS -X "$method" "$BASE_URL$path" "$@"
}
