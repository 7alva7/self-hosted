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
# The assertions against the shared container below are not "does WebDAV
# work" but "does it still work with the token-resolving middleware in front
# of it, end to end through PrefixDirectory". They are NOT, by themselves,
# proof that WebDAV survives ONLY_AUTHORIZED's instance-wide login gate --
# /webdav is NOT in web-ui's onlyAuthorizedExempt() list (serve.go) -- unlike
# /stremio, /api/v1, /s3 and /embed, which are deliberately exempted there.
# WebDAV survives the gate only because handlers/access_token's
# token-resolving middleware is registered (ats.RegisterHandler, serve.go)
# *before* r.Use(auth.OnlyAuthorized(...)) is mounted: it injects the
# token's user into the request context first, so OnlyAuthorized's own
# HasAuth() check (auth/only_authorized.go) finds an authenticated user and
# never fires. That is an accident of registration order, not a declared
# exemption -- reorder the two r.Use() calls in serve.go and a real,
# ADMIN_PASSWORD-protected deployment would start 302-redirecting (or
# 401-ing) every WebDAV client with no test anywhere noticing.
#
# This suite's shared container runs with no ADMIN_PASSWORD, i.e. as
# web-ui's "open instance" (services/auth/auth.go's auto-admin branch, the
# same one 90-api.sh's assertion #2 and 92-cli.sh rely on) -- there,
# OnlyAuthorized's HasAuth() check passes for every request regardless of
# token, because auto-admin already registers a real user before it runs.
# So no assertion against the shared container can exercise the
# session-vs-token distinction the real risk lives in. Section 5 below
# closes that gap the same way 60-admin-password.sh does: it starts its own,
# throwaway container with ADMIN_PASSWORD set, confirms an ordinary page
# genuinely cannot be read without a session there, and only then proves a
# tokened WebDAV request still reaches the surface -- the assertion that
# actually has teeth, on a box where OnlyAuthorized's HasAuth() would reject
# anyone without one.
#
# Re-runnable against a warm container for the assertions against the
# shared container: POST /webdav/url/generate is idempotent
# (models.MakeAccessToken keeps the existing token on conflict -- see
# docs/webdav.md's "Token management" table), and every request against it
# below is a read (PROPFIND/GET). Section 5's own container is destroyed
# (via its own EXIT-trapped `docker rm -f`) before this script exits either
# way, so it never lingers for a second run to collide with.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

jar="$(mktemp)"
closed_jar=""
closed_login_body=""
closed_name=""

cleanup() {
  rm -f "$jar"
  [ -z "$closed_jar" ] || rm -f "$closed_jar"
  [ -z "$closed_login_body" ] || rm -f "$closed_login_body"
  [ -z "$closed_name" ] || docker rm -f "$closed_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A plain GET establishes the session and carries the _csrf token the
# generate form needs -- same pattern as api_key() in lib.sh and
# 91-s3-webui.sh's profile fetch.
profile_body="$(curl --fail-with-body -sS -c "$jar" "$BASE_URL/profile")" \
  || fail "GET /profile failed"
csrf_token="$(csrf_from "$profile_body")" || csrf_token=""
[ -n "$csrf_token" ] || fail "GET /profile did not render an _csrf token to submit"

webdav_field() {
  # Pulls the value out of `var webdavUrl = "...";`, rendered inline (not
  # behind an async fragment) in profile/webdav.html. Go's html/template
  # renders this in a JS-string context, which always quotes -- same
  # reasoning as 91-s3-webui.sh's s3_field. Escaped slashes (\/) are
  # unescaped so the result is a normal URL.
  local raw
  raw="$(first_group 'var webdavUrl = "([^"]*)"' "$1")" || return 1
  # The slash goes through a variable: written literally, the replacement
  # pattern in ${var//\//} is ambiguous with the expansion's own delimiter
  # and silently leaves the string untouched.
  local sl="/"
  printf '%s' "${raw//\\$sl/$sl}"
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

# --- 5. The assertion with teeth: a closed instance (ADMIN_PASSWORD is read
# at startup, so this needs its own container, same as 60-admin-password.sh) ---
closed_port=18098
closed_name=webtor-smoke-webdav-closed
closed_password=smoke-webdav-password

docker rm -f "$closed_name" >/dev/null 2>&1 || true
docker run -d --name "$closed_name" -e ADMIN_PASSWORD="$closed_password" \
  -p "$closed_port:8080" "${WEBTOR_IMAGE:-ghcr.io/webtor-io/self-hosted:latest}" >/dev/null

closed="http://localhost:$closed_port"
wait_for 180 "closed instance to boot" curl -fsS -o /dev/null "$closed/login"

# 5a. Confirm the instance really is locked down: an ordinary page must
# redirect to the login form, not render -- otherwise #5c below would prove
# nothing about the gate.
headers="$(curl -s -o /dev/null -D - \
  -H 'Accept: text/html' -H 'Sec-Fetch-Mode: navigate' \
  "$closed/profile")"
code="$(head -1 <<<"$headers" | tr -d '\r' | awk '{print $2}')"
assert_eq "$code" "302" "a protected page on the closed WebDAV-test instance must redirect to the login form"
location="$(printf '%s' "$headers" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
case "$location" in
  *login*) : ;;
  *) fail "redirect Location does not point at the login form (got '$location')" ;;
esac

# 5b. Log in (same shape as 60-admin-password.sh) and mint a "webdav"
# access_token inside this session. GET /login is the CSRF-form scrape
# target here, not GET /profile: profile/webdav.html renders its own
# _csrf-carrying form, but profile/password.html -- the only other form on
# /profile -- switches to a plain "managed by env" hint with no form at all
# once ADMIN_PASSWORD is set (PasswordManagedEnv, templates/partials/
# profile/password.html), so a closed instance's /profile page carries no
# _csrf field until a token already exists. The token scraped from /login
# stays valid for the later /webdav/url/generate POST in the same
# session/jar -- csrf.GetToken() (utrack/gin-csrf, wired in handlers/
# session/handler.go) mints one salt per session and derives every token
# from it, not one salt per page, the same fact 60-admin-password.sh's own
# comment relies on to reuse its scraped token across both its login
# attempts.
closed_jar="$(mktemp)"
closed_login_body="$(mktemp)"
curl -fsS -c "$closed_jar" -o "$closed_login_body" "$closed/login"
csrf_token="$(csrf_from "$(cat "$closed_login_body")")" || csrf_token=""
[ -n "$csrf_token" ] || fail "GET /login (closed instance) did not render an _csrf token to submit"

login_headers="$(curl -s -o /dev/null -D - -b "$closed_jar" -c "$closed_jar" \
  -X POST --data-urlencode "_csrf=$csrf_token" -d "password=$closed_password" "$closed/login")"
login_code="$(head -1 <<<"$login_headers" | tr -d '\r' | awk '{print $2}')"
assert_eq "$login_code" "302" "login with the correct password on the closed WebDAV-test instance"

# services/session's csrf.Middleware exempts the whole "/webdav/" prefix
# from its own mismatch check (serve.go's sess.RegisterHandler csrfIgnorePrefixes
# list, alongside /s/, /token/, /s3/, /api/, /auth/dashboard,
# /transcoder-session/ -- the same fact 91-s3-webui.sh documents for /s3/'s
# own generate endpoint) -- so this POST would in fact succeed even with a
# wrong or missing _csrf value. The real token is submitted anyway: this
# scenario is proving the WebDAV *feature*, not probing which prefixes
# happen to skip CSRF enforcement, and a real browser submits the real
# value regardless of whether the server would have let a wrong one
# through.
gen_headers="$(curl -s -o /dev/null -D - -b "$closed_jar" -c "$closed_jar" \
  -X POST --data-urlencode "_csrf=$csrf_token" "$closed/webdav/url/generate")"
gen_code="$(head -1 <<<"$gen_headers" | tr -d '\r' | awk '{print $2}')"
assert_eq "$gen_code" "302" "POST /webdav/url/generate on the closed WebDAV-test instance"

closed_profile_body="$(curl --fail-with-body -sS -b "$closed_jar" -c "$closed_jar" "$closed/profile")" \
  || fail "GET /profile (closed instance, authenticated) failed"
closed_webdav_url="$(webdav_field "$closed_profile_body" || true)"
[ -n "$closed_webdav_url" ] || fail "could not obtain a WebDAV URL from the closed instance's /profile after generating"

# The scraped URL embeds web-ui's configured DOMAIN (unset for this
# throwaway container, so it defaults to the image's baked-in value, not
# this container's actual published port) -- only the path is real, so this
# reduces the scraped URL to that path and replays it against $closed.
closed_webdav_path="$(printf '%s' "$closed_webdav_url" | sed -E 's#^https?://[^/]+##')"
case "$closed_webdav_path" in
  /s/*/webdav/) : ;;
  *) fail "WebDAV URL path from the closed instance does not look like the documented alias: $closed_webdav_path" ;;
esac

# 5c. The assertion with teeth: a tokened WebDAV request still reaches the
# surface on an instance where #5a already proved an uncredentialed request
# to an ordinary page cannot.
resp="$(propfind "$closed$closed_webdav_path" 1)"
split_status "$resp"
assert_eq "$STATUS" "207" "credentialed PROPFIND on the closed WebDAV-test instance status"
closed_names="$(printf '%s' "$BODY" | python3 -c "
import sys, xml.etree.ElementTree as ET
ns = {'d': 'DAV:'}
root = ET.fromstring(sys.stdin.read())
print(' '.join(sorted(e.text for e in root.findall('.//d:response/d:propstat/d:prop/d:displayname', ns))))
" 2>&1)" || fail "closed-instance credentialed PROPFIND response is not well-formed WebDAV multistatus XML: $closed_names
  body was: $BODY"
assert_eq "$closed_names" "all movies series torrents" "closed-instance credentialed PROPFIND root displayname set"

# 5d. Both directions on the closed instance: the same request with no
# token/cookie at all must NOT reach the surface. This is the negative
# control that gives 5c its teeth -- if this one also returned 207, 5c would
# not be proving the gate did anything.
resp="$(propfind "$closed/webdav/fs/webdav/" 1)"
split_status "$resp"
case "$STATUS" in
  401 | 302) : ;;
  *) fail "uncredentialed PROPFIND on the closed WebDAV-test instance status (got '$STATUS', want 401 or a redirect to /login)" ;;
esac
[ -z "$BODY" ] || fail "uncredentialed PROPFIND on the closed instance returned a body, expected bare status: $BODY"

echo "PASS-detail: closed instance (ADMIN_PASSWORD set) -- /profile redirects to login unauthenticated, a tokened WebDAV request still returns 207 with the real root shape, and the same request with no token/cookie is rejected ($STATUS)"

echo "PASS: webdav"
