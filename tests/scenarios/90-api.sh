#!/usr/bin/env bash
# The JSON API (/api/v1) as a surface in its own right. Every other scenario
# already exercises it heavily through apiv1/apiv1_json (lib.sh), but only as
# plumbing to set up other assertions -- nothing in the suite checks the
# API's own auth contract or error envelope. This does.
#
# Re-runnable against a warm container: every request here is read-only
# (GET /library, GET /docs, GET /swagger.json) or targets credentials that
# were already invalid before this scenario ran (a fixed all-zero UUID, no
# header at all). Nothing is created, so a second run leaves nothing behind
# to interfere with a third.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# api_v1_raw <method> <path> [extra curl args...] -- like `api`, but never
# lets --fail-with-body turn a non-2xx into a nonzero exit. Unlike `api` and
# `apiv1`, this scenario's whole point is to look at the body and status of
# *rejected* requests, not just succeed-or-fail.
api_v1_raw() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" -w 'HTTPSTATUS:%{http_code}' "$BASE_URL/api/v1$path" "$@"
}

# split_status <combined> -- fills STATUS/BODY from api_v1_raw's output.
split_status() {
  STATUS="${1##*HTTPSTATUS:}"
  BODY="${1%HTTPSTATUS:*}"
}

# error_field <body> <code|message> -- pulls one field out of the
# {"error":{"code":...,"message":...}} envelope. Failing to parse is itself
# the assertion for "the response is shaped like the documented envelope",
# not an incidental crash -- a bare 401 with an HTML or empty body, or a JSON
# body with a different shape, must fail here rather than fall through to a
# string-compare that silently passes on garbage.
error_field() {
  local body="$1" field="$2" out
  out="$(printf '%s' "$body" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['error']['$field'])
" 2>&1)" || fail "response body is not the documented {\"error\":{...}} envelope (field '$field'): $out
  body was: $body"
  printf '%s' "$out"
}

# --- 1. No credential at all -------------------------------------------
resp="$(api_v1_raw GET /library)"
split_status "$resp"
assert_eq "$STATUS" "401" "unauthenticated GET /api/v1/library status"

code="$(error_field "$BODY" code)"
assert_eq "$code" "unauthorized" "unauthenticated response error.code"

message="$(error_field "$BODY" message)"
case "$message" in
  *'Authorization: Bearer <key>'*'profile page'*) : ;;
  *) fail "unauthenticated response error.message does not match the documented text: $message" ;;
esac

# --- 2. Syntactically valid but wrong key -------------------------------
# All-zero UUID: passes the middleware's uuid.FromString gate (so it reaches
# the same code path a real key would) but is not, and never will be, an
# actual issued access_token row.
#
# This is NOT the 401 a naive reading of web-ui's generic auth contract would
# suggest, and that is specific to self-hosted, not a mistake in this
# assertion. This container runs with no ADMIN_PASSWORD, i.e. as an "open
# instance" (web-ui services/auth/auth.go, RegisterHandler's "no password
# configured -> open instance, auto-admin" branch): every request is
# auto-registered as the admin user regardless of whether it carries any key
# at all, before the API handler's own
# auth.GetUserFromContext(c).HasAuth() check ever runs. So a
# well-formed-but-unissued UUID clears that HasAuth() gate (real 401
# territory elsewhere) and instead trips the *next* gate down: the request
# carries no scope (no access_token row means no TokenScope in context), so
# HasScope(nil, "api:read") fails and the handler answers 403 forbidden, not
# 401 unauthorized. A garbage, non-UUID-shaped key takes a different, earlier
# branch instead (rejected as 401 by the key/query mismatch check before
# HasAuth() is even consulted) -- this scenario deliberately picks the
# UUID-shaped case because it is the one that actually reaches, and proves,
# the scope check.
wrong_key="00000000-0000-0000-0000-000000000000"
resp="$(api_v1_raw GET /library -H "Authorization: Bearer $wrong_key")"
split_status "$resp"
assert_eq "$STATUS" "403" "wrong-key GET /api/v1/library status"

code="$(error_field "$BODY" code)"
assert_eq "$code" "forbidden" "wrong-key response error.code"

message="$(error_field "$BODY" message)"
assert_eq "$message" "this key is not allowed to use the API" "wrong-key response error.message"

# --- 3. Real key succeeds ------------------------------------------------
body="$(apiv1 GET /library)" || fail "authenticated GET /api/v1/library was rejected"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert isinstance(d, dict), "response is not a JSON object: %r" % (d,)
assert isinstance(d.get("items"), list), "response has no \"items\" array: %r" % (d,)
assert d.get("type") == "all", "response echoed type=%r, want \"all\" (the default)" % (d.get("type"),)
' "$body" || fail "authenticated GET /api/v1/library did not return the documented LibraryListResponse shape: $body"

# --- 4. Docs are reachable without any credential ------------------------
docs_code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/v1/docs/index.html")"
assert_eq "$docs_code" "200" "unauthenticated GET /api/v1/docs/index.html status"

spec="$(curl --fail-with-body -sS "$BASE_URL/api/v1/swagger.json")" \
  || fail "unauthenticated GET /api/v1/swagger.json was rejected"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert "paths" in d, "swagger.json has no \"paths\" key: keys were %r" % (list(d.keys()),)
assert "/library" in d["paths"], "swagger.json paths do not include /library: %r" % (list(d["paths"].keys()),)
' "$spec" || fail "unauthenticated GET /api/v1/swagger.json did not return a parseable Swagger spec: $spec"

echo "PASS: api"
