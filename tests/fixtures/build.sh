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

docker run --rm -v "$content:/out" jrottenberg/ffmpeg:8-alpine \
  -nostdin -y \
  -f lavfi -i "testsrc=size=320x240:rate=15:duration=10" \
  -f lavfi -i "sine=frequency=440:duration=10" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a aac -shortest \
  /out/webtor-smoke/video.mp4

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
