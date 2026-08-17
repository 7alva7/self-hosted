#!/usr/bin/env bash
# Upload the fixture torrent, list it, download a file, verify bytes.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

json() { python3 -c "import json,sys;print($1)"; }

resource="$(api POST /rest-api/resource/ --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(printf '%s' "$resource" | json 'json.load(sys.stdin)["id"]')"
[ -n "$id" ] || fail "no resource id in response: $resource"

expected_ih="$(json 'json.load(open("'"$FIXTURE_DIR"'/summary.json"))["infohash"]' </dev/null)"
assert_eq "$id" "$expected_ih" "resource id must equal fixture infohash"

listing="$(api GET "/rest-api/resource/$id/list?path=/")"
count="$(printf '%s' "$listing" | json 'len(json.load(sys.stdin)["items"])')"
[ "$count" -ge 3 ] || fail "expected at least 3 items in root listing, got $count: $listing"

content_id="$(printf '%s' "$listing" | json '[i for i in json.load(sys.stdin)["items"] if i["name"]=="video.mp4"][0]["id"]')"
[ -n "$content_id" ] || fail "video.mp4 not found in listing: $listing"

export_json="$(api GET "/rest-api/resource/$id/export/$content_id")"
url="$(printf '%s' "$export_json" | json 'json.load(sys.stdin)["exports"]["download"]["url"]')"
[ -n "$url" ] || fail "no download url: $export_json"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
# The seeder pulls from the webseed on first request; allow for a cold start.
wait_for 180 "download url to serve bytes" curl -fsS -o "$out" "$url"

want="$(shasum -a 256 "$FIXTURE_DIR/content/webtor-smoke/video.mp4" | cut -d' ' -f1)"
got="$(shasum -a 256 "$out" | cut -d' ' -f1)"
assert_eq "$got" "$want" "downloaded video.mp4 checksum"

echo "PASS: ddl"
