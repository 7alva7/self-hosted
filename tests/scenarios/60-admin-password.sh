#!/usr/bin/env bash
# With ADMIN_PASSWORD set, the instance must require a password to reach any
# protected page and must never accept a wrong one; without it, the instance
# stays exactly as open as it always was. Both directions matter: the first
# is the feature, the second is that we did not break existing installs.
#
# NOT EXECUTED as part of this change -- see task-10-report.md. It needs a
# self-hosted image whose Dockerfile pins a web-ui digest carrying the
# admin-password feature, which does not exist in GHCR yet (web-ui's CI only
# publishes on pushes to main), and a running Docker daemon, neither of which
# was available while writing this.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# --- Open instance: the suite's shared container runs without ADMIN_PASSWORD ---
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")"
assert_eq "$code" "200" "front page on an open instance"

body="$(curl -sL "$BASE_URL/")"
case "$body" in
  *open-instance-banner*) : ;;
  *) fail "the open-instance banner is missing from an instance with no password" ;;
esac

# --- Closed instance: ADMIN_PASSWORD is read at startup, so this needs its own container ---
port=18099
name=webtor-smoke-adminpw
cookiejar=""
wrong_body=""
login_body_file=""

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  [ -z "$cookiejar" ] || rm -f "$cookiejar"
  [ -z "$wrong_body" ] || rm -f "$wrong_body"
  [ -z "$login_body_file" ] || rm -f "$login_body_file"
}
trap cleanup EXIT

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -e ADMIN_PASSWORD=smoke-test-password \
  -p "$port:8080" "${WEBTOR_IMAGE:-ghcr.io/webtor-io/self-hosted:latest}" >/dev/null

closed="http://localhost:$port"
wait_for 180 "closed instance to boot" curl -fsS -o /dev/null "$closed/login"

# A browser navigation to a protected page must redirect to the login form,
# carrying the original path back via return-url so login can send you home.
headers="$(curl -s -o /dev/null -D - \
  -H 'Accept: text/html' -H 'Sec-Fetch-Mode: navigate' \
  "$closed/profile")"
code="$(printf '%s' "$headers" | head -1 | tr -d '\r' | awk '{print $2}')"
assert_eq "$code" "302" "a protected page on a closed instance must redirect to the login form"

location="$(printf '%s' "$headers" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
case "$location" in
  *login*return-url*profile*) : ;;
  *) fail "redirect Location does not carry both the login target and a return-url back to /profile (got '$location')" ;;
esac

# GET /login must render an actual password form, not just any 200. It also
# establishes the session that carries the CSRF salt (see
# handlers/session/handler.go in web-ui: csrf.Middleware answers every POST
# with 400 unless the request carries both a session cookie and the _csrf
# token minted into that same session), so this step keeps a cookie jar and
# scrapes the hidden "_csrf" field a real browser would submit unmodified --
# exactly like templates/views/auth/password.html does.
cookiejar="$(mktemp)"
login_body_file="$(mktemp)"
curl -fsS -c "$cookiejar" -o "$login_body_file" "$closed/login"
login_body="$(cat "$login_body_file")"
case "$login_body" in
  *'type="password"'*) : ;;
  *) fail "GET /login did not render a password field" ;;
esac

csrf_token="$(printf '%s' "$login_body" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
[ -n "$csrf_token" ] || fail "GET /login did not render an _csrf token to submit"

# A wrong password must be rejected with 401 and the form re-rendered --
# never a redirect (a redirect here would mean a session got set anyway).
# This is the suite's only wrong-password attempt: the feature rate-limits
# login attempts per direct peer (five at once, then one per five seconds),
# and this scenario has no need to go anywhere near that limit.
# Reuses the CSRF token scraped above: the underlying utrack/gin-csrf
# GetToken() (wired in handlers/session/handler.go) only mints a fresh salt
# when the session has none yet, and nothing on the wrong-password path
# calls session.Save(), so the token stays valid for the next request in
# this same jar.
wrong_body="$(mktemp)"
wrong_headers="$(curl -s -o "$wrong_body" -D - -b "$cookiejar" -c "$cookiejar" \
  -X POST --data-urlencode "_csrf=$csrf_token" -d 'password=wrong-password' "$closed/login")"
wrong_code="$(printf '%s' "$wrong_headers" | head -1 | tr -d '\r' | awk '{print $2}')"
[ "$wrong_code" = "401" ] || fail "a wrong password did not return 401 (got $wrong_code)"
case "$(cat "$wrong_body")" in
  *'type="password"'*) : ;;
  *) fail "a wrong password's 401 response did not re-render the password form" ;;
esac

# The right password must set a session and redirect -- proving the whole
# loop closes, not just that wrong passwords are rejected. Checking for a
# fresh Set-Cookie on this exact response (rather than just "the jar is
# non-empty") is the meaningful signal now that the jar already holds the
# pre-login session cookie fetched above for CSRF purposes: passwordLogin
# only calls session.Save() -- which is what emits Set-Cookie -- on the
# success path, never on the 401 path above. Confirm the session actually
# works by reusing it against the page we were bounced from.
right_headers="$(curl -s -o /dev/null -D - -b "$cookiejar" -c "$cookiejar" \
  -X POST --data-urlencode "_csrf=$csrf_token" -d 'password=smoke-test-password' "$closed/login")"
right_code="$(printf '%s' "$right_headers" | head -1 | tr -d '\r' | awk '{print $2}')"
[ "$right_code" = "302" ] || fail "the correct password did not redirect (got $right_code)"
printf '%s' "$right_headers" | tr -d '\r' | grep -qi '^set-cookie:' \
  || fail "the correct password did not set a session cookie"

authed_code="$(curl -s -o /dev/null -w '%{http_code}' -b "$cookiejar" \
  -H 'Accept: text/html' -H 'Sec-Fetch-Mode: navigate' "$closed/profile")"
assert_eq "$authed_code" "200" "the profile page must be reachable after a successful login"

echo "PASS: admin-password"
