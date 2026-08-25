#!/usr/bin/env bash
# The ~hls export leg forces a real FFmpeg transcode: torrent-http-proxy routes
# to content-transcoder (not nginx-vod's passthrough remux), content-transcoder
# actually runs, and the resulting manifest/segment are genuine decodable
# media. This is the sibling to 30-hls.sh, which only proves the nginx-vod
# passthrough path (no re-encode) -- see that file's header for why the two
# are not redundant.
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

# resolve_url <playlist-url> <entry> -- see 30-hls.sh for the full rationale;
# duplicated here rather than shared so each scenario file stays self-contained,
# matching this suite's existing convention (10-ddl.sh / 20-archive.sh both
# duplicate jget rather than sourcing a shared copy).
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
      local no_query="${playlist_url%%\?*}"
      printf '%s/%s' "${no_query%/*}" "$entry"
      ;;
  esac
}

resource="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(jget "$resource" 'd["id"]' 'resource id')"

listing="$(apiv1 GET "/resource/$id/list?path=/")"
content_id="$(jget "$listing" \
  '[i["id"] for i in walk(d) if i.get("name") == "video.mp4"][0]' \
  'video.mp4 content id')"

export_json="$(apiv1 GET "/resource/$id/export/$content_id")"
vod_url="$(jget "$export_json" 'd["exports"]["stream"]["url"]' 'stream url')"

# The export contract only publishes the nginx-vod (~vod) chain; the
# content-transcoder (~hls) leg is reached by substituting the matryoshka
# segment while keeping the same signed api-key/token query string, which is
# not path-bound. See task-6-report.md "Fix round 1" for how this was found.
case "$vod_url" in
  *'~vod/'*) : ;;
  *) fail "stream url does not use ~vod chaining, cannot derive a ~hls url: $vod_url" ;;
esac
case "$vod_url" in
  *'?'*) : ;;
  *) fail "stream url has no query string to preserve: $vod_url" ;;
esac
prefix="${vod_url%%~vod/*}"
query="${vod_url#*\?}"
base="${prefix}~hls"

# content-transcoder is session-based since upstream commit 76cc495
# ("replace legacy transcoding with session-based architecture", 2026-03-15):
# the old `~hls/index.m3u8` entry point is gone and now 404s. A client first
# POSTs `~hls/session` to get {id, duration}, then reads the master playlist at
# `~hls/session/<id>/index.m3u8`. This mirrors exactly what web-ui does today
# (web-ui `jobs/scripts/hls.go` -> `api.CreateTranscoderSession` ->
# `sessionHLSURL`), so the scenario exercises the real production client flow.
#
# Cold start: creating the session probes the media and spins up FFmpeg, so
# give it the same budget the manifest fetch used to get.
session_json="$(mktemp)"
trap 'rm -f "$session_json"' EXIT
wait_for 300 "content-transcoder session creation" \
  curl -fsS -X POST -o "$session_json" "${base}/session?${query}"

session_id="$(jget "$(cat "$session_json")" 'd["id"]' 'transcoder session id')"
[ -n "$session_id" ] || fail "transcoder session id is empty: $(cat "$session_json")"
# The session document also carries the probed duration. A stub/error response
# could still parse as JSON with an id; requiring a positive duration proves
# content-transcoder actually probed the fixture media (10s) rather than
# handing back an empty shell.
duration="$(jget "$(cat "$session_json")" 'd["duration"]' 'transcoder session duration')"
python3 -c "import sys; sys.exit(0 if float('$duration') > 0 else 1)" \
  || fail "transcoder session reports non-positive duration ($duration), media was not probed: $(cat "$session_json")"

url="${base}/session/${session_id}/index.m3u8?${query}"

manifest="$(mktemp)"
trap 'rm -f "$manifest" "$session_json"' EXIT
wait_for 300 "content-transcoder HLS manifest" curl -fsS -o "$manifest" "$url"

head -1 "$manifest" | grep -q '#EXTM3U' || fail "not an m3u8: $(head -3 "$manifest")"

# content-transcoder emits a genuine master playlist (#EXT-X-STREAM-INF); the
# top-level entry is always a media-playlist reference here, unlike the
# nginx-vod path in 30-hls.sh where it's the segment directly.
segment_line="$(grep -m1 -v '^#' "$manifest")"
[ -n "$segment_line" ] || fail "manifest has no entries: $(cat "$manifest")"

child="$(resolve_url "$url" "$segment_line")"
case "$segment_line" in
  *.m3u8*)
    media="$(mktemp)"
    wait_for 120 "media playlist" curl -fsS -o "$media" "$child"
    media_url="$child"
    segment_line="$(grep -m1 -v '^#' "$media")"
    [ -n "$segment_line" ] || fail "media playlist has no segments: $(cat "$media")"
    child="$(resolve_url "$media_url" "$segment_line")"
    rm -f "$media"
    ;;
  *)
    fail "expected a master playlist pointing at a media playlist, got a segment directly: $segment_line"
    ;;
esac

seg="$(mktemp)"
wait_for 120 "first transcoded HLS segment" curl -fsS -o "$seg" "$child"
[ -s "$seg" ] || fail "first segment is empty: $child"
size="$(wc -c < "$seg")"
[ "$size" -gt 1000 ] || fail "first segment suspiciously small: $size bytes"

# The whole point of this scenario: assert content-transcoder actually
# participated, not merely that some URL returned 200 bytes. A passing
# manifest/segment fetch alone would not distinguish "content-transcoder ran"
# from "torrent-http-proxy silently fell back to nginx-vod" -- only the access
# log and the transcoder's own log prove which service actually served this.
compose=(docker compose -f "$TESTS_DIR/docker-compose.yml" -p webtor-smoke)
logs="$("${compose[@]}" logs webtor 2>&1)"
# NB: these use here-strings, not `printf ... | grep -q`. Under `set -o
# pipefail` (from lib.sh) that pipeline is a coin flip: `grep -q` exits the
# moment it matches, printf then takes SIGPIPE on its remaining write, and the
# *pipeline* reports failure even though the assertion held. It only bites once
# the log is big enough for printf not to finish in one write -- which the
# session flow's extra requests made routine. A here-string has no pipe.
grep -q 'edge=content-transcoder' <<<"$logs" \
  || fail "torrent-http-proxy access log never shows edge=content-transcoder -- the ~hls request did not route through the transcoder: $(tail -40 <<<"$logs")"
# The session-based transcoder no longer logs "transcoding finished"; the
# equivalent proof that a real FFmpeg run happened for *this* session is the
# session-creation line plus a normally-terminating ffmpeg run. Requiring both
# is strictly stronger than the single old grep: the first pins the session to
# the id this scenario created, the second pins an actual encode completing.
grep -q "sessionManager: created session.*sessionID=$session_id" <<<"$logs" \
  || fail "content-transcoder log never reports creating session $session_id: $(grep -i content-transcoder <<<"$logs" | tail -40)"

# The completed-encode line is asynchronous, so it needs a bounded retry rather
# than a one-shot grep on the snapshot above. content-transcoder logs it from a
# goroutine after `cmd.Wait()` returns (services/transcode_run.go:162-172):
#
#     waitErr := r.cmd.Wait()
#     if waitErr != nil { ...Debug("run: ffmpeg exited with error") }
#     else             { ...Info("run: ffmpeg finished normally") }
#
# Fetching segment 0 only proves ffmpeg has produced its *first* segment; the
# process may still be encoding the rest, so a bare grep here races the encoder
# and goes red for no reason. That matters more than usual: this suite is about
# to gate automated Renovate bump PRs, where an intermittent red erodes trust in
# the gate far faster than it catches anything.
transcode_run_completed() {
  local l
  l="$("${compose[@]}" logs webtor 2>&1)"
  if grep -q 'run: ffmpeg finished normally' <<<"$l"; then
    return 0
  fi
  # Printed only on the final attempt (wait_for discards output until it gives
  # up), so the timeout message carries the transcoder's own last words.
  grep -i content-transcoder <<<"$l" | tail -20 || true
  return 1
}
wait_for 120 "content-transcoder to report a completed ffmpeg run" transcode_run_completed

# A size check alone would pass for an HTML error page of similar size. Probe
# the segment with ffprobe to confirm it is real, decodable H.264 video with
# the fixture's known resolution -- proof that content-transcoder produced
# genuine media, not just that some route returned bytes.
probe="$(docker run --rm -i -v "$seg:/seg.ts:ro" --entrypoint ffprobe \
  jrottenberg/ffmpeg:8-alpine \
  -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height \
  -of csv=p=0 /seg.ts 2>&1)" \
  || fail "ffprobe could not decode first segment (not real media): $probe"

case "$probe" in
  *h264*240*) : ;;
  *) fail "decoded segment does not look like the expected transcoded rendition (want h264, height 240): $probe" ;;
esac

rm -f "$seg"

echo "PASS: transcode"
