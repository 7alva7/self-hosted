#!/usr/bin/env bash
# web-ui's own /s3 endpoint: an S3-protocol gateway over the *user's torrent
# library*, reached through nginx on the normal web port (BASE_URL). Buckets
# are torrents (writable -- PUT a .torrent to add it to the library, DELETE
# to remove it), and all/movies/series (read-only, library-backed).
#
# Not to be confused with 70-s3.sh, which covers the *embedded object store*
# (versitygw over /storage): a different service, reached only from inside
# the container on 127.0.0.1:8099, with different buckets
# (vault/posters/subtitles/thumbnails) and a different purpose (internal
# plumbing for vault/posters/subtitles, not user-facing). Same three
# letters, unrelated surfaces -- see 70-s3.sh's own header for the
# mirror-image note.
#
# Re-runnable against a warm container: this scenario PUTs one object into
# the torrents bucket and always DELETEs it again via an EXIT trap (DELETE
# on this bucket removes the underlying library row outright -- see
# services/libfs/torrent_lib.go removeFromLibrary -- not just an S3-layer
# tombstone), so a second run finds no leftover row to collide with. The
# object key embeds $$ and the current time, so concurrent/successive runs
# never reuse a key even if cleanup somehow didn't run.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# --- Credentials: the profile-page flow, same as a real user configuring rclone ---
#
# There is no JSON endpoint for reading back issued S3 credentials (unlike
# /api-credentials/key for the API key) -- the profile page is the only place
# they are exposed, so scraping it is the intended path, not a workaround.
# It is also the more faithful test: it is literally what a user does.
#
# The secret is deliberately *read*, not derived locally with
# s3.DeriveSecretKey: reading proves the value the profile page shows a real
# user is the value that actually authenticates, instead of just proving the
# derivation formula matches itself.
#
# The S3 card is NOT part of the HTML that GET /profile returns. Like several
# profile sections it is a progressive-enhancement fragment
# (templates/partials/profile/s3.html, wrapped in a div carrying
# data-async-layout="{{ template \"profile/s3\" $ }}") -- the initial response
# ships that Go-template string verbatim, unrendered, and the browser's own JS
# (assets/src/js/lib/async.js: asyncLayout/bindAsync) re-requests the SAME URL
# with X-Requested-With: XMLHttpRequest and X-Layout: <that string>, and the
# server renders just that partial in response (services/template/template.go,
# ~line 480: "if X-Requested-With == XMLHttpRequest && X-Layout != '' ->
# WithLayoutBody(X-Layout)"). A plain GET /profile never contains
# accessKey/secretKey at all, generated or not; fetching the fragment is not
# optional here.
#
# Inside that fragment, the triple lives in a small inline script:
#   var s3Values = { endpoint: "...", accessKey: "...", secretKey: "...", region: "..." };
# rather than only in the visible <input> tags. The script block is scraped
# instead of the inputs because two of the three inputs carry no id/name to
# key off (only aria-label, which is locale text) -- the script's key names
# are stable across languages. Go's html/template renders these in JS-string
# context, which always quotes, so a plain "field: "value"" grep is safe.
s3_jar="$(mktemp)"
s3_layout='{{ template "profile/s3" $ }}'

fetch_s3_fragment() {
  curl --fail-with-body -sS -b "$s3_jar" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "X-Layout: $s3_layout" \
    "$BASE_URL/profile"
}

s3_field() {
  # s3_field <body> <field> -- pulls one value out of the inline s3Values
  # script block.
  local body="$1" field="$2"
  printf '%s' "$body" | grep -o "${field}:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/'
}

# A plain (non-XHR) GET still establishes the session and carries the _csrf
# token every form on the page shares, S3's generate form included.
profile_body="$(curl --fail-with-body -sS -c "$s3_jar" "$BASE_URL/profile")" \
  || fail "GET /profile failed"
csrf_token="$(printf '%s' "$profile_body" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
[ -n "$csrf_token" ] || fail "GET /profile did not render an _csrf token to submit"

s3_fragment="$(fetch_s3_fragment)" || fail "fetching the profile/s3 fragment failed"
# `|| true` is load-bearing on every s3_field call in this credentials
# section, not decoration: grep -o prints nothing AND exits 1 when there is
# no match, which is the *expected*, common case right here (no S3
# credentials issued yet, so the fragment has no s3Values block at all).
# lib.sh has `set -euo pipefail`, and a bare `var="$(pipeline)"` assignment
# aborts the whole script the instant that pipeline's exit status is
# non-zero -- silently, before the `if [ -z "$access_key" ]` below ever gets
# a chance to react to the empty value. Without `|| true` this scenario
# would work every time it happens to run against a container that already
# has credentials (e.g. re-run by hand) and die with no output at all the
# one time it matters: a genuinely fresh container, which is what the real
# suite runs against every time (found by reproducing the fresh-container
# failure that api-only manual reruns never hit).
access_key="$(s3_field "$s3_fragment" accessKey || true)"
if [ -z "$access_key" ]; then
  curl --fail-with-body -sS -b "$s3_jar" -c "$s3_jar" \
    -X POST --data-urlencode "_csrf=$csrf_token" \
    "$BASE_URL/s3-credentials/generate" >/dev/null \
    || fail "POST /s3-credentials/generate was rejected"
  s3_fragment="$(fetch_s3_fragment)" || fail "fetching the profile/s3 fragment (after generate) failed"
  access_key="$(s3_field "$s3_fragment" accessKey || true)"
fi
secret_key="$(s3_field "$s3_fragment" secretKey || true)"

[ -n "$access_key" ] && [ -n "$secret_key" ] && [ "$access_key" != "$secret_key" ] \
  || fail "S3 credentials scraped from the profile/s3 fragment look empty or malformed (access='$access_key' secret len=${#secret_key})"

# --- helpers -----------------------------------------------------------

# s3_raw <method> <path> [extra curl args...] -- unsigned/arbitrary request,
# status and body both captured, never treats non-2xx as a curl failure.
s3_raw() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" -w 'HTTPSTATUS:%{http_code}' "$BASE_URL$path" "$@"
}
split_status() {
  STATUS="${1##*HTTPSTATUS:}"
  BODY="${1%HTTPSTATUS:*}"
}

# xml_field <body> <tag> -- pulls <Tag>...</Tag> out of an S3 XML document.
# Failing to parse IS the assertion that the body is well-formed S3 XML, not
# an incidental crash: a non-XML body (e.g. an HTML error page) must fail
# here rather than fall through to a string compare that silently passes on
# garbage.
#
# xml.etree (not defusedxml) is fine here: the body is generated exclusively
# by web-ui's own encoding/xml marshaller (services/s3/xml.go, errors.go)
# against our own just-issued request, never third-party or user-supplied
# XML -- there is no DOCTYPE/entity payload for XXE to ride in on.
xml_field() {
  local body="$1" tag="$2" out
  out="$(printf '%s' "$body" | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
el = root.find('$tag')
if el is None or el.text is None:
    sys.exit(1)
print(el.text)
" 2>&1)" || fail "response body is not XML with a <$tag> element: $out
  body was: $body"
  printf '%s' "$out"
}

# s3_curl [extra curl args...] -- SigV4-signs with the scraped credentials.
# Run directly against BASE_URL from the host: unlike 70-s3.sh's embedded-S3
# endpoint (127.0.0.1:8099, container-internal only, reached via
# `webtor_exec sh -c '...'`), this endpoint is nginx-proxied to the host, so
# there is no inner shell to pass credentials through -- and therefore none
# of 70-s3.sh's positional-argument trick is needed here: these are ordinary
# host-side curl arguments, not a string re-interpreted by a second shell.
s3_curl() {
  curl --fail-with-body -sS \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "$access_key:$secret_key" \
    "$@"
}

# s3_put <path> <data-arg...> -- PUT through s3_curl with an explicit
# Content-Type. Load-bearing, not decoration: curl defaults an untyped
# --data-binary body to application/x-www-form-urlencoded, and web-ui's
# global CSRF middleware parses any form-encoded body looking for its token
# -- even on this CSRF-*exempt* path, because the exemption (checked by
# prefix on services/session) only skips *validating* the token, not the
# body-parsing that goes looking for one. That parse drains
# http.Request.Body, so by the time the S3 handler tries to read it for
# real, io.ReadAll sees an immediate EOF and every PUT fails with a 500
# InternalError, never reaching Create at all. Same root cause, same fix, as
# apiv1's Content-Type in lib.sh -- discovered here by watching web-ui's own
# logs (`create error=EOF`) once the plain-403 read-only-bucket PUT above
# (which never reaches Create) turned out to still succeed as designed.
s3_put() {
  local path="$1"
  shift
  s3_curl -H "Content-Type: application/x-bittorrent" -X PUT "$@" "$BASE_URL$path"
}

# --- 1. Unsigned request is rejected, with the documented error code -----
resp="$(s3_raw GET /s3)"
split_status "$resp"
assert_eq "$STATUS" "403" "unsigned GET /s3 status"
code="$(xml_field "$BODY" Code)"
assert_eq "$code" "AccessDenied" "unsigned GET /s3 error code"

# --- 2. A WebDAV method gets the protocol-mismatch status, not a bare 403 -
#
# Deliberately "/s3/", not "/s3": the global CSRF middleware's exemption for
# this endpoint is registered on the "/s3/" prefix (serve.go, sess.RegisterHandler),
# which does not match the bare mount path. PROPFIND against plain "/s3" hits
# that middleware first and gets a generic 400 "CSRF token mismatch" --
# a real answer, just not the one this assertion is about; every real S3
# client path (and PROPFIND's own real target, "/s3/torrents/...") carries a
# trailing segment and never observes this.
resp="$(s3_raw PROPFIND /s3/)"
split_status "$resp"
assert_eq "$STATUS" "405" "PROPFIND /s3/ status"
code="$(xml_field "$BODY" Code)"
assert_eq "$code" "MethodNotAllowed" "PROPFIND /s3/ error code"
message="$(xml_field "$BODY" Message)"
case "$message" in
  *WebDAV*) : ;;
  *) fail "PROPFIND /s3/ error message does not point at the WebDAV URL: $message" ;;
esac

# --- 3. A correctly signed request succeeds and lists the expected buckets
buckets_body="$(s3_curl "$BASE_URL/s3")" || fail "signed GET /s3 was rejected"
for b in torrents all movies series; do
  printf '%s' "$buckets_body" | grep -q "<Name>$b</Name>" \
    || fail "signed GET /s3 bucket listing is missing bucket '$b': $buckets_body"
done

# --- 4. Read-only buckets reject writes with the same AccessDenied code --
# (all/movies/series are library views with no Create of their own --
# services/libfs.BaseDirectory.Create always answers 403 "operation not
# permitted", which the protocol layer maps to AccessDenied. It answers that
# before ever reading the body, so this one doesn't strictly need s3_put's
# Content-Type fix the way #5's real upload does -- used anyway so this
# doesn't quietly start depending on that ordering.)
resp="$(curl -sS -w 'HTTPSTATUS:%{http_code}' \
  --aws-sigv4 "aws:amz:us-east-1:s3" --user "$access_key:$secret_key" \
  -H "Content-Type: application/x-bittorrent" \
  -X PUT --data-binary 'nope' "$BASE_URL/s3/movies/should-not-be-created.torrent")"
split_status "$resp"
assert_eq "$STATUS" "403" "PUT into read-only bucket 'movies' status"
code="$(xml_field "$BODY" Code)"
assert_eq "$code" "AccessDenied" "PUT into read-only bucket 'movies' error code"

# --- 5. The writable bucket actually round-trips a real upload -----------
# torrents/<name>.torrent is not a plain object store: Create() parses the
# body as a torrent and adds it to the library (services/libfs/torrent_lib.go),
# so the payload has to be an actual .torrent file, not arbitrary bytes.
obj_key="s3-webui-smoke-$$-$(date +%s).torrent"
obj_path="/s3/torrents/$obj_key"

cleanup() {
  s3_curl -X DELETE "$BASE_URL$obj_path" >/dev/null 2>&1 || true
  rm -f "$s3_jar" "${got_file:-}"
}
trap cleanup EXIT

put_object() {
  s3_put "$obj_path" --data-binary "@$FIXTURE_DIR/smoke.torrent"
}
wait_for 30 "PUT $obj_key through web-ui's S3 endpoint" put_object

# Verified with a direct object GET, not a bucket listing: listing goes
# through a recursive-walk cache with a real 1-minute TTL of its own
# (services/s3/s3.go, h.walks -- "short-lived" but not zero, and nothing
# invalidates it on Create/RemoveAll). A direct GET/HEAD on one key isn't
# part of that cache -- it calls FileSystem.Stat/Open straight through -- so
# it reflects the PUT and, below, the DELETE immediately. Confirmed the hard
# way: an earlier version of this scenario checked the listing right after
# DELETE and failed on a still-cached pre-delete snapshot.
#
# Compared as files, not bash strings: a .torrent's "pieces" field is raw
# 20-byte SHA1 hashes, which routinely contain NUL bytes that command
# substitution silently truncates -- exactly why 70-s3.sh's own round-trip
# check base64-encodes its random payload first. cmp is binary-safe.
got_file="$(mktemp)"
s3_curl -o "$got_file" "$BASE_URL$obj_path" || fail "GET $obj_path (after PUT) was rejected"
cmp -s "$got_file" "$FIXTURE_DIR/smoke.torrent" \
  || fail "object fetched back through the S3 endpoint differs from what was uploaded"
rm -f "$got_file"

s3_curl -X DELETE "$BASE_URL$obj_path" >/dev/null \
  || fail "DELETE $obj_path through the S3 endpoint failed"

# Signed (not s3_raw, which is deliberately unsigned for assertion #1) --
# an unsigned request would 403 AccessDenied regardless of whether the
# object exists, telling us nothing about the DELETE.
resp="$(curl -sS -w 'HTTPSTATUS:%{http_code}' \
  --aws-sigv4 "aws:amz:us-east-1:s3" --user "$access_key:$secret_key" \
  "$BASE_URL$obj_path")"
split_status "$resp"
assert_eq "$STATUS" "404" "GET $obj_path (after DELETE) status"
code="$(xml_field "$BODY" Code)"
assert_eq "$code" "NoSuchKey" "GET $obj_path (after DELETE) error code"

echo "PASS: s3-webui"
