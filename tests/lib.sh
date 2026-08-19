# Shared helpers for smoke scenarios. Sourced, not executed.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"
BASE_URL="${BASE_URL:-http://localhost:${WEBTOR_HOST_PORT:-8080}}"
# Must match the -p passed by run.sh.
COMPOSE_PROJECT="${COMPOSE_PROJECT:-webtor-smoke}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  [ "$actual" = "$expected" ] || fail "$msg (got '$actual', want '$expected')"
}

# wait_for <timeout-sec> <description> <command...>
# Retries until the command succeeds or the timeout expires. On timeout the last
# attempt's exit status and combined output are reported: without them every
# failure looks identical, and "rejected immediately" (e.g. a 403) is
# indistinguishable from "genuinely still unavailable".
WAIT_FOR_OUTPUT_LIMIT="${WAIT_FOR_OUTPUT_LIMIT:-500}"
wait_for() {
  local timeout="$1" desc="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  local out rc detail
  while true; do
    # Assignment is the non-final operand of &&, so a failure here does not
    # trip `set -e`; it falls through to the deadline check below.
    out="$("$@" 2>&1)" && return 0
    rc=$?
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done

  detail="$(printf '%s' "$out" | head -c "$WAIT_FOR_OUTPUT_LIMIT")"
  if [ "${#out}" -gt "$WAIT_FOR_OUTPUT_LIMIT" ]; then
    detail="$detail ...[truncated, ${#out} bytes total]"
  fi
  [ -n "$detail" ] || detail='(no output)'
  fail "timed out after ${timeout}s waiting for: $desc
  last attempt: '$*'
  exit status:  $rc
  output:       $detail"
}

# api <method> <path> [extra curl args...]
api() {
  local method="$1" path="$2"
  shift 2
  curl --fail-with-body -sS -X "$method" "$BASE_URL$path" "$@"
}

# webtor_exec <cmd...>
# Runs a command inside the running webtor container (the "webtor" service
# in docker-compose.yml) via docker compose exec.
webtor_exec() {
  docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT" \
    exec -T webtor "$@"
}
