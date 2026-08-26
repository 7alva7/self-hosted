#!/usr/bin/env bash
# Build the smoke-test fixture: synthetic media + a webseeded .torrent.
# No network content is downloaded; ffmpeg runs from a container so the host
# needs nothing but docker and python3.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
content="$here/content"
root="$content/webtor-smoke"

rm -rf "$content"
mkdir -p "$root/subs"

# Mount the stable parent dir, not "$content": "$content" was just replaced by
# rm -rf/mkdir, and Docker Desktop resolves a bind-mount source at mount time,
# so a freshly recreated mount root can appear empty inside the container.
# Pinned by digest, like every other image this repo depends on. The tag
# alone is not enough here: 92-cli.sh asserts the fixture's exact infohash,
# size and file count, and those are a function of the bytes ffmpeg emits.
# An upstream rebuild of :8-alpine changes them -- it already did once, by a
# single byte, and the suite went red on a scenario that had nothing to do
# with the change under test.
docker run --rm -v "$here:/out" jrottenberg/ffmpeg:8-alpine@sha256:1278f385658510b4f8370ed4de93b279452071b56fa9db4873e6433549b35c39 \
  -nostdin -y \
  -f lavfi -i "testsrc=size=320x240:rate=15:duration=10" \
  -f lavfi -i "sine=frequency=440:duration=10" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a aac -shortest \
  /out/content/webtor-smoke/video.mp4

printf 'webtor self-hosted smoke fixture\n' > "$root/readme.txt"

cat > "$root/subs/subtitle.srt" <<'EOF'
1
00:00:00,000 --> 00:00:02,000
webtor smoke test

2
00:00:02,000 --> 00:00:04,000
second cue
EOF

python3 "$here/make_fixture.py" "$root" "http://webseed/" "$here/smoke.torrent" \
  | tee "$here/summary.json"
echo
echo "fixture built: $here/smoke.torrent"
