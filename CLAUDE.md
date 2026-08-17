# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

`self-hosted` — all-in-one Docker-образ Webtor (`ghcr.io/webtor-io/self-hosted`): 11 сервисов платформы + nginx + embedded PostgreSQL + Redis в одном контейнере под супервизором s6-overlay v3. **Собственного Go/JS-кода здесь нет** — репозиторий состоит из Dockerfile, s6-описаний сервисов и шаблонов конфигов. Исходники сервисов клонируются из GitHub на этапе сборки по закреплённым коммитам.

Общий контекст платформы (архитектура сервисов, matryoshka chaining и т.д.) — в `../CLAUDE.md`.

## Команды

```bash
# Сборка (долгая: клонирует и собирает ~11 Go-сервисов + npm build + компиляция nginx)
docker build -t webtor-self-hosted .

# Запуск и проверка
docker run -d -p 8080:8080 -v data:/data -v pgdata:/pgdata --name webtor webtor-self-hosted
curl http://localhost:8080
docker logs webtor        # логи всех сервисов с префиксами [service-name] через s6-log
```

Тестов нет — верификация только через сборку образа и живой запуск.

**Релиз:** пуш тега `v*` запускает GitHub Actions (`.github/workflows/docker-image.yml`) → сборка и публикация в GHCR с semver-тегами.

## Как обновить версию сервиса

Единственная рутинная операция в этом репо: поменять `ARG <SERVICE>_COMMIT` в шапке Dockerfile на нужный SHA из соответствующего репозитория webtor-io. Конвенция коммитов: `update web-ui dependency`, `update deps` и т.п.

Особые случаи чекаута: `magnet2torrent` и `torrent-web-seeder` собираются из подкаталога `server/` своего репо.

## Архитектура образа

### Сборка (Dockerfile)

Multi-stage: по одному `build-<service>` stage на сервис (git clone → checkout SHA → `go build` static). Отдельно:
- `build-web-ui-assets` — npm-сборка фронтенда из склонированного web-ui; в финальный образ попадают `templates/`, `pub/`, `migrations/`, `assets/dist`
- `build-nginx-vod` — nginx компилируется из исходников с модулями Kaltura `nginx-vod-module` и `nginx-secure-token-module`

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

Nginx — единственная входная точка (8080): `/` → web-ui, `/rest-api/` → rest-api, `/torrent-http-proxy/` → torrent-http-proxy. Второй server-блок на 8098 — nginx-vod (`vod_mode remote`, upstream — torrent-http-proxy) для HLS/DASH-упаковки. Шаблон рендерится envsubst'ом в run-скрипте nginx-vod с **явным списком переменных** — новую переменную в шаблоне нужно добавить и в этот список, иначе она заменится пустотой.

### Oneshot-секреты

`generate-api-key-and-secret` (oneshot, скрипт в `s6-overlay/scripts/`) генерирует или принимает `API_KEY`/`API_SECRET` и пишет в `/etc/webtor/secrets/api.env`; web-ui зависит от него через `dependencies.d/`.

### PostgreSQL

Embedded-инстанс (`s6-rc.d/postgres/run`): initdb при первом старте в `/pgdata`, фоновый инициализатор создаёт роль/базу `app`. `USE_LOCALPG=false` отключает его полностью (сервисы идут на внешний `PG_HOST`). Миграции схемы применяет web-ui из своих `migrations/`.

## Env-переменные пользователя

Все пользовательские настройки (DOMAIN, CLEANER_*, PG_*, DISABLE_*, OMDB_API_KEY и др.) задокументированы в README.md — при добавлении новой обновлять его.
