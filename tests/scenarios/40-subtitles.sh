#!/usr/bin/env bash
# The .srt inside the torrent is served as real WebVTT through srt2vtt,
# exercising torrent-http-proxy's ~vtt matryoshka leg.
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

resource="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(jget "$resource" 'd["id"]' 'resource id')"

listing="$(apiv1 GET "/resource/$id/list?path=/")"
srt_id="$(jget "$listing" \
  '[i["id"] for i in walk(d) if i.get("name") == "subtitle.srt"][0]' \
  'subtitle.srt content id')"

# Probed directly against the live API (see task-7-report.md for the full
# transcript): the .srt item's export document has no "subtitles" key at all.
# The vtt URL is `exports.stream.url` on the .srt item itself, e.g.:
#   .../webtor-smoke/subs/subtitle.srt~vtt/subtitle.vtt?api-key=...&token=...
# The video item's export has no `tracks[]` either -- its `stream.html_tag`
# only carries the HLS `sources[]` entry. So this scenario reads the .srt
# item's own stream export, not the video item's.
export_json="$(apiv1 GET "/resource/$id/export/$srt_id")"
url="$(jget "$export_json" 'd["exports"]["stream"]["url"]' 'subtitle stream (vtt) url')"
case "$url" in
  *'~vtt/'*) : ;;
  *) fail "subtitle stream url does not route through the ~vtt chain: $url" ;;
esac

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
wait_for 120 "vtt conversion" curl -fsS -o "$out" "$url"

# A 200 with the wrong bytes (e.g. an unconverted .srt passed through, or an
# error page) would still pass a bare status check. Confirm the response is
# genuine WebVTT -- not SRT, not HTML -- and that the fixture's first cue text
# survived the conversion byte-for-byte.
head -1 "$out" | grep -q '^WEBVTT' || fail "not a WebVTT document: $(head -3 "$out")"
grep -q '^webtor smoke test$' "$out" || fail "cue text missing from vtt: $(cat "$out")"

# SRT uses comma decimal separators ("00:00:00,000"); VTT requires periods
# ("00:00:00.000"). A real conversion rewrites this; a passthrough would not.
grep -q '00:00:00\.000 --> 00:00:02\.000' "$out" \
  || fail "vtt timestamps do not use VTT's period separator (looks like unconverted SRT passthrough): $(cat "$out")"
grep -q '00:00:00,000' "$out" \
  && fail "vtt output still contains SRT-style comma timestamps: $(cat "$out")"

echo "PASS: subtitles"
