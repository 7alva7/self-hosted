#!/usr/bin/env bash
# The video streams as HLS: manifest is served, segments download, and a
# downloaded segment is real decodable media -- not an error page or a
# truncated file. This exercises torrent-http-proxy routing to nginx-vod,
# which remuxes the already-H.264/AAC fixture straight into HLS segments
# without invoking content-transcoder (nginx-vod's vod module only re-packages
# a container that's already codec-compatible; no re-encode needed). The
# transcoder itself -- the ~hls export leg, which forces a real FFmpeg
# encode -- is covered separately by 31-transcode.sh.
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

# resolve_url <playlist-url> <entry> -- joins a playlist's own URL with an
# entry line from that playlist, per RFC 8216 URI reference resolution.
# An entry can be:
#   - an absolute URL (scheme://...): used as-is
#   - an absolute path (/...): joined against the playlist URL's origin
#   - a relative name (no leading slash): joined against the playlist URL's
#     directory
# Getting this wrong silently breaks HLS chains that use absolute paths or
# full URLs. nginx-vod, as observed here, only ever emits the relative form
# (e.g. "s-1-v1-a1.ts?api-key=...&token=..."); the other two branches are
# handled for correctness per RFC 8216 but are not exercised by this system.
resolve_url() {
  local playlist_url="$1" entry="$2"
  case "$entry" in
    *://*) printf '%s' "$entry" ;;
    /*)
      local origin="${playlist_url%%://*}://"
      local rest="${playlist_url#*://}"
      origin="$origin${rest%%/*}"
      printf '%s%s' "$origin" "$entry"
      ;;
    *)
      # Strip the playlist URL's own query string before chopping at the last
      # "/" -- otherwise a query value containing "/" (e.g. a token encoded
      # with plain base64 rather than base64url) would truncate the path
      # inside the query and produce a garbage, confusingly-404ing URL.
      local no_query="${playlist_url%%\?*}"
      printf '%s/%s' "${no_query%/*}" "$entry"
      ;;
  esac
}

resource="$(api POST /rest-api/resource/ --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(jget "$resource" 'd["id"]' 'resource id')"

listing="$(api GET "/rest-api/resource/$id/list?path=/")"
content_id="$(jget "$listing" \
  '[i["id"] for i in walk(d) if i.get("name") == "video.mp4"][0]' \
  'video.mp4 content id')"

export_json="$(api GET "/rest-api/resource/$id/export/$content_id")"
url="$(jget "$export_json" 'd["exports"]["stream"]["url"]' 'stream url')"
case "$url" in
  *index.m3u8*) : ;;
  *) fail "stream url is not an HLS manifest: $url" ;;
esac

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
# Transcoding starts cold: ffmpeg must spin up and produce the first segments.
wait_for 300 "HLS manifest" curl -fsS -o "$manifest" "$url"

head -1 "$manifest" | grep -q '#EXTM3U' || fail "not an m3u8: $(head -3 "$manifest")"

# The top-level manifest may be a master playlist; follow one level down if so.
segment_line="$(grep -v '^#' "$manifest" | head -1)"
[ -n "$segment_line" ] || fail "manifest has no entries: $(cat "$manifest")"

child="$(resolve_url "$url" "$segment_line")"
case "$segment_line" in
  *.m3u8*)
    media="$(mktemp)"
    wait_for 120 "media playlist" curl -fsS -o "$media" "$child"
    media_url="$child"
    segment_line="$(grep -v '^#' "$media" | head -1)"
    [ -n "$segment_line" ] || fail "media playlist has no segments: $(cat "$media")"
    child="$(resolve_url "$media_url" "$segment_line")"
    rm -f "$media"
    ;;
esac

seg="$(mktemp)"
wait_for 120 "first HLS segment" curl -fsS -o "$seg" "$child"
[ -s "$seg" ] || fail "first segment is empty: $child"
size="$(wc -c < "$seg")"
[ "$size" -gt 1000 ] || fail "first segment suspiciously small: $size bytes"

# A size check alone would pass for an HTML error page of similar size. Probe
# the segment with ffprobe to confirm it is real, decodable H.264 video with
# the fixture's known resolution -- proof that nginx-vod served a genuine
# media segment rather than an error page or truncated bytes. This does not
# prove content-transcoder ran (it doesn't, on this path); see
# 31-transcode.sh for that.
probe="$(docker run --rm -i -v "$seg:/seg.ts:ro" --entrypoint ffprobe \
  jrottenberg/ffmpeg:8-alpine \
  -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height \
  -of csv=p=0 /seg.ts 2>&1)" \
  || fail "ffprobe could not decode first segment (not real media): $probe"

case "$probe" in
  *h264*320*240*) : ;;
  *) fail "decoded segment does not match fixture (want h264 320x240): $probe" ;;
esac

rm -f "$seg"

echo "PASS: hls"
