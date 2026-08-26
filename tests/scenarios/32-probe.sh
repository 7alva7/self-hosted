#!/usr/bin/env bash
# The ~cp leg: torrent-http-proxy routes to content-prober, which runs ffprobe
# against the seeded file and answers its JSON.
#
# This is the step web-ui takes before deciding whether a browser can play a
# file directly or it has to be transcoded (jobs/scripts/action.go, "probing
# content media info"). When the container needs transcoding -- mkv, mostly --
# a failure there is fatal, so playback stops on that line with "Something
# went wrong".
#
# The service was missing from this image entirely, and nothing here noticed:
# 31-transcode.sh exercises content-transcoder's OWN probe, which it does over
# gRPC with its own client, so it stayed green while the HTTP chain web-ui uses
# had no endpoint at all. Hence this scenario, separate from that one.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

resource="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$resource")"

listing="$(apiv1 GET "/resource/$id/list?path=/")"
content_id="$(python3 -c '
import json, sys
def walk(n):
    if isinstance(n, dict):
        if "id" in n and "name" in n: yield n
        for v in n.values(): yield from walk(v)
    elif isinstance(n, list):
        for v in n: yield from walk(v)
d = json.loads(sys.argv[1])
print([i["id"] for i in walk(d) if i.get("name") == "video.mp4"][0])
' "$listing")"

export_json="$(apiv1 GET "/resource/$id/export/$content_id")"
vod_url="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["exports"]["stream"]["url"])' "$export_json")"

# Same substitution 31-transcode.sh documents: the export contract publishes
# only the ~vod chain, and the other matryoshka legs are reached by swapping
# that segment while keeping the signed query string, which is not path-bound.
case "$vod_url" in
  *\?*) : ;;
  *) fail "stream url has no query string to preserve: $vod_url" ;;
esac
probe_url="${vod_url%%~vod/*}~cp?${vod_url#*\?}"

probe_json="$(mktemp)"
trap 'rm -f "$probe_json"' EXIT
# Cold start: the prober fetches enough of the file through the seeder to run
# ffprobe over it, so give it room.
wait_for 120 "content-prober answering the ~cp chain" \
  curl -fsS -o "$probe_json" "$probe_url"

# ffprobe's own shape, not merely "some JSON came back": the fixture is one
# h264 video stream plus one audio stream (tests/fixtures/build.sh), so a
# reply that cannot name the codec is not a probe of this file.
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert "streams" in d and "format" in d, "not an ffprobe document: keys=%r" % sorted(d)
codecs = sorted(s.get("codec_name") for s in d["streams"])
assert "h264" in codecs, "no h264 stream in the probe: %r" % (codecs,)
assert len(d["streams"]) == 2, "expected the fixture'"'"'s two streams, got %d" % len(d["streams"])
' "$probe_json" || fail "content-prober did not return ffprobe data for the fixture: $(head -c 300 "$probe_json")"

echo "PASS: probe"
