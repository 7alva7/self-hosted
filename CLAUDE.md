# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

`self-hosted` — all-in-one Docker-образ Webtor (`ghcr.io/webtor-io/self-hosted`): 11 сервисов платформы + nginx + embedded PostgreSQL + Redis в одном контейнере под супервизором s6-overlay v3. **Собственного Go/JS-кода здесь нет** — репозиторий состоит из Dockerfile, s6-описаний сервисов и шаблонов конфигов. Ничего не компилируется: Dockerfile копирует готовые бинарники и ассеты из прекомпилированных образов компонентов, опубликованных CI каждого сервисного репозитория (`ghcr.io/webtor-io/<svc>`), закреплённых по тегу и дайджесту.

Общий контекст платформы (архитектура сервисов, matryoshka chaining и т.д.) — в `../CLAUDE.md`.

## Команды

```bash
# Сборка (быстрая: копирует готовые артефакты из образов компонентов; замеры на amd64:
# ~49s холодная, ~31s тёплая — против 40+ минут у старого компилирующего Dockerfile)
docker build -t webtor-self-hosted:assembly .
# Под конкретную архитектуру: docker build --platform linux/arm64 -t webtor-self-hosted:arm64 .

# Запуск и проверка
docker run -d -p 8080:8080 -v data:/data -v pgdata:/pgdata --name webtor webtor-self-hosted:assembly
curl http://localhost:8080
docker logs webtor        # логи всех сервисов с префиксами [service-name] через s6-log

# End-to-end смоук-сьют: boot, DDL, zip-архив, HLS (nginx-vod), транскодирование
# (session API content-transcoder), субтитры, персистентность после рестарта
tests/run.sh webtor-self-hosted:assembly
```

`tests/run.sh [image]` без аргумента по умолчанию тянет `ghcr.io/webtor-io/self-hosted:latest`. На момент написания этот тег ещё не содержит фикс подписи export-ссылок rest-api (`fix: sign rest-api export urls so torrent-http-proxy accepts them`), поэтому голый прогон падает на сценариях, завязанных на export (архив, HLS, субтитры). До выхода релиза с этим фиксом гонять сьют нужно на локально собранном образе — соберите его командой выше и передайте `tests/run.sh` явным аргументом.

**Релиз:** пуш тега `v*` запускает GitHub Actions (`.github/workflows/docker-image.yml`), который делегирует сборку и публикацию multi-arch-манифеста (amd64+arm64) переиспользуемому workflow `webtor-io/.github/.github/workflows/docker-multiarch.yml`. Все 12 компонентных репозиториев используют тот же workflow и публикуют свои образы под обе архитектуры. PR-гейт (`.github/workflows/test.yml`) собирает образ и гоняет `tests/run.sh` нативно на amd64- и arm64-раннерах; обе ноги обязательны.

Порт хоста для тестов задаётся `WEBTOR_HOST_PORT` (по умолчанию 8080) — пригодится, когда 8080 занят локальным дев-сервером: `WEBTOR_HOST_PORT=18080 tests/run.sh <image>`.

## Как обновить версию сервиса

Компоненты пинятся в Dockerfile по тегу и дайджесту: `FROM ghcr.io/webtor-io/<svc>:<tag>@sha256:<digest> AS <svc>`. Файлов `*.commit` в репозитории больше нет — provenance каждого компонента полностью описывается этой строкой в Dockerfile.

Штатный путь — Renovate (`renovate.json`): следит за `ghcr.io/webtor-io/**`, при появлении нового дайджеста под тем же тегом открывает отдельный PR на компонент (намеренно не групповой — так по упавшей смоук-джобе из `.github/workflows/test.yml` сразу видно, какой компонент виноват).

Ручной бамп — то же самое руками: узнать новый дайджест образа (например, `docker buildx imagetools inspect ghcr.io/webtor-io/<svc>:<tag>`) и заменить `@sha256:...` в соответствующей строке `FROM`. Тег (`master`/`main`, в зависимости от компонента — см. Dockerfile) обычно не трогают.

## Архитектура образа

### Сборка (Dockerfile)

Multi-stage, но ничего не компилируется. Каждый `FROM ghcr.io/webtor-io/<svc>:<tag>@sha256:<digest> AS <svc>` — это уже готовый образ, собранный CI соответствующего сервисного репозитория (тег и дайджест зафиксированы вместе, см. «Как обновить версию сервиса»). Финальный стейдж (`FROM alpine:${ALPINE_VER}`) вытаскивает артефакты через `COPY --from=<svc> <src> <dst>`:
- у большинства сервисов — один бинарник `/server` → `/app/<service>` (torrent-store, magnet2torrent, external-proxy, torrent-web-seeder, torrent-web-seeder-cleaner, torrent-archiver, srt2vtt, torrent-http-proxy, rest-api)
- `content-transcoder` — `/app/server` → `/app/content-transcoder`, плюс `/app/player` → `/app/player`
- `web-ui` — `/app/server` → `/app/web-ui`, плюс `templates/`, `pub/`, `migrations/`, `assets/dist`
- `nginx-vod` — весь `/usr/local/nginx` целиком (бинарник + уже вкомпилированные модули Kaltura `nginx-vod-module`/`nginx-secure-token-module`)

**Важно:** имя бинарника под `/app/<name>` должно совпадать с тем, что вызывает соответствующий s6 run-скрипт (`s6-overlay/s6-rc.d/<name>/run`) — это единственная связь между Dockerfile и рантаймом, и её легко разорвать при добавлении нового компонента.

s6-overlay качается двумя тарболами: noarch (общий для всех архитектур) и архитектурный, который выбирается по build-arg `TARGETARCH` (`amd64` → `x86_64`, `arm64` → `aarch64`; buildx подставляет `TARGETARCH` автоматически при мультиплатформенной сборке). На любой другой архитектуре стадия падает явной ошибкой (`unsupported TARGETARCH: ...`), а не тихо собирает нерабочий образ.

По результатам замера холодной сборки на amd64 при подготовке этой ветки: ~49 секунд, финальный образ ~218 МБ (раньше, когда Dockerfile компилировал ~11 Go-сервисов + npm-сборку + nginx из исходников, сборка занимала 40+ минут). Цифры приблизительные и не переизмерялись при каждой правке — ориентир по порядку величины, а не гарантия.

### Runtime (s6-overlay)

- `s6-overlay/s6-rc.d/<service>/` → копируется в `/etc/s6-overlay/`. Каждый сервис: `type` (longrun/oneshot), `run` (или `up`), `dependencies.d/`. **Новый сервис обязательно регистрировать в `s6-overlay/s6-rc.d/user/contents.d/<name>`**, иначе он не стартует.
- `cont-init.d/` → `/etc/cont-init.d/` — init-скрипты до старта сервисов: `00-wait-for-vpn` (ожидание Gluetun при `WAIT_FOR_VPN=true`), `01-generate-common-env` (envsubst шаблона env).
- Внимание: `s6-overlay/cont-init.d/00-wait-for-vpn` — **пустой файл-заглушка**; рабочая копия лежит в корневом `cont-init.d/`. Не редактировать пустышку.
- Dockerfile сам делает `chmod +x` на все `run`/`up` и файлы cont-init.d — права в git не критичны.

### Прокидывание конфигурации

Цепочка: `etc/webtor/common.template.env` --envsubst--> `/etc/webtor/common.env` → каждый `run`-скрипт делает `set -a; source common.env` и **переопределяет generic-переменные под себя** (все сервисы читают `WEB_PORT`, поэтому каждый run-скрипт ставит `WEB_PORT=$<SVC>_SERVICE_PORT` перед запуском своего бинарника). При добавлении переменной окружения: добавить её в `common.template.env` (с `${VAR:-default}` для проброса снаружи) и задокументировать в README.

Сервисы находят друг друга через переменные `<SVC>_SERVICE_HOST/PORT` (все на 127.0.0.1) — тот же механизм, что K8s-сервисы в проде. `etc/webtor/torrent-http-proxy/config.yaml` мапит matryoshka-имена (`hls`, `vod`, `arch`, `vtt`, `ext`) на сервисы через `endpointsProvider: Environment`.

Карта портов: 8080 nginx (вход), 8090–8098 HTTP-сервисы, 50051/50052 gRPC (torrent-store, magnet2torrent), 6379 Redis, 5432 PostgreSQL.

### Маршрутизация (etc/nginx/conf/nginx.template.conf)

Nginx — единственная входная точка (8080): `/` → web-ui, `/torrent-http-proxy/` → torrent-http-proxy. Второй server-блок на 8098 — nginx-vod (`vod_mode remote`, upstream — torrent-http-proxy) для HLS/DASH-упаковки. Шаблон рендерится envsubst'ом в run-скрипте nginx-vod с **явным списком переменных** — новую переменную в шаблоне нужно добавить и в этот список, иначе она заменится пустотой.

**`/rest-api/` намеренно не проксируется наружу** — у rest-api нет собственной авторизации, и публичный доступ к нему позволял бы сохранить торрент и получить подписанные ссылки на контент в обход web-ui. Сервис `rest-api` продолжает работать внутри контейнера (на `REST_API_SERVICE_HOST/PORT`, см. `common.template.env`) — к нему обращается только web-ui через свой `/api/v1`, который требует API-ключ (`Authorization: Bearer <key>`, выпускается на странице профиля). Пути `/api/v1` зеркалят старые `/rest-api/` один в один (`POST /resource`, `GET /resource/<id>`, `.../list`, `.../export/<id>`) и отдают тот же JSON — сменился только префикс и требование авторизации. Смоук-сьют (`tests/lib.sh`, хелперы `api_key`/`apiv1`) переведён на этот путь; `00-boot.sh` держит регресс-проверку, что `/rest-api/` не отвечает 2xx снаружи.

### Oneshot-секреты

`generate-api-key-and-secret` (oneshot, скрипт в `s6-overlay/scripts/`) генерирует или принимает `API_KEY`/`API_SECRET` и пишет в `/etc/webtor/secrets/api.env`; web-ui зависит от него через `dependencies.d/`.

`generate-session-secret` (тот же паттерн) генерирует или принимает `SESSION_SECRET` и пишет в `/etc/webtor/secrets/session.env`; web-ui run-скрипт сорсит его после `api.env`. web-ui в коде дефолтит `SESSION_SECRET` на публичную константу (`secret123`, см. `services/common/common.go`) — этот oneshot гарантирует, что self-hosted её никогда не использует, и что значение переживает рестарт контейнера (иначе рестарт разлогинивал бы администратора).

### PostgreSQL

Embedded-инстанс (`s6-rc.d/postgres/run`): initdb при первом старте в `/pgdata`, фоновый инициализатор создаёт роль/базу `app`. `USE_LOCALPG=false` отключает его полностью (сервисы идут на внешний `PG_HOST`). Миграции схемы применяет web-ui из своих `migrations/`.

## Env-переменные пользователя

Все пользовательские настройки (DOMAIN, CLEANER_*, PG_*, DISABLE_*, OMDB_API_KEY, ADMIN_PASSWORD, ONLY_AUTHORIZED и др.) задокументированы в README.md — при добавлении новой обновлять его.

`ADMIN_PASSWORD` (пусто по умолчанию) — пароль администратора. Без него инстанс полностью открыт: любой, кто может достучаться до контейнера, имеет полный доступ без авторизации. Переменная имеет приоритет над паролем, сохранённым через профиль (см. также восстановление доступа: `docker exec webtor sh -c 'set -a; . /etc/webtor/common.env; cd /app && ./web-ui admin set-password <new-password>'` — команда должна сама сорсить `/etc/webtor/common.env`, иначе `web-ui` подключится к Postgres с дефолтами common-services (`PG_USER=webhook`/`PG_DATABASE=webhook`) вместо `app`/`app`; подробности в README).

`ONLY_AUTHORIZED` (по умолчанию `true`) — фича web-ui, закрывает весь веб-интерфейс авторизацией: без валидной сессии запрос на любую страницу редиректит на `/login`, а не отдаёт контент на чтение. self-hosted включает её по умолчанию, в отличие от исторически открытого поведения — `ONLY_AUTHORIZED=false` возвращает старое поведение (страницы доступны без логина, паролем защищены только уже защищённые ранее действия).
