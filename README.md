# Webtor, self-hosted

This is the self-hosted version of [webtor.io](https://webtor.io), implemented as an all-in-one Docker image.

## Features

- **Direct Download Link (DDL):** Select any file inside a torrent and download it directly.
- **Instant Video and Audio Streaming:** Choose a video or audio file inside a torrent and start streaming immediately without needing to download it first.  
  **Supported Formats:**
   - **Video:** `avi`, `mkv`, `mp4`, `webm`, `m4v`, `ts`, `vob`
   - **Audio:** `mp3`, `wav`, `ogg`, `flac`, `m4a`
- **Download Entire Torrent as a ZIP Archive:** Download your torrent as a ZIP archive on-the-fly while preserving the original directory structure, without requiring a torrent client.
- **Personal Library:** Organize your own collection by adding torrents to your account. Movies and series will be detected automatically!
- **Stremio integration** Just install the addon using the link from profile and start watching your library on TV with Stremio.
- **Developer-friendly** With the [SDK](https://github.com/webtor-io/embed-sdk-js) you can provide your users with the ability to watch torrent-videos online on your website.

## Quick Setup

1. [Install Docker](https://docs.docker.com/get-docker/).
2. Start your Webtor instance with the following command:
   ```bash
   docker run -d -p 8080:8080 -v data:/data -v pgdata:/pgdata --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
   ```
3. Access the UI at <http://localhost:8080>.
4. You're all set!

You can run your Webtor instance on [ElfHosted](https://store.elfhosted.com/product/webtor/elf/10433/)!

## Supported Platforms

The image is published for `linux/amd64` and `linux/arm64`, so it runs on x86
servers as well as Apple Silicon, 64-bit ARM boards and ARM NAS devices. Docker
picks the right variant automatically — the command above is the same on every
platform. 32-bit ARM (`armv7`) is not supported.

## Administrator Password

By default the instance is open: anyone who can reach it has full access. Set a
password from the profile page, or start the container with one:

```bash
docker run -e ADMIN_PASSWORD=your-password -d -p 8080:8080 -v data:/data -v pgdata:/pgdata \
  --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
```

`ADMIN_PASSWORD` overrides whatever password was set from the profile, which
also makes it the way back in if you forget it. To change the password without
putting it on the command line, source the environment the container's own
services run with first — `web-ui` isn't started under it by `docker exec`,
so a bare invocation connects to Postgres with the wrong defaults
(`PG_USER=webhook`, `PG_DATABASE=webhook`, no password) instead of the
`app`/`app` role the embedded database actually created:

```bash
docker exec webtor sh -c 'set -a; . /etc/webtor/common.env; cd /app && ./web-ui admin set-password <new-password>'
```

Once a password is set, the web interface requires authentication for every
page (`ONLY_AUTHORIZED=true`, the default) — a visitor without a valid session
is redirected to `/login` instead of getting read access. Set
`ONLY_AUTHORIZED=false` to turn that off and fall back to the old behavior:
pages stay reachable without logging in, and only actions that were already
password-gated (e.g. changing settings) still prompt for one.

## API Access

The REST API (`rest-api`) is not exposed publicly — nginx no longer proxies
`/rest-api/`. It still runs inside the container, but only web-ui's own
`/api/v1` can reach it, and `/api/v1` requires an API key.

To get a key: open the profile page in a browser (this requires being logged
in if `ADMIN_PASSWORD`/`ONLY_AUTHORIZED` are in effect) and generate an API
credential there. Then call `/api/v1` with it:

```bash
curl -H "Authorization: Bearer <your-api-key>" http://localhost:8080/api/v1/resource/<id>
```

`/api/v1` mirrors the old `/rest-api/` paths one for one (e.g.
`POST /resource`, `GET /resource/<id>`, `GET /resource/<id>/list`,
`GET /resource/<id>/export/<content_id>`) and returns the same response
shapes; only the host path prefix and the authentication requirement changed.

## Setting a Custom Domain

If you plan to access your instance from a different host or domain, set the `DOMAIN` environment variable like this:

```bash
docker run -e DOMAIN=https://example.com -d -p 8080:8080 -v data:/data -v pgdata:/pgdata --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
```

## Setting Custom Port

```bash
docker run -e DOMAIN=http://localhost:8085 -d -p 8085:8080 -v data:/data -v pgdata:/pgdata --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
```

## Configuring the Autocleaner

Webtor automatically cleans old data when there is insufficient space on the device. You can configure this behavior using the following variables:

```bash
CLEANER_FREE=35%
CLEANER_KEEP_FREE=25%
```

- `CLEANER_FREE` specifies how much space to clean when triggered.
- `CLEANER_KEEP_FREE` sets the threshold at which cleaning starts.

Both variables can be defined as percentages or as byte values (e.g., `10G` or `100M`).

## Configuring Database

By default Webtor uses an embedded PostgreSQL database. You can configure the database connection using the following environment variables:

- **USE_LOCALPG** - use built-in postgres (default: true)
- **PG_HOST** - host for postgres (default: localhost)
- **PG_PORT** - port for postgres (default: 5432)
- **PG_USER** - user for postgres (default: app)
- **PG_PASSWORD** - password for postgres (default: app)
- **PG_DATABASE** - database for postgres (default: app)

## Configuring content enrichment

- **OMDB_API_KEY** - key for OMDB API
- **KINOPOISK_UNOFFICIAL_API_KEY** - key for KinoPoisk Unofficial API

## Configring Stremio Addon Access

- **STREMIO_ADDON_USER_AGENT** - user agent to use for stremio addon
- **STREMIO_ADDON_PROXY** - proxy to use for stremio addon (like socks5://user:pass@host:port)

## Configuring Transcoding

- **DISABLE_VIDEO_TRANSCODING** - disables video transcoding (default: false)

## Disable UI Features

- **DISABLE_WEBDAV** - disables WebDAV interface (default: false)
- **DISABLE_EMBED** - disables embeds support (default: false)

## Other Custom Variables

- **WAIT_FOR_VPN** - waits for VPN to start (in case you are using Gluetun) (default: false)
- **REQUEST_URL_MAPPINGS** - custom mappings for request urls
