#!/usr/bin/env bash
# Upload the fixture torrent, list it, download a file, verify bytes.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# jget <json-doc> <python-expr> <description>
# Evaluates the expression with `d` bound to the parsed document and a `walk(n)`
# generator that yields every entry under `n`, at any depth. A parse or lookup
# failure is reported with the offending response: `fail` runs in the command
# substitution's subshell, so its message reaches stderr and the resulting
# non-zero status trips `set -e` in the caller. (The previous
# `x="$(...)"; [ -n "$x" ] || fail ...` form could never run its guard --
# `set -e` aborted on the assignment first, leaving a bare Python traceback.)
jget() {
  local doc="$1" expr="$2" what="$3" val
  if ! val="$(printf '%s' "$doc" | python3 -c "
import json, sys

def walk(n):
    for it in (n.get('items') or []):
        yield it
        for sub in walk(it):
            yield sub

d = json.load(sys.stdin)
print($expr)
" 2>&1)"; then
    fail "$what: could not extract it -- $val
  from response: $doc"
  fi
  printf '%s' "$val"
}

resource="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(jget "$resource" 'd["id"]' 'resource id')"

expected_ih="$(jget "$(cat "$FIXTURE_DIR/summary.json")" 'd["infohash"]' 'fixture infohash')"
assert_eq "$id" "$expected_ih" "resource id must equal fixture infohash"

# `path=/` currently returns a flattened recursive listing, but `walk` also
# handles children nested under their directory entry, so this assertion pins
# the contract that matters -- every fixture file is reachable -- either way.
listing="$(apiv1 GET "/resource/$id/list?path=/")"
names="$(jget "$listing" \
  '"\n".join(sorted({i["name"] for i in walk(d) if i.get("type") == "file"}))' \
  'listed file names')"
for want in video.mp4 readme.txt subtitle.srt; do
  grep -qx -- "$want" <<<"$names" \
    || fail "fixture file '$want' missing from listing (found: $(printf '%s' "$names" | tr '\n' ' ')): $listing"
done

content_id="$(jget "$listing" \
  '[i["id"] for i in walk(d) if i.get("name") == "video.mp4"][0]' \
  'video.mp4 content id')"

export_json="$(apiv1 GET "/resource/$id/export/$content_id")"
url="$(jget "$export_json" 'd["exports"]["download"]["url"]' 'download url')"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
# The seeder pulls from the webseed on first request; allow for a cold start.
wait_for 180 "download url to serve bytes" curl -fsS -o "$out" "$url"

want="$(shasum -a 256 "$FIXTURE_DIR/content/webtor-smoke/video.mp4" | cut -d' ' -f1)"
got="$(shasum -a 256 "$out" | cut -d' ' -f1)"
assert_eq "$got" "$want" "downloaded video.mp4 checksum"

echo "PASS: ddl"
