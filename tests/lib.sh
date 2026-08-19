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

# api_key -- returns a cached API key for this run, minting one only if the
# account does not already have one.
#
# The suite's shared container runs with no ADMIN_PASSWORD, so every visitor
# is auto-admin (HasAuth passes with no login) -- that is what lets this mint
# a key with no credentials. Issuing needs a session cookie AND a CSRF token:
# POST /api-credentials/generate is not covered by the CSRF-ignore list (only
# the /api/ prefix is ignored, and that does not reach /api-credentials), so
# a page that renders a form is fetched first to establish a session and
# scrape the _csrf hidden input, exactly like a browser submitting that form
# would (see the login flow in 60-admin-password.sh for the same pattern).
# /profile is used for that page: it is where a real admin goes to manage
# API credentials, and it renders a form carrying the same _csrf input.
#
# GET /api-credentials/key is checked before generating: it returns 200 with
# {"key":"<uuid>"} if a key already exists for the account, 204 with no body
# otherwise. Fetching first (rather than unconditionally generating) means
# re-running scenarios against the same shared container reuses the one key
# already on the account instead of minting a fresh one every time.
#
# Cached in a file, not a plain shell variable: every caller so far invokes
# this through `apiv1`, and every existing call site captures apiv1's output
# with `x="$(apiv1 ...)"` -- command substitution always forks a subshell in
# bash, so a variable assigned inside api_key() would only ever update that
# subshell's copy and vanish the instant it exits, silently re-running the
# whole profile/CSRF/generate dance on every single call. $$ is stable across
# those subshells (bash documents it as "the process ID of the invoking
# shell, not the subshell"), so a $$-scoped file survives them and still
# gives each scenario script -- a fresh `bash scenario.sh` process -- its own
# cache. It is not cleaned up: it's a few bytes per scenario run, and scoping
# cleanup here would fight the EXIT trap every scenario already sets for its
# own temp files (last trap wins, so ours would just get silently dropped).
_API_KEY_CACHE_FILE="${TMPDIR:-/tmp}/webtor-smoke-api-key.$$"
api_key() {
  if [ -s "$_API_KEY_CACHE_FILE" ]; then
    cat "$_API_KEY_CACHE_FILE"
    return 0
  fi

  local jar body csrf_token resp code key_json key

  jar="$(mktemp)"
  body="$(curl --fail-with-body -sS -c "$jar" "$BASE_URL/profile")"
  csrf_token="$(printf '%s' "$body" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
  [ -n "$csrf_token" ] || fail "GET /profile did not render an _csrf token to submit"

  resp="$(curl -sS -b "$jar" -w 'HTTPSTATUS:%{http_code}' "$BASE_URL/api-credentials/key")"
  code="${resp##*HTTPSTATUS:}"
  key_json="${resp%HTTPSTATUS:*}"

  if [ "$code" = "204" ]; then
    curl --fail-with-body -sS -b "$jar" -c "$jar" \
      -X POST --data-urlencode "_csrf=$csrf_token" \
      "$BASE_URL/api-credentials/generate" >/dev/null

    resp="$(curl -sS -b "$jar" -w 'HTTPSTATUS:%{http_code}' "$BASE_URL/api-credentials/key")"
    code="${resp##*HTTPSTATUS:}"
    key_json="${resp%HTTPSTATUS:*}"
  fi

  [ "$code" = "200" ] || fail "GET /api-credentials/key returned unexpected status $code: $key_json"

  key="$(printf '%s' "$key_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])' 2>&1)" \
    || fail "could not parse API key from /api-credentials/key response: $key ($key_json)"
  [ -n "$key" ] || fail "API key response parsed but was empty: $key_json"

  rm -f "$jar"
  printf '%s' "$key" > "$_API_KEY_CACHE_FILE"
  cat "$_API_KEY_CACHE_FILE"
}

# apiv1 <method> <path> [extra curl args...]
# Mirrors `api` above but hits web-ui's authenticated /api/v1, which is the
# only way to create/read resources now that nginx no longer exposes
# rest-api directly. A middleware in front of /api/v1 copies the
# Authorization header's key into the query parameter the handler
# cross-checks, so the caller only needs to supply the header.
apiv1() {
  local method="$1" path="$2"
  shift 2
  curl --fail-with-body -sS -X "$method" \
    -H "Authorization: Bearer $(api_key)" \
    "$BASE_URL/api/v1$path" "$@"
}

# webtor_exec <cmd...>
# Runs a command inside the running webtor container (the "webtor" service
# in docker-compose.yml) via docker compose exec.
webtor_exec() {
  docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT" \
    exec -T webtor "$@"
}
