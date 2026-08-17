#!/usr/bin/env bash
# A directory inside the torrent downloads as a zip with the right contents,
# exercising torrent-archiver.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# jget <json-doc> <python-expr> <description>
# Evaluates the expression with `d` bound to the parsed document and a `walk(n)`
# generator that yields every entry under `n`, at any depth. See 10-ddl.sh for
# the rationale: this mirrors that scenario's helper so both stay consistent.
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

resource="$(api POST /rest-api/resource/ --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(jget "$resource" 'd["id"]' 'resource id')"

listing="$(api GET "/rest-api/resource/$id/list?path=/")"
dir_id="$(jget "$listing" \
  '[i["id"] for i in walk(d) if i.get("name") == "subs" and i.get("type") == "directory"][0]' \
  'subs directory id')"

export_json="$(api GET "/rest-api/resource/$id/export/$dir_id")"
url="$(jget "$export_json" 'd["exports"]["download"]["url"]' 'archive download url')"
case "$url" in
  *arch*) : ;;
  *) fail "directory download url does not route through torrent-archiver: $url" ;;
esac

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# Cold archive builds under amd64 emulation can be slow; allow for that.
wait_for 180 "archive url to serve bytes" curl -fsS -o "$out/subs.zip" "$url"

python3 - "$out/subs.zip" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    bad = z.testzip()
    if bad is not None:
        raise SystemExit("corrupt entry in zip: %s" % bad)
    names = z.namelist()
    if not any(n.endswith("subtitle.srt") for n in names):
        raise SystemExit("subtitle.srt missing from archive: %s" % names)
print("zip ok")
EOF

echo "PASS: archive"
