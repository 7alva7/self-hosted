# Prebuilt Multi-Arch Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Self-hosted перестаёт компилировать код — образ собирается копированием артефактов из готовых multi-arch образов компонентов, публикуется под linux/amd64 + linux/arm64, а версии компонентов бампаются Renovate и проверяются e2e-смоуком.

**Architecture:** Сначала пишутся e2e-тесты и прогоняются против текущего опубликованного образа — это baseline и регрессионный гейт. Параллельно компонентные CI переводятся на buildx multi-arch через переиспользуемый workflow в `webtor-io/.github`. Затем Dockerfile self-hosted переписывается на `FROM ghcr.io/webtor-io/<svc>@sha256:… AS <svc>` + `COPY --from`, s6-overlay выбирает архитектуру по `TARGETARCH`, CI гоняет смоук нативно на amd64- и arm64-раннерах.

**Tech Stack:** Docker buildx, GitHub Actions (reusable workflows, `ubuntu-24.04-arm`), s6-overlay v3, bash + curl + jq для тестов, Python 3 stdlib для генератора торрент-фикстуры, Renovate.

**Spec:** `docs/superpowers/specs/2026-08-17-prebuilt-multiarch-design.md`

## Global Constraints

- Платформы: **`linux/amd64,linux/arm64`**. armv7 не поддерживается — при неизвестном `TARGETARCH` сборка обязана падать с явной ошибкой, а не собирать битый образ.
- Компоненты пинятся как `FROM ghcr.io/webtor-io/<svc>:<tag>@sha256:<digest>` — **тег И дайджест**, иначе Renovate не сможет обновлять.
- Дефолтные ветки различаются: `main` у `rest-api`, `web-ui`, `nginx-vod`, `torrent-web-seeder-cleaner`; `master` у остальных семи. Тег образа по умолчанию совпадает с именем дефолтной ветки.
- Пути артефактов внутри компонентных образов (проверено 2026-08-17): бинарь `/server` у torrent-store, magnet2torrent, external-proxy, torrent-web-seeder, torrent-web-seeder-cleaner, torrent-archiver, srt2vtt, torrent-http-proxy, rest-api; `/app/server` + `/app/player` у content-transcoder; `/app/server` + `/app/templates` + `/app/pub` + `/app/migrations` + `/app/assets/dist` у web-ui; `/usr/local/nginx` у nginx-vod.
- Имена бинарей в `/app` менять нельзя — s6 run-скрипты вызывают `/app/<service-name>` (напр. `/app/torrent-http-proxy`, `cd /app && ./web-ui serve`).
- Тесты не ходят в интернет за контентом: фикстура генерируется локально, раздаётся своим nginx-webseed'ом, торрент трекерless.
- Никаких изменений в бизнес-логике компонентов. Работа затрагивает только CI компонентов и сборку/тесты self-hosted.
- **Образ для прогона сценариев (Tasks 5-7): `webtor-self-hosted:baseline`, а не дефолтный `:latest`.** Смоук Task 4
  вскрыл баг: `rest-api` отдавал неподписанные экспортные URL, и torrent-http-proxy отбивал их 403. Правка
  (`s6-overlay/s6-rc.d/rest-api/run` + `dependencies.d/generate-api-key-and-secret`) уже в ветке, но
  опубликованный `:latest` её не содержит, поэтому bare `tests/run.sh` падает по таймауту 180s. Команда
  пересборки локального тега — в отчёте Task 4. После Task 10 дефолтом станет локальная сборка репозитория.

## File Structure

**Создаётся в `self-hosted`:**
- `tests/fixtures/make_fixture.py` — генератор `.torrent` с webseed (bencode, Python 3 stdlib).
- `tests/fixtures/build.sh` — генерирует медиа через docker+ffmpeg и вызывает `make_fixture.py`.
- `tests/fixtures/test_make_fixture.sh` — юнит-тест генератора.
- `tests/docker-compose.yml` — self-hosted + nginx-webseed в одной сети.
- `tests/lib.sh` — общие хелперы (`wait_for`, `api`, `fail`, `assert_eq`).
- `tests/run.sh` — раннер: поднимает окружение, гоняет сценарии, гасит.
- `tests/scenarios/*.sh` — по файлу на сценарий (boot, ddl, archive, hls, subtitles, persistence).
- `renovate.json` — автобамп дайджестов компонентов.
- `.github/workflows/test.yml` — сборка + смоук на матрице amd64/arm64.

**Модифицируется в `self-hosted`:** `Dockerfile` (переписывается целиком), `.github/workflows/docker-image.yml` (buildx multi-arch), `README.md`, `CLAUDE.md`.

**Создаётся в `webtor-io/.github`:** `.github/workflows/docker-multiarch.yml` — переиспользуемый workflow.

**Модифицируется в 12 компонентных репо:** `.github/workflows/docker-image.yml` → вызов reusable.

---

### Task 1: Генератор торрент-фикстуры

Детерминированный `.torrent` без трекеров, с BEP19 webseed. Проверено: `torrent-web-seeder` использует anacrolix v1.60 и включает webseed'ы по умолчанию (`DisableWebseeds` — opt-in флаг), поэтому пиры и трекеры в тестах не нужны.

**Files:**
- Create: `tests/fixtures/make_fixture.py`
- Test: `tests/fixtures/test_make_fixture.sh`

**Interfaces:**
- Consumes: ничего.
- Produces: `make_fixture.py <content-dir> <webseed-url> <out.torrent>` пишет торрент и печатает в stdout JSON: `{"name": str, "infohash": str(40 hex), "files": [{"path": str, "length": int}], "piece_length": int, "pieces_count": int, "total_length": int}`. Раскладка фикстуры (используется всеми сценариями): `webtor-smoke/video.mp4`, `webtor-smoke/readme.txt`, `webtor-smoke/subs/subtitle.srt`.

- [ ] **Step 1: Написать падающий тест**

Создать `tests/fixtures/test_make_fixture.sh`:

```bash
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
grep -q 'url-list' "$tmp/out.torrent" || { echo "FAIL: no url-list"; exit 1; }
echo "PASS: make_fixture"
```

- [ ] **Step 2: Прогнать тест — убедиться, что падает**

Run: `chmod +x tests/fixtures/test_make_fixture.sh && tests/fixtures/test_make_fixture.sh`
Expected: FAIL — `python3: can't open file '.../make_fixture.py': No such file or directory`

- [ ] **Step 3: Написать генератор**

Создать `tests/fixtures/make_fixture.py`:

```python
#!/usr/bin/env python3
"""Build a trackerless multi-file .torrent with a BEP19 webseed (url-list).

Usage: make_fixture.py <content-dir> <webseed-url> <out.torrent>
Prints a JSON summary of what was built.
"""
import hashlib
import json
import sys
from pathlib import Path

PIECE_LENGTH = 32768


def bencode(value):
    if isinstance(value, bool):
        raise TypeError("bool is not bencodable")
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, str):
        return bencode(value.encode())
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, list):
        return b"l" + b"".join(bencode(v) for v in value) + b"e"
    if isinstance(value, dict):
        out = b"d"
        for key in sorted(value):
            out += bencode(key) + bencode(value[key])
        return out + b"e"
    raise TypeError("cannot bencode %r" % type(value))


def build(root: Path, webseed: str, out: Path):
    # Sorted so piece hashing is deterministic for a given content tree.
    paths = sorted(p for p in root.rglob("*") if p.is_file())
    if not paths:
        raise SystemExit("no files under %s" % root)

    files = []
    pieces = b""
    buf = b""
    for path in paths:
        data = path.read_bytes()
        files.append(
            {
                b"length": len(data),
                b"path": [part.encode() for part in path.relative_to(root).parts],
            }
        )
        buf += data
        while len(buf) >= PIECE_LENGTH:
            pieces += hashlib.sha1(buf[:PIECE_LENGTH]).digest()
            buf = buf[PIECE_LENGTH:]
    if buf:
        pieces += hashlib.sha1(buf).digest()

    info = {
        b"name": root.name.encode(),
        b"piece length": PIECE_LENGTH,
        b"pieces": pieces,
        b"files": files,
    }
    # url-list as a list: both forms are legal, anacrolix accepts either.
    torrent = {b"info": info, b"url-list": [webseed.encode()]}
    out.write_bytes(bencode(torrent))

    return {
        "name": root.name,
        "infohash": hashlib.sha1(bencode(info)).hexdigest(),
        "files": [
            {
                "path": "/".join(p.decode() for p in f[b"path"]),
                "length": f[b"length"],
            }
            for f in files
        ],
        "piece_length": PIECE_LENGTH,
        "pieces_count": len(pieces) // 20,
        "total_length": sum(f[b"length"] for f in files),
    }


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    content_dir, webseed, out = sys.argv[1], sys.argv[2], sys.argv[3]
    print(json.dumps(build(Path(content_dir), webseed, Path(out))))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Прогнать тест — убедиться, что проходит**

Run: `tests/fixtures/test_make_fixture.sh`
Expected: PASS — последняя строка `PASS: make_fixture`

- [ ] **Step 5: Коммит**

```bash
git add tests/fixtures/make_fixture.py tests/fixtures/test_make_fixture.sh
git commit -m "test: add deterministic torrent fixture generator"
```

---

### Task 2: Сборка медиа-фикстуры

**Files:**
- Create: `tests/fixtures/build.sh`
- Modify: `.gitignore` (добавить `tests/fixtures/content/`, `tests/fixtures/*.torrent`)

**Interfaces:**
- Consumes: `make_fixture.py` из Task 1.
- Produces: `tests/fixtures/build.sh` создаёт `tests/fixtures/content/webtor-smoke/{video.mp4,readme.txt,subs/subtitle.srt}` и `tests/fixtures/smoke.torrent`, печатает JSON-сводку в `tests/fixtures/summary.json`. ffmpeg берётся из docker-образа `jrottenberg/ffmpeg:8-alpine` (мультиарховый, проверено) — на хосте ffmpeg не нужен.

- [ ] **Step 1: Написать скрипт сборки фикстуры**

Создать `tests/fixtures/build.sh`:

```bash
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
```

- [ ] **Step 2: Прогнать и убедиться, что фикстура собирается**

Run: `chmod +x tests/fixtures/build.sh && tests/fixtures/build.sh`
Expected: печатается JSON со `"name": "webtor-smoke"` и тремя файлами; `tests/fixtures/smoke.torrent` существует; `tests/fixtures/content/webtor-smoke/video.mp4` — валидный mp4 ненулевого размера.

Проверка размера видео (должно быть заметно больше одного пиcа, чтобы HLS-сценарий был осмысленным):

Run: `python3 -c "import json;d=json.load(open('tests/fixtures/summary.json'));print(d['total_length'], d['pieces_count'])"`
Expected: `total_length` > 100000, `pieces_count` > 3

- [ ] **Step 3: Исключить артефакты из git**

Добавить в `.gitignore`:

```
tests/fixtures/content/
tests/fixtures/*.torrent
tests/fixtures/summary.json
```

- [ ] **Step 4: Коммит**

```bash
git add tests/fixtures/build.sh .gitignore
git commit -m "test: add fixture build script (synthetic media + webseed torrent)"
```

---

### Task 3: Тестовое окружение и boot-сценарий

Первый исполняемый смоук. Гоняется против **текущего опубликованного** образа `ghcr.io/webtor-io/self-hosted:latest` — это baseline: если он не зелёный, переписывать Dockerfile нельзя, потому что не с чем будет сравнивать.

**Files:**
- Create: `tests/docker-compose.yml`, `tests/lib.sh`, `tests/run.sh`, `tests/scenarios/00-boot.sh`

**Interfaces:**
- Consumes: `tests/fixtures/build.sh` из Task 2.
- Produces:
  - `tests/run.sh [image]` — образ по умолчанию `ghcr.io/webtor-io/self-hosted:latest`, переопределяется первым аргументом или `WEBTOR_IMAGE`. Возвращает 0 при успехе всех сценариев.
  - `tests/lib.sh` экспортирует: `BASE_URL` (`http://localhost:8080`), `FIXTURE_DIR`, `fail <msg>` (печатает и выходит с 1), `assert_eq <actual> <expected> <msg>`, `wait_for <timeout-sec> <description> <command...>` (повторяет команду раз в секунду до успеха), `api <method> <path> [curl-args...]` (curl к `$BASE_URL`, `--fail-with-body -sS`).
  - Каждый сценарий — исполняемый файл в `tests/scenarios/`, запускается с `tests/lib.sh` уже подключённым через `source`; печатает `PASS: <name>` в конце.

- [ ] **Step 1: Написать окружение compose**

Создать `tests/docker-compose.yml`:

```yaml
services:
  webseed:
    image: nginx:alpine
    volumes:
      - ./fixtures/content:/usr/share/nginx/html:ro

  webtor:
    image: ${WEBTOR_IMAGE:-ghcr.io/webtor-io/self-hosted:latest}
    depends_on:
      - webseed
    environment:
      DOMAIN: http://localhost:8080
    ports:
      - "8080:8080"
    volumes:
      - data:/data
      - pgdata:/pgdata

volumes:
  data:
  pgdata:
```

Webseed резолвится внутри сети compose по имени `webseed` — ровно тот URL, что зашит в торрент (`http://webseed/`). `DOMAIN=http://localhost:8080` нужен, чтобы экспортируемые rest-api ссылки были достижимы с хоста.

- [ ] **Step 2: Написать библиотеку хелперов**

Создать `tests/lib.sh`:

```bash
# Shared helpers for smoke scenarios. Sourced, not executed.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"
BASE_URL="${BASE_URL:-http://localhost:8080}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  [ "$actual" = "$expected" ] || fail "$msg (got '$actual', want '$expected')"
}

# wait_for <timeout-sec> <description> <command...>
wait_for() {
  local timeout="$1" desc="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || fail "timed out after ${timeout}s waiting for: $desc"
    sleep 1
  done
}

# api <method> <path> [extra curl args...]
api() {
  local method="$1" path="$2"
  shift 2
  curl --fail-with-body -sS -X "$method" "$BASE_URL$path" "$@"
}
```

- [ ] **Step 3: Написать boot-сценарий**

Создать `tests/scenarios/00-boot.sh`:

```bash
#!/usr/bin/env bash
# All s6 services come up and the front door answers.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

wait_for 180 "web-ui front page" curl -fsS "$BASE_URL/"

code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")"
assert_eq "$code" "200" "front page status"

# rest-api must be reachable through the nginx /rest-api/ prefix.
wait_for 60 "rest-api swagger" curl -fsS "$BASE_URL/rest-api/swagger/index.html"

echo "PASS: boot"
```

- [ ] **Step 4: Написать раннер**

Создать `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Run the self-hosted smoke suite against an image.
#   tests/run.sh [image]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WEBTOR_IMAGE="${1:-${WEBTOR_IMAGE:-ghcr.io/webtor-io/self-hosted:latest}}"
compose=(docker compose -f "$here/docker-compose.yml" -p webtor-smoke)

echo "== image under test: $WEBTOR_IMAGE"

"$here/fixtures/build.sh"

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "== webtor logs (tail) =="
    "${compose[@]}" logs --tail 200 webtor || true
  fi
  "${compose[@]}" down -v --remove-orphans || true
  exit "$rc"
}
trap cleanup EXIT

"${compose[@]}" up -d --force-recreate

failed=0
for scenario in "$here"/scenarios/*.sh; do
  name="$(basename "$scenario")"
  echo "== running $name"
  if bash "$scenario"; then
    :
  else
    echo "!! $name failed"
    failed=1
  fi
done

[ "$failed" -eq 0 ] || { echo "SUITE FAILED"; exit 1; }
echo "SUITE PASSED"
```

- [ ] **Step 5: Прогнать против текущего образа — зафиксировать baseline**

Run: `chmod +x tests/run.sh tests/scenarios/00-boot.sh && tests/run.sh`
Expected: `PASS: boot`, затем `SUITE PASSED`

Если boot не проходит на текущем `:latest` — остановиться и разобраться до продолжения: без зелёного baseline последующие таски не смогут отличить регрессию сборки от уже существующей поломки.

- [ ] **Step 6: Коммит**

```bash
git add tests/docker-compose.yml tests/lib.sh tests/run.sh tests/scenarios/00-boot.sh
git commit -m "test: add smoke harness and boot scenario"
```

---

### Task 4: Сценарий DDL (загрузка торрента, листинг, скачивание файла)

**Files:**
- Create: `tests/scenarios/10-ddl.sh`

**Interfaces:**
- Consumes: `tests/lib.sh` (`api`, `wait_for`, `assert_eq`, `fail`, `FIXTURE_DIR`).
- Produces: состояние между сценариями не передаётся — каждый сценарий самодостаточен и сам заливает торрент. Контракт rest-api, на который опираются все дальнейшие сценарии:
  - `POST /rest-api/resource/` с телом = байты `.torrent` → `{"id": "<40 hex infohash>", "name": ..., "magnet_uri": ...}`
  - `GET /rest-api/resource/<id>/list?path=<path>` → `{"items": [{"id","name","path","type","size","media_format","ext"}], "items_count": N}`, где `type` = `file` либо `dir`
  - `GET /rest-api/resource/<id>/export/<content_id>` → `{"source": {...}, "exports": {"download": {"url": ...}, "stream": {"url": ..., "html_tag": {...}}, ...}}`

- [ ] **Step 1: Разведать фактический контракт API**

Перед написанием ассертов снять реальные ответы (структуры выше вычитаны из `rest-api/services/models.go`, но версия образа может отличаться):

```bash
tests/fixtures/build.sh
docker compose -f tests/docker-compose.yml -p webtor-smoke up -d
ID=$(curl -sS --fail-with-body -X POST --data-binary @tests/fixtures/smoke.torrent \
     http://localhost:8080/rest-api/resource/ | tee /dev/stderr | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
curl -sS "http://localhost:8080/rest-api/resource/$ID/list?path=/" | python3 -m json.tool
CID=$(curl -sS "http://localhost:8080/rest-api/resource/$ID/list?path=/" \
      | python3 -c 'import json,sys;print([i for i in json.load(sys.stdin)["items"] if i["name"]=="video.mp4"][0]["id"])')
curl -sS "http://localhost:8080/rest-api/resource/$ID/export/$CID" | python3 -m json.tool
docker compose -f tests/docker-compose.yml -p webtor-smoke down -v
```

Записать наблюдаемые имена полей. Если они расходятся с контрактом выше — использовать наблюдаемые и обновить блок Interfaces этого таска. Если `POST /rest-api/resource/` возвращает 401/403 (в self-hosted rest-api запускается без API-ключа, так что не должен), переключить сценарии на эндпоинты, которыми пользуется web-ui, и зафиксировать это решение в спеке.

- [ ] **Step 2: Написать падающий сценарий**

Создать `tests/scenarios/10-ddl.sh`:

```bash
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
```

Замечание про `shasum`: на ubuntu-раннерах он присутствует (пакет perl), на macOS — тоже. Если в конкретном окружении его нет — заменить на `sha256sum` через враппер в `lib.sh`.

- [ ] **Step 3: Прогнать — убедиться, что сценарий реально проверяет систему**

Run: `chmod +x tests/scenarios/10-ddl.sh && tests/run.sh`
Expected: `PASS: boot`, `PASS: ddl`, `SUITE PASSED`

- [ ] **Step 4: Негативный контроль**

Сломать webseed и убедиться, что сценарий краснеет (иначе он проверяет не то, что заявлено): временно поменять в `tests/docker-compose.yml` volume webseed'а на пустую директорию, прогнать `tests/run.sh`, увидеть падение `10-ddl` по таймауту, вернуть как было.

Expected: без webseed'а `10-ddl` падает, `00-boot` продолжает проходить.

- [ ] **Step 5: Коммит**

```bash
git add tests/scenarios/10-ddl.sh
git commit -m "test: add DDL scenario (upload, list, download, checksum)"
```

---

### Task 5: Сценарий ZIP-архива

**Files:**
- Create: `tests/scenarios/20-archive.sh`

**Interfaces:**
- Consumes: контракт rest-api из Task 4. Для директорий `DownloadURLBuilder` добавляет к пути `~arch/<name>.zip` — поэтому архивная ссылка приходит тем же полем `.exports.download.url`, но для элемента с `"type": "dir"`.
- Produces: ничего для последующих тасков.

- [ ] **Step 1: Написать сценарий**

Создать `tests/scenarios/20-archive.sh`:

```bash
#!/usr/bin/env bash
# A directory inside the torrent downloads as a zip with the right contents.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

json() { python3 -c "import json,sys;print($1)"; }

resource="$(api POST /rest-api/resource/ --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(printf '%s' "$resource" | json 'json.load(sys.stdin)["id"]')"

listing="$(api GET "/rest-api/resource/$id/list?path=/")"
dir_id="$(printf '%s' "$listing" | json '[i for i in json.load(sys.stdin)["items"] if i["name"]=="subs"][0]["id"]')"
[ -n "$dir_id" ] || fail "directory 'subs' not found in listing: $listing"

export_json="$(api GET "/rest-api/resource/$id/export/$dir_id")"
url="$(printf '%s' "$export_json" | json 'json.load(sys.stdin)["exports"]["download"]["url"]')"
case "$url" in
  *arch*) : ;;
  *) fail "directory download url does not route through torrent-archiver: $url" ;;
esac

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
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
```

- [ ] **Step 2: Прогнать**

Run: `chmod +x tests/scenarios/20-archive.sh && tests/run.sh`
Expected: `PASS: archive` в числе прочих, `SUITE PASSED`

- [ ] **Step 3: Коммит**

```bash
git add tests/scenarios/20-archive.sh
git commit -m "test: add zip archive scenario"
```

---

### Task 6: Сценарий HLS-стриминга

Самый ценный сценарий: единственный, который проходит через content-transcoder → nginx-vod → torrent-http-proxy разом.

**Files:**
- Create: `tests/scenarios/30-hls.sh`

**Interfaces:**
- Consumes: контракт rest-api из Task 4. `.exports.stream.url` заканчивается на `/index.m3u8` (см. `StreamURLBuilder.Build`).
- Produces: ничего для последующих тасков.

- [ ] **Step 1: Написать сценарий**

Создать `tests/scenarios/30-hls.sh`:

```bash
#!/usr/bin/env bash
# The video streams as HLS: manifest is served and its first segment downloads.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

json() { python3 -c "import json,sys;print($1)"; }

resource="$(api POST /rest-api/resource/ --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(printf '%s' "$resource" | json 'json.load(sys.stdin)["id"]')"

listing="$(api GET "/rest-api/resource/$id/list?path=/")"
content_id="$(printf '%s' "$listing" | json '[i for i in json.load(sys.stdin)["items"] if i["name"]=="video.mp4"][0]["id"]')"

export_json="$(api GET "/rest-api/resource/$id/export/$content_id")"
url="$(printf '%s' "$export_json" | json 'json.load(sys.stdin)["exports"]["stream"]["url"]')"
[ -n "$url" ] || fail "no stream url: $export_json"
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

base="${url%/*}"
child="$base/$segment_line"
case "$segment_line" in
  *.m3u8*)
    media="$(mktemp)"
    wait_for 120 "media playlist" curl -fsS -o "$media" "$child"
    segment_line="$(grep -v '^#' "$media" | head -1)"
    [ -n "$segment_line" ] || fail "media playlist has no segments: $(cat "$media")"
    child="${child%/*}/$segment_line"
    rm -f "$media"
    ;;
esac

seg="$(mktemp)"
wait_for 120 "first HLS segment" curl -fsS -o "$seg" "$child"
[ -s "$seg" ] || fail "first segment is empty: $child"
size="$(wc -c < "$seg")"
[ "$size" -gt 1000 ] || fail "first segment suspiciously small: $size bytes"
rm -f "$seg"

echo "PASS: hls"
```

- [ ] **Step 2: Прогнать**

Run: `chmod +x tests/scenarios/30-hls.sh && tests/run.sh`
Expected: `PASS: hls`, `SUITE PASSED`

Если падает по таймауту — посмотреть `docker compose -p webtor-smoke logs webtor | grep -E '\[content-transcoder\]|\[nginx\]'` и увеличить таймаут, а не ослаблять ассерты.

- [ ] **Step 3: Коммит**

```bash
git add tests/scenarios/30-hls.sh
git commit -m "test: add HLS streaming scenario"
```

---

### Task 7: Сценарии субтитров и персистентности

**Files:**
- Create: `tests/scenarios/40-subtitles.sh`, `tests/scenarios/50-persistence.sh`

**Interfaces:**
- Consumes: контракт rest-api из Task 4.
- Produces: ничего.

- [ ] **Step 1: Разведать, на каком элементе висит экспорт субтитров**

Ссылка на vtt может приходить либо в `exports.subtitles.url` элемента `.srt`, либо в `exports.stream.html_tag.tracks[]` элемента видео. Снять оба ответа:

```bash
tests/fixtures/build.sh
docker compose -f tests/docker-compose.yml -p webtor-smoke up -d
ID=$(curl -sS -X POST --data-binary @tests/fixtures/smoke.torrent http://localhost:8080/rest-api/resource/ | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
SRT=$(curl -sS "http://localhost:8080/rest-api/resource/$ID/list?path=/subs" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][0]["id"])')
curl -sS "http://localhost:8080/rest-api/resource/$ID/export/$SRT" | python3 -m json.tool
docker compose -f tests/docker-compose.yml -p webtor-smoke down -v
```

Использовать в сценарии то поле, которое реально содержит URL; зафиксировать выбор комментарием в файле сценария.

- [ ] **Step 2: Написать сценарий субтитров**

Создать `tests/scenarios/40-subtitles.sh` (поле URL — из наблюдения в Step 1; ниже вариант через `exports.subtitles.url`):

```bash
#!/usr/bin/env bash
# The .srt inside the torrent is served as WebVTT through srt2vtt.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

json() { python3 -c "import json,sys;print($1)"; }

resource="$(api POST /rest-api/resource/ --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(printf '%s' "$resource" | json 'json.load(sys.stdin)["id"]')"

listing="$(api GET "/rest-api/resource/$id/list?path=/subs")"
srt_id="$(printf '%s' "$listing" | json '[i for i in json.load(sys.stdin)["items"] if i["name"]=="subtitle.srt"][0]["id"]')"
[ -n "$srt_id" ] || fail "subtitle.srt not found: $listing"

export_json="$(api GET "/rest-api/resource/$id/export/$srt_id")"
url="$(printf '%s' "$export_json" | json 'json.load(sys.stdin)["exports"]["subtitles"]["url"]')"
[ -n "$url" ] || fail "no subtitles url: $export_json"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
wait_for 180 "vtt conversion" curl -fsS -o "$out" "$url"

head -1 "$out" | grep -q 'WEBVTT' || fail "not a WebVTT document: $(head -3 "$out")"
grep -q 'webtor smoke test' "$out" || fail "cue text missing from vtt: $(cat "$out")"

echo "PASS: subtitles"
```

- [ ] **Step 3: Написать сценарий персистентности**

Создать `tests/scenarios/50-persistence.sh`:

```bash
#!/usr/bin/env bash
# State survives a container restart: embedded postgres keeps the resource and
# web-ui migrations are idempotent on an existing /pgdata.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

json() { python3 -c "import json,sys;print($1)"; }
compose=(docker compose -f "$TESTS_DIR/docker-compose.yml" -p webtor-smoke)

resource="$(api POST /rest-api/resource/ --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(printf '%s' "$resource" | json 'json.load(sys.stdin)["id"]')"

"${compose[@]}" restart webtor

wait_for 240 "front page after restart" curl -fsS "$BASE_URL/"
wait_for 120 "resource after restart" curl -fsS "$BASE_URL/rest-api/resource/$id"

listing="$(api GET "/rest-api/resource/$id/list?path=/")"
count="$(printf '%s' "$listing" | json 'len(json.load(sys.stdin)["items"])')"
[ "$count" -ge 3 ] || fail "listing broken after restart: $listing"

# A second boot must not re-run migrations destructively or crash-loop.
logs="$("${compose[@]}" logs --tail 400 webtor)"
printf '%s' "$logs" | grep -qiE 'panic:|migration failed' && fail "restart logs contain fatal errors"

echo "PASS: persistence"
```

Порядок важен: файл назван `50-`, чтобы рестарт случился после всех остальных сценариев.

- [ ] **Step 4: Прогнать полный набор**

Run: `chmod +x tests/scenarios/40-subtitles.sh tests/scenarios/50-persistence.sh && tests/run.sh`
Expected: `PASS: boot`, `PASS: ddl`, `PASS: archive`, `PASS: hls`, `PASS: subtitles`, `PASS: persistence`, `SUITE PASSED`

- [ ] **Step 5: Коммит**

```bash
git add tests/scenarios/40-subtitles.sh tests/scenarios/50-persistence.sh
git commit -m "test: add subtitles and persistence scenarios"
```

---

### Task 8: Переиспользуемый multi-arch workflow

**Files:**
- Create: `webtor-io/.github` → `.github/workflows/docker-multiarch.yml`

**Interfaces:**
- Consumes: ничего.
- Produces: reusable workflow `webtor-io/.github/.github/workflows/docker-multiarch.yml@main` с входами: `platforms` (string, default `linux/amd64,linux/arm64`), `context` (string, default `.`), `file` (string, default `Dockerfile`). Вызывающий обязан передать `permissions: {contents: read, packages: write}`.

- [ ] **Step 1: Склонировать org-репозиторий**

```bash
cd ~/Projects/webtor && gh repo clone webtor-io/.github dot-github && cd dot-github
```

- [ ] **Step 2: Написать workflow**

Создать `.github/workflows/docker-multiarch.yml`:

```yaml
name: Docker multi-arch build

on:
  workflow_call:
    inputs:
      platforms:
        type: string
        default: linux/amd64,linux/arm64
      context:
        type: string
        default: .
      file:
        type: string
        default: Dockerfile

jobs:
  docker:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Docker meta
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=ref,event=branch
            type=ref,event=pr
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha

      - name: Login to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: ${{ inputs.context }}
          file: ${{ inputs.file }}
          platforms: ${{ inputs.platforms }}
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

Схема тегов сохранена ровно как в текущих workflow компонентов — существующие потребители (helmfile, sync.sh) не ломаются. `cache-from/to: gha` добавлен, потому что QEMU-сборка arm64 без кеша повторяется каждый раз целиком.

- [ ] **Step 3: Закоммитить и запушить**

```bash
git add .github/workflows/docker-multiarch.yml
git commit -m "ci: add reusable multi-arch docker build workflow"
git push
```

- [ ] **Step 4: Проверить, что workflow виден как reusable**

Run: `gh api repos/webtor-io/.github/contents/.github/workflows/docker-multiarch.yml --jq .name`
Expected: `docker-multiarch.yml`

---

### Task 9: Перевод компонентов на multi-arch

Двенадцать репозиториев, одинаковая правка. Начинать с `nginx-vod` — он единственный, чей образ раньше вообще не проверялся на пригодность для self-hosted.

**Files:**
- Modify (в каждом из 12 репо): `.github/workflows/docker-image.yml`

**Interfaces:**
- Consumes: reusable workflow из Task 8.
- Produces: образы `ghcr.io/webtor-io/<svc>` с манифест-листом, содержащим `linux/amd64` и `linux/arm64`.

- [ ] **Step 1: Перевести nginx-vod**

В `~/Projects/webtor/nginx-vod/.github/workflows/docker-image.yml` заменить содержимое на:

```yaml
name: Docker Image CI

on:
  workflow_dispatch:
  push:
    branches:
      - 'main'
    tags:
      - 'v*'

jobs:
  docker:
    uses: webtor-io/.github/.github/workflows/docker-multiarch.yml@main
    permissions:
      contents: read
      packages: write
```

Ветку в `on.push.branches` брать из дефолтной ветки конкретного репо (см. Global Constraints), а не копировать вслепую.

- [ ] **Step 2: Запушить и дождаться зелёной сборки**

```bash
cd ~/Projects/webtor/nginx-vod
git add .github/workflows/docker-image.yml
git commit -m "ci: build multi-arch image (amd64 + arm64)"
git push
gh run watch "$(gh run list -L 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: run завершается `success`

- [ ] **Step 3: Проверить манифест**

Run: `docker manifest inspect ghcr.io/webtor-io/nginx-vod:main | grep -c '"architecture"'`
Expected: не меньше 2; в выводе присутствуют и `amd64`, и `arm64`

- [ ] **Step 4: Повторить для остальных одиннадцати**

Для каждого из `torrent-store`, `magnet2torrent`, `external-proxy`, `torrent-web-seeder`, `torrent-web-seeder-cleaner`, `content-transcoder`, `torrent-archiver`, `srt2vtt`, `torrent-http-proxy`, `rest-api`, `web-ui` выполнить Steps 1–3, подставляя правильную дефолтную ветку.

Ожидаемая проблема: `torrent-web-seeder` и `srt2vtt` собираются с CGO, под QEMU их arm64-сборка может занять 30–60 минут. Если время выходит за лимит job'а — перевести именно эти два репозитория на кросс-компиляцию: в их Dockerfile заменить build-стейдж на `FROM --platform=$BUILDPLATFORM golang:… AS build` с `ARG TARGETARCH`, `ENV GOARCH=$TARGETARCH`, и musl-кросс-тулчейном для CGO. Остальные десять не трогать.

- [ ] **Step 5: Свести результат**

Run:
```bash
for svc in torrent-store magnet2torrent external-proxy torrent-web-seeder torrent-web-seeder-cleaner \
           content-transcoder torrent-archiver srt2vtt torrent-http-proxy rest-api web-ui nginx-vod; do
  br=$(gh api "repos/webtor-io/$svc" --jq .default_branch)
  archs=$(docker manifest inspect "ghcr.io/webtor-io/$svc:$br" | grep '"architecture"' | sort -u | tr -d ' "' | paste -sd, -)
  echo "$svc:$br -> $archs"
done
```
Expected: у всех двенадцати в списке есть `architecture:amd64` и `architecture:arm64`

---

### Task 10: Переписать Dockerfile self-hosted на сборку из готовых образов

**Files:**
- Modify: `Dockerfile` (полная замена)

**Interfaces:**
- Consumes: multi-arch образы компонентов из Task 9.
- Produces: образ, в котором `/app/<service-name>` — бинарь каждого сервиса (имена в точности как в s6 run-скриптах), `/app/templates`, `/app/pub`, `/app/migrations`, `/app/assets/dist` — ассеты web-ui, `/app/player` — плеер content-transcoder, `/usr/local/nginx` — nginx с VOD-модулями.

- [ ] **Step 1: Собрать дайджесты компонентов**

```bash
for svc in torrent-store magnet2torrent external-proxy torrent-web-seeder torrent-web-seeder-cleaner \
           content-transcoder torrent-archiver srt2vtt torrent-http-proxy rest-api web-ui nginx-vod; do
  br=$(gh api "repos/webtor-io/$svc" --jq .default_branch)
  d=$(docker buildx imagetools inspect "ghcr.io/webtor-io/$svc:$br" | awk '/^Digest:/{print $2; exit}')
  echo "ghcr.io/webtor-io/$svc:$br@$d"
done
```

Вывод этой команды подставляется в `FROM`-строки следующего шага дословно.

- [ ] **Step 2: Переписать Dockerfile**

Заменить содержимое `Dockerfile` на (дайджесты — из Step 1, ниже показаны плейсхолдеры вида `sha256:<digest>`, которые обязаны быть заменены реальными значениями перед сборкой):

```dockerfile
ARG ALPINE_VER="3.22"
ARG S6_OVERLAY_VER="3.2.0.2"
ARG S6_VERBOSITY=1

# Component images are pinned by tag AND digest so Renovate can bump them
# and builds stay reproducible. Nothing is compiled here any more.
FROM ghcr.io/webtor-io/torrent-store:master@sha256:<digest> AS torrent-store
FROM ghcr.io/webtor-io/magnet2torrent:master@sha256:<digest> AS magnet2torrent
FROM ghcr.io/webtor-io/external-proxy:master@sha256:<digest> AS external-proxy
FROM ghcr.io/webtor-io/torrent-web-seeder:master@sha256:<digest> AS torrent-web-seeder
FROM ghcr.io/webtor-io/torrent-web-seeder-cleaner:main@sha256:<digest> AS torrent-web-seeder-cleaner
FROM ghcr.io/webtor-io/content-transcoder:master@sha256:<digest> AS content-transcoder
FROM ghcr.io/webtor-io/torrent-archiver:master@sha256:<digest> AS torrent-archiver
FROM ghcr.io/webtor-io/srt2vtt:master@sha256:<digest> AS srt2vtt
FROM ghcr.io/webtor-io/torrent-http-proxy:master@sha256:<digest> AS torrent-http-proxy
FROM ghcr.io/webtor-io/rest-api:main@sha256:<digest> AS rest-api
FROM ghcr.io/webtor-io/web-ui:main@sha256:<digest> AS web-ui
FROM ghcr.io/webtor-io/nginx-vod:main@sha256:<digest> AS nginx-vod

FROM alpine:${ALPINE_VER}

ARG S6_OVERLAY_VER
ARG S6_VERBOSITY
ARG TARGETARCH
ENV S6_VERBOSITY=$S6_VERBOSITY

LABEL org.opencontainers.image.source="https://github.com/webtor-io/self-hosted"

RUN apk --no-cache add redis ffmpeg ca-certificates openssl pcre zlib envsubst uuidgen \
    postgresql postgresql-client postgresql-contrib curl

ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VER}/s6-overlay-noarch.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && rm /tmp/s6-overlay-noarch.tar.xz

# s6-overlay ships per-arch tarballs under names that do not match TARGETARCH.
RUN case "$TARGETARCH" in \
      amd64) s6arch=x86_64 ;; \
      arm64) s6arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/s6-overlay-arch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VER}/s6-overlay-${s6arch}.tar.xz" && \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz && \
    rm /tmp/s6-overlay-arch.tar.xz

WORKDIR /app

# Binary names must match what the s6 run scripts invoke (/app/<service>).
COPY --from=torrent-store /server ./torrent-store
COPY --from=magnet2torrent /server ./magnet2torrent
COPY --from=external-proxy /server ./external-proxy
COPY --from=torrent-web-seeder /server ./torrent-web-seeder
COPY --from=torrent-web-seeder-cleaner /server ./torrent-web-seeder-cleaner
COPY --from=torrent-archiver /server ./torrent-archiver
COPY --from=srt2vtt /server ./srt2vtt
COPY --from=torrent-http-proxy /server ./torrent-http-proxy
COPY --from=rest-api /server ./rest-api
COPY --from=content-transcoder /app/server ./content-transcoder
COPY --from=content-transcoder /app/player ./player
COPY --from=web-ui /app/server ./web-ui
COPY --from=web-ui /app/templates ./templates
COPY --from=web-ui /app/pub ./pub
COPY --from=web-ui /app/migrations ./migrations
COPY --from=web-ui /app/assets/dist ./assets/dist
COPY --from=nginx-vod /usr/local/nginx /usr/local/nginx

COPY etc/webtor /etc/webtor
COPY etc/nginx/conf /usr/local/nginx/conf
COPY s6-overlay /etc/s6-overlay
COPY cont-init.d /etc/cont-init.d

RUN find /etc/s6-overlay -type f \( -name run -o -name up \) -exec chmod +x {} +
RUN find /etc/cont-init.d -type f -exec chmod +x {} +

EXPOSE 8080
# Optionally expose Postgres for host access
EXPOSE 5432

ENTRYPOINT ["/init"]
```

- [ ] **Step 3: Собрать под родной архитектурой**

Run: `docker build -t webtor-self-hosted:assembly .`
Expected: сборка проходит; на порядок быстрее прежней (минуты вместо десятков минут), в логах нет ни `go build`, ни `npm`

- [ ] **Step 4: Прогнать смоук против нового образа — главный гейт**

Run: `tests/run.sh webtor-self-hosted:assembly`
Expected: `SUITE PASSED` — все шесть сценариев зелёные

Падения здесь — это, как правило, не поломка сборки, а последствия скачка версий компонентов (переименованные env-переменные, изменившиеся флаги, новый формат конфига torrent-http-proxy). Чинить в `s6-overlay/s6-rc.d/*/run`, `etc/webtor/common.template.env`, `etc/webtor/torrent-http-proxy/config.yaml`, сверяясь с README и флагами в исходниках соответствующего компонента.

- [ ] **Step 5: Проверить негативный контроль по архитектуре**

Run: `docker build --build-arg TARGETARCH=riscv64 -t should-fail . 2>&1 | tail -3`
Expected: сборка падает с `unsupported TARGETARCH: riscv64`

- [ ] **Step 6: Коммит**

```bash
git add Dockerfile
git commit -m "build: assemble image from prebuilt component images instead of compiling"
```

---

### Task 11: Multi-arch сборка self-hosted и CI-прогон тестов

**Files:**
- Create: `.github/workflows/test.yml`
- Modify: `.github/workflows/docker-image.yml`

**Interfaces:**
- Consumes: `tests/run.sh` (Task 3–7), Dockerfile из Task 10.
- Produces: PR-гейт, собирающий образ и гоняющий смоук нативно на amd64 и arm64; релизный workflow, публикующий манифест-лист с обеими архитектурами.

- [ ] **Step 1: Проверить arm64 локально до автоматизации**

На Apple Silicon:

Run: `docker build --platform linux/arm64 -t webtor-self-hosted:arm64 . && tests/run.sh webtor-self-hosted:arm64`
Expected: `SUITE PASSED`

Это первое реальное подтверждение ARM-поддержки; без него CI-матрица проверяет неизвестно что.

- [ ] **Step 2: Написать тестовый workflow**

Создать `.github/workflows/test.yml`:

```yaml
name: Smoke tests

on:
  pull_request:
  workflow_dispatch:

jobs:
  smoke:
    strategy:
      fail-fast: false
      matrix:
        include:
          - runner: ubuntu-latest
            arch: amd64
          - runner: ubuntu-24.04-arm
            arch: arm64
    runs-on: ${{ matrix.runner }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      # Native runner per arch: no QEMU, so the smoke suite exercises real
      # arm64 binaries at real speed.
      - name: Build image
        uses: docker/build-push-action@v6
        with:
          context: .
          load: true
          tags: webtor-self-hosted:ci
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Run smoke suite
        run: tests/run.sh webtor-self-hosted:ci
```

- [ ] **Step 3: Перевести релизный workflow на multi-arch**

Заменить содержимое `.github/workflows/docker-image.yml` на:

```yaml
name: Docker Image CI

on:
  workflow_dispatch:
  push:
    tags:
      - 'v*'

jobs:
  docker:
    uses: webtor-io/.github/.github/workflows/docker-multiarch.yml@main
    permissions:
      contents: read
      packages: write
```

- [ ] **Step 4: Проверить на PR**

```bash
git checkout -b ci/multiarch
git add .github/workflows/test.yml .github/workflows/docker-image.yml
git commit -m "ci: build multi-arch and run smoke suite on amd64 and arm64"
git push -u origin ci/multiarch
gh pr create --fill
gh pr checks --watch
```

Expected: обе job'ы матрицы (`smoke (amd64)`, `smoke (arm64)`) — зелёные

- [ ] **Step 5: Смёржить**

```bash
gh pr merge --squash --delete-branch
```

---

### Task 12: Renovate

**Files:**
- Create: `renovate.json`

**Interfaces:**
- Consumes: `FROM`-строки с тегом и дайджестом из Task 10.
- Produces: PR-ы с бампом дайджестов компонентов, каждый из которых автоматически проходит через smoke-матрицу из Task 11.

- [ ] **Step 1: Написать конфиг**

Создать `renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "labels": ["dependencies"],
  "packageRules": [
    {
      "description": "Webtor components: keep the tag, bump the digest, one PR each",
      "matchDatasources": ["docker"],
      "matchPackageNames": ["ghcr.io/webtor-io/**"],
      "pinDigests": true,
      "groupName": null,
      "schedule": ["at any time"]
    },
    {
      "description": "Base images move rarely; group them to keep PR noise down",
      "matchDatasources": ["docker"],
      "matchPackageNames": ["alpine"],
      "groupName": "base images"
    }
  ]
}
```

Отдельные PR на компонент — осознанно: смоук должен уметь указать пальцем, какой именно компонент сломал сборку.

- [ ] **Step 2: Провалидировать конфиг**

Run: `npx --yes --package renovate -- renovate-config-validator renovate.json`
Expected: `Config validated successfully`

- [ ] **Step 3: Коммит**

```bash
git add renovate.json
git commit -m "ci: let Renovate bump pinned component digests"
```

- [ ] **Step 4: Включить Renovate для репозитория (ручное действие владельца)**

Установить/разрешить приложение Renovate на `webtor-io/self-hosted` через GitHub UI (`https://github.com/apps/renovate`), затем дождаться onboarding-PR.

Expected: в репозитории появляется Dependency Dashboard issue и первые PR-ы с бампом дайджестов

---

### Task 13: Документация

**Files:**
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: результат Task 10–12.
- Produces: ничего.

- [ ] **Step 1: Заявить ARM в README**

В `README.md` после раздела «Quick Setup» добавить:

```markdown
## Supported Platforms

The image is published for `linux/amd64` and `linux/arm64`, so it runs on
x86 servers, Apple Silicon and 64-bit ARM boards and NAS devices. Docker
picks the right variant automatically — the `docker run` command above is
the same on every platform.
```

- [ ] **Step 2: Переписать в CLAUDE.md разделы про сборку**

В `CLAUDE.md` заменить:
- Раздел «Как обновить версию сервиса» — вместо `ARG <SERVICE>_COMMIT` описать, что компоненты пинятся `FROM ghcr.io/webtor-io/<svc>:<tag>@sha256:<digest>` и бампаются Renovate-PR-ами, а ручной бамп — это правка дайджеста в `FROM`.
- Подраздел «Сборка (Dockerfile)» в «Архитектура образа» — вместо описания build-стейджей описать assembly: `FROM … AS <svc>` + `COPY --from`, точные пути артефактов, требование совпадения имён бинарей в `/app` с s6 run-скриптами, выбор s6-архитектуры по `TARGETARCH`.
- Раздел «Команды» — добавить `tests/run.sh [image]` как способ проверки, отметить, что образ теперь собирается за минуты, и убрать утверждение «Тестов нет».

- [ ] **Step 3: Коммит**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document ARM support and the prebuilt-image build"
```

---

## Порядок и параллельность

Task 1–7 (тесты) и Task 8–9 (CI компонентов) независимы и могут идти параллельно: тесты пишутся и отлаживаются против текущего `:latest`-образа, пока компонентные сборки переезжают на buildx. Task 10 требует обеих веток разом. Task 11–13 строго после Task 10.
