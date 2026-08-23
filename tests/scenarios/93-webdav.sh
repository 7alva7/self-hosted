#!/usr/bin/env bash
# WebDAV: a read-only view of the user's library (services/libfs), reached
# through handlers/webdav and the WebDAV-only PrefixDirectory that splits the
# request path on the literal string "webdav" so every href in a response
# round-trips the alias prefix intact (see web-ui/docs/webdav.md, "Request
# routing" and "Why the path still works").
#
# Credential: an access_token row named "webdav", scopes webdav:read +
# webdav:write, minted by POST /webdav/url/generate (session + CSRF, same
# form dance as S3's *-credentials/generate in 91-s3-webui.sh) and consumed
# as ?token=<uuid> on /webdav/fs/*rest. The user-facing URL is a short alias
# (/s/<code>/webdav/, resolved by services/url_alias in *proxy* mode --
# rewritten in-process via gin.Engine.HandleContext, not a redirect); unlike
# S3's credential triple, web-ui renders this URL directly into the plain
# (non-XHR) GET /profile response -- templates/views/profile/get.html renders
# "profile/webdav" inline, not only behind the data-async-layout fragment --
# so no X-Layout dance is needed here, just a plain GET.
#
# The central assertion below is not "does WebDAV work" but "does it still
# work with ONLY_AUTHORIZED's instance-wide login gate mounted". /webdav is
# NOT in web-ui's onlyAuthorizedExempt() list (serve.go) -- unlike /stremio,
# /api/v1, /s3 and /embed, which are deliberately exempted there. WebDAV
# survives the gate only because handlers/access_token's token-resolving
# middleware is registered (ats.RegisterHandler, serve.go) *before*
# r.Use(auth.OnlyAuthorized(...)) is mounted: it injects the token's user
# into the request context first, so OnlyAuthorized's own HasAuth() check
# (auth/only_authorized.go) finds an authenticated user and never fires.
# That is an accident of registration order, not a declared exemption --
# reorder the two r.Use() calls in serve.go and a real, ADMIN_PASSWORD-
# protected deployment would start 302-redirecting every WebDAV client to
# /login with no test anywhere noticing. Caveat, stated plainly: this
# suite's shared container runs with no ADMIN_PASSWORD, i.e. as web-ui's
# "open instance" (services/auth/auth.go's auto-admin branch, the same one
# 90-api.sh's assertion #2 and 92-cli.sh rely on) -- on THIS container,
# OnlyAuthorized's HasAuth() check passes for every request regardless of
# token, because auto-admin already registers a real user before it runs.
# So this assertion cannot exercise the session-vs-token distinction the
# real risk lives in; it verifies (a) ONLY_AUTHORIZED's gate is genuinely
# mounted here (read from the live web-ui process's own environment, not the
# container's unexpanded common.env template) and (b) the token-gated
# request still resolves end to end through PrefixDirectory with that gate
# mounted. What it does still catch: any regression that breaks the
# token->user wiring, the /webdav route registration, or the doubled-
# "webdav" path-splitting -- just not a reordering that only a password-
# protected deployment would expose.
#
# Re-runnable against a warm container: POST /webdav/url/generate is
# idempotent (models.MakeAccessToken keeps the existing token on conflict --
# see docs/webdav.md's "Token management" table), and every request below is
# a read (PROPFIND/GET), so nothing this scenario does needs cleanup or an
# EXIT trap.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

# A plain GET establishes the session and carries the _csrf token the
# generate form needs -- same pattern as api_key() in lib.sh and
# 91-s3-webui.sh's profile fetch.
profile_body="$(curl --fail-with-body -sS -c "$jar" "$BASE_URL/profile")" \
  || fail "GET /profile failed"
csrf_token="$(printf '%s' "$profile_body" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
[ -n "$csrf_token" ] || fail "GET /profile did not render an _csrf token to submit"

webdav_field() {
  # Pulls the value out of `var webdavUrl = "...";`, rendered inline (not
  # behind an async fragment) in profile/webdav.html. Go's html/template
  # renders this in a JS-string context, which always quotes -- same
  # reasoning as 91-s3-webui.sh's s3_field. Escaped slashes (\/) are
  # unescaped so the result is a normal URL.
  printf '%s' "$1" | grep -o 'var webdavUrl = "[^"]*"' | head -1 \
    | sed -E 's/.*"(.*)"/\1/; s/\\\//\//g'
}

webdav_url="$(webdav_field "$profile_body" || true)"
if [ -z "$webdav_url" ]; then
  curl --fail-with-body -sS -b "$jar" -c "$jar" \
    -X POST --data-urlencode "_csrf=$csrf_token" \
    "$BASE_URL/webdav/url/generate" >/dev/null \
    || fail "POST /webdav/url/generate was rejected"
  profile_body="$(curl --fail-with-body -sS -b "$jar" -c "$jar" "$BASE_URL/profile")" \
    || fail "GET /profile (after generate) failed"
  webdav_url="$(webdav_field "$profile_body" || true)"
fi
[ -n "$webdav_url" ] || fail "could not obtain a WebDAV URL from /profile, generated or pre-existing"

case "$webdav_url" in
  http*://*/s/*/webdav/) : ;;
  *) fail "WebDAV URL does not look like the documented /s/<code>/webdav/ alias: $webdav_url" ;;
esac

# --- helpers -------------------------------------------------------------

propfind() {
  local url="$1" depth="$2"
  shift 2
  curl -sS -X PROPFIND -H "Depth: $depth" -w 'HTTPSTATUS:%{http_code}' "$url" "$@"
}
split_status() {
  STATUS="${1##*HTTPSTATUS:}"
  BODY="${1%HTTPSTATUS:*}"
}

# --- 1. ONLY_AUTHORIZED is actually mounted on this container ------------
# Read from the live web-ui process's own environment inside the container,
# not /etc/webtor/common.env: that file is a shell fragment with
# ${ONLY_AUTHORIZED:-true}-style defaults meant to be evaluated by each
# service's own "set -a; source common.env" at run time (see this repo's own
# CLAUDE.md, "Прокидывание конфигурации") -- grepping it directly would just
# match the unexpanded template text and prove nothing about what web-ui
# actually saw.
webui_pid="$(webtor_exec sh -c 'pgrep -f "web-ui serve"')" \
  || fail "could not find the running web-ui process to inspect its environment"
only_authorized="$(webtor_exec sh -c "tr '\\0' '\\n' < /proc/$webui_pid/environ | grep '^ONLY_AUTHORIZED='" || true)"
assert_eq "$only_authorized" "ONLY_AUTHORIZED=true" "web-ui process env ONLY_AUTHORIZED (self-hosted's default -- if this ever reads false the assertion below is not testing what its comment claims)"

# --- 2. Credentialed PROPFIND succeeds and lists the real root shape -----
# Depth 1 on the alias root lists RootDirectory's four virtual top-level
# dirs (docs/webdav.md) -- this is WebDAV's actual content shape, not just
# "some XML came back".
resp="$(propfind "$webdav_url" 1)"
split_status "$resp"
assert_eq "$STATUS" "207" "credentialed PROPFIND Depth:1 on WebDAV root status"

# xml.etree (not defusedxml) is fine here for the same reason 91-s3-webui.sh
# gives for its own xml_field: the body is generated exclusively by
# services/webdav's own marshaller against our own just-issued request, never
# third-party or user-supplied XML -- there is no XXE surface to defend
# against.
names="$(printf '%s' "$BODY" | python3 -c "
import sys, xml.etree.ElementTree as ET
ns = {'d': 'DAV:'}
root = ET.fromstring(sys.stdin.read())
print(' '.join(sorted(e.text for e in root.findall('.//d:response/d:propstat/d:prop/d:displayname', ns))))
" 2>&1)" || fail "credentialed PROPFIND response is not well-formed WebDAV multistatus XML: $names
  body was: $BODY"
assert_eq "$names" "all movies series torrents" "credentialed PROPFIND root displayname set"

echo "PASS-detail: credentialed PROPFIND on $webdav_url returned 207 with the four root dirs"

# --- 3. Uncredentialed request is rejected, bare status, no XML ----------
# Hits the underlying route directly (bypassing the /s/<code> alias, which
# has no meaning without a code) with no ?token= at all. access_token.HasScope
# (services/access_token/access_token.go) checks for the token query param
# before anything else -- absent, it aborts 400 without ever reaching
# PrefixDirectory or the WebDAV protocol handler, so there is no XML
# envelope to parse, only a bare status.
resp="$(propfind "$BASE_URL/webdav/fs/webdav/" 1)"
split_status "$resp"
assert_eq "$STATUS" "400" "uncredentialed PROPFIND status (no ?token= at all)"
[ -z "$BODY" ] || fail "uncredentialed PROPFIND (no token) returned a body, expected bare status: $BODY"

# --- 4. Well-formed but unissued token: a different, later rejection -----
# Clears HasScope's "is there a token param" check, reaches getToken(), and
# is rejected there instead (at == nil -> 401) -- the same well-formed
# all-zero UUID trick 90-api.sh and 92-cli.sh use for their own "valid shape,
# never issued" negative controls, exercising a different code path than #3.
resp="$(propfind "$BASE_URL/webdav/fs/webdav/?token=00000000-0000-0000-0000-000000000000" 1)"
split_status "$resp"
assert_eq "$STATUS" "401" "uncredentialed PROPFIND status (well-formed, unissued token)"
[ -z "$BODY" ] || fail "uncredentialed PROPFIND (unissued token) returned a body, expected bare status: $BODY"

echo "PASS-detail: uncredentialed PROPFIND rejected with bare 400 (no token) and bare 401 (unissued token)"

echo "PASS: webdav"
