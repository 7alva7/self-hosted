#!/usr/bin/env bash
# Stremio addon (handlers/stremio, services/stremio): lets a user browse and
# play their Webtor library from inside the Stremio app.
#
# Two different trust levels on one route group ("/stremio", handler.go):
#   - GET /manifest.json is registered on the *bare* group, before
#     auth.HasAuth is ever added -- public, no credential, by design. This is
#     the URL Stremio itself fetches the moment a user pastes the addon URL
#     into "install addon", so it has to answer on a locked-down instance
#     before that user has proven anything. It is also declared exempt from
#     ONLY_AUTHORIZED outright ("/stremio" is in web-ui's
#     onlyAuthorizedExempt(), serve.go) -- unlike WebDAV (93-webdav.sh),
#     there is no accident-of-ordering story here: the exemption is explicit
#     and the route needs no session context at all to answer.
#   - GET /catalog/:type/*id, /stream/:type/*id, /meta/:type/*id sit behind
#     at.HasScope("stremio:read") (services/access_token), consuming the same
#     ?token=<uuid> mechanism as WebDAV, against an access_token row named
#     "stremio" instead of "webdav".
#
# There is no DISABLE_STREMIO flag anywhere in web-ui (grepped
# handlers/stremio, services/stremio, services/common for
# Disable*Stremio*/DISABLE_STREMIO*: nothing) -- unlike WebDAV
# (DisableWebDAVFlag/DISABLE_WEBDAV, handlers/webdav/handler.go), the addon
# is registered unconditionally. Nothing to gate on, so nothing below tests
# a disable path.
#
# Credential: POST /stremio/url/generate mints the "stremio" access_token
# (session + CSRF, same shape as WebDAV's own generate). The installable URL
# -- alias(/token/<uuid>/stremio/) + "manifest.json" -- is rendered inline
# into the plain GET /profile response (profile/stremio.html, same
# non-async-fragment pattern WebDAV uses; unlike S3's XHR-only fragment in
# 91-s3-webui.sh). Unlike WebDAV's alias (services/url_alias, proxy mode,
# rewritten in-process), the Stremio alias resolves in *redirect* mode (a
# plain 301 to /token/<uuid>/stremio/manifest.json) -- confirmed by reading
# handlers/profile/handler.go's getStremioAddonURL (ual.Get(..., false)) vs
# getWebDAVURL (ual.Get(..., true)), and empirically: curl -D- on the alias
# URL returns a Location header, not a proxied body. This scenario follows
# that redirect once to recover the token-bearing URL, then talks
# ?token=<uuid> directly for the scope-gated endpoints, mirroring what the
# real Stremio client does after installing (it resolves resource URLs
# relative to wherever the manifest it fetched actually lived).
#
# Re-runnable against a warm container: POST /stremio/url/generate is
# idempotent, same as WebDAV's; every request below is a read against an
# empty library. Nothing to clean up, no EXIT trap needed.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# --- helpers ---------------------------------------------------------------

raw() {
  # method, path, extra curl args... -- status + body, non-2xx not fatal.
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" -w 'HTTPSTATUS:%{http_code}' "$BASE_URL$path" "$@"
}
split_status() {
  STATUS="${1##*HTTPSTATUS:}"
  BODY="${1%HTTPSTATUS:*}"
}

# --- 1. The public manifest answers with no credential at all ------------
# This is the assertion that matters most for this endpoint: it must answer
# even on an instance with ONLY_AUTHORIZED=true and no session at all,
# because that is exactly the request Stremio itself makes when a user
# installs the addon.
resp="$(raw GET /stremio/manifest.json)"
split_status "$resp"
assert_eq "$STATUS" "200" "unauthenticated GET /stremio/manifest.json status"

python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d.get("id") == "org.stremio.webtor.io", "id=%r" % (d.get("id"),)
types = {c.get("type") for c in d.get("catalogs", [])}
assert types == {"movie", "series"}, "catalog types=%r, want {\"movie\", \"series\"}" % (types,)
' "$BODY" || fail "unauthenticated GET /stremio/manifest.json did not return the documented manifest shape: $BODY"

echo "PASS-detail: public GET /stremio/manifest.json answered 200 with id + both catalogs, no credential"

# --- 2. Mint the "stremio" access_token via the profile page -------------
jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

profile_body="$(curl --fail-with-body -sS -c "$jar" "$BASE_URL/profile")" \
  || fail "GET /profile failed"
csrf_token="$(printf '%s' "$profile_body" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
[ -n "$csrf_token" ] || fail "GET /profile did not render an _csrf token to submit"

stremio_field() {
  # Same JS-string-context scrape as 93-webdav.sh's webdav_field, against
  # profile/stremio.html's `var stremioAddonUrl = "...";`.
  printf '%s' "$1" | grep -o 'var stremioAddonUrl = "[^"]*"' | head -1 \
    | sed -E 's/.*"(.*)"/\1/; s/\\\//\//g'
}

addon_url="$(stremio_field "$profile_body" || true)"
if [ -z "$addon_url" ]; then
  curl --fail-with-body -sS -b "$jar" -c "$jar" \
    -X POST --data-urlencode "_csrf=$csrf_token" \
    "$BASE_URL/stremio/url/generate" >/dev/null \
    || fail "POST /stremio/url/generate was rejected"
  profile_body="$(curl --fail-with-body -sS -b "$jar" -c "$jar" "$BASE_URL/profile")" \
    || fail "GET /profile (after generate) failed"
  addon_url="$(stremio_field "$profile_body" || true)"
fi
[ -n "$addon_url" ] || fail "could not obtain a Stremio addon URL from /profile, generated or pre-existing"

case "$addon_url" in
  http*://*/s/*/manifest.json) : ;;
  *) fail "Stremio addon URL does not look like the documented /s/<code>/manifest.json alias: $addon_url" ;;
esac

# Follow the alias's one redirect hop (not -L: the point is to read the
# Location header, which carries the /token/<uuid>/stremio/manifest.json
# path this scenario needs, not just to land on the final body).
location="$(curl -sS -o /dev/null -D - "$addon_url" | tr -d '\r' | grep -i '^location:' | sed -E 's/^[Ll]ocation: *//')"
case "$location" in
  /token/*/stremio/manifest.json) : ;;
  *) fail "GET $addon_url did not redirect to a /token/<uuid>/stremio/manifest.json path: got Location '$location'" ;;
esac
# Everything up to and including the trailing slash before manifest.json --
# the base every scope-gated resource URL below is built from, same as a
# real Stremio client resolving catalog/stream/meta relative to the manifest
# URL it fetched.
token_base="${location%manifest.json}"

resolved_manifest="$(curl --fail-with-body -sS "$BASE_URL$location")" \
  || fail "GET $location (resolved manifest, token-bearing path) was rejected"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d.get("id") == "org.stremio.webtor.io", "id=%r" % (d.get("id"),)
' "$resolved_manifest" || fail "resolved token-bearing manifest URL did not return the documented manifest shape: $resolved_manifest"

# --- 3. Credentialed catalog/stream succeed with the real (empty) shape --
# An empty library is not an error: catalog answers {"metas": ...} and
# stream {"streams": ...}, both empty, not a 4xx. "Webtor.io" is the one
# catalog id the manifest advertises for both types (services/stremio/
# manifest.go's catalogID constant) -- not a fixture-derived value, so no
# torrent needs to exist in the library for this to mean anything.
catalog_body="$(curl --fail-with-body -sS "$BASE_URL${token_base}catalog/movie/Webtor.io.json")" \
  || fail "credentialed GET .../catalog/movie/Webtor.io.json was rejected"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert "metas" in d, "response has no \"metas\" key: %r" % (d,)
# An empty library serializes as either null or [] depending on whether Go
# ever allocated the backing slice -- both mean "no results", neither is an
# error, so both are accepted here.
assert not d["metas"], "metas=%r, want empty (null or []) for a fresh library" % (d["metas"],)
' "$catalog_body" || fail "credentialed catalog response was not the documented (empty) CatalogResponse shape: $catalog_body"

stream_body="$(curl --fail-with-body -sS "$BASE_URL${token_base}stream/movie/tt0000000.json")" \
  || fail "credentialed GET .../stream/movie/tt0000000.json was rejected"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d.get("streams") == [], "streams=%r, want [] for a fresh library" % (d.get("streams"),)
' "$stream_body" || fail "credentialed stream response was not the documented (empty) StreamsResponse shape: $stream_body"

echo "PASS-detail: credentialed catalog + stream both answered 200 with the documented empty-library shape"

# --- 4. Uncredentialed requests to the scope-gated routes are rejected ---
# Same two-tier negative control as 93-webdav.sh: no token param at all hits
# access_token.HasScope's own presence check first (400, before the token is
# even looked up); a well-formed but never-issued UUID clears that and is
# rejected by getToken() instead (401). Both bare status, no JSON envelope --
# access_token's middleware runs ahead of anything that would build one.
resp="$(raw GET /stremio/catalog/movie/Webtor.io.json)"
split_status "$resp"
assert_eq "$STATUS" "400" "uncredentialed GET /stremio/catalog status (no ?token= at all)"
[ -z "$BODY" ] || fail "uncredentialed catalog request (no token) returned a body, expected bare status: $BODY"

resp="$(raw GET /stremio/catalog/movie/Webtor.io.json?token=00000000-0000-0000-0000-000000000000)"
split_status "$resp"
assert_eq "$STATUS" "401" "uncredentialed GET /stremio/catalog status (well-formed, unissued token)"
[ -z "$BODY" ] || fail "uncredentialed catalog request (unissued token) returned a body, expected bare status: $BODY"

echo "PASS-detail: uncredentialed catalog request rejected with bare 400 (no token) and bare 401 (unissued token)"

echo "PASS: stremio"
