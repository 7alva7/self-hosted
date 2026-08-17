#!/usr/bin/env bash
# Unit test for make_fixture.py: runs it on a synthetic tree and checks the summary.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/webtor-smoke/subs"
# 100000 bytes => with piece length 32768 that is 4 pieces (3 full + remainder)
head -c 100000 /dev/zero | tr '\0' 'a' > "$tmp/webtor-smoke/video.mp4"
printf 'hello\n' > "$tmp/webtor-smoke/readme.txt"
printf '1\n00:00:00,000 --> 00:00:01,000\nhi\n' > "$tmp/webtor-smoke/subs/subtitle.srt"

summary="$(python3 "$here/make_fixture.py" "$tmp/webtor-smoke" "http://webseed/" "$tmp/out.torrent")"
echo "$summary"

get() { printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

[ -s "$tmp/out.torrent" ] || { echo "FAIL: torrent not written"; exit 1; }
[ "$(get "['name']")" = "webtor-smoke" ] || { echo "FAIL: wrong name"; exit 1; }
[ "$(get "['piece_length']")" = "32768" ] || { echo "FAIL: wrong piece length"; exit 1; }
[ "$(printf '%s' "$summary" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['files']))")" = "3" ] \
  || { echo "FAIL: expected 3 files"; exit 1; }
total="$(get "['total_length']")"
[ "$total" = "100041" ] || { echo "FAIL: total_length=$total, expected 100041"; exit 1; }
# ceil(100041 / 32768) == 4
[ "$(get "['pieces_count']")" = "4" ] || { echo "FAIL: wrong pieces_count"; exit 1; }
ih="$(get "['infohash']")"
printf '%s' "$ih" | grep -Eq '^[0-9a-f]{40}$' || { echo "FAIL: bad infohash $ih"; exit 1; }
# BEP19 webseed must be present in the bencoded output
# -a: force text-mode scan (the pieces blob contains arbitrary bytes,
# including NUL, which BSD grep otherwise treats as a binary file).
# LC_ALL=C: under a UTF-8 locale, BSD grep can silently fail to match an
# ASCII substring that sits next to invalid UTF-8 byte sequences -- which
# the SHA1 piece hashes are full of. The C locale treats bytes as bytes.
LC_ALL=C grep -aq 'url-list' "$tmp/out.torrent" || { echo "FAIL: no url-list"; exit 1; }
echo "PASS: make_fixture"
