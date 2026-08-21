ARG ALPINE_VER="3.22"
ARG S6_OVERLAY_VER="3.2.0.2"
ARG S6_VERBOSITY=1

# Component images are pinned by tag AND digest so Renovate can bump them
# one at a time and each component's provenance is fully reproducible.
# Nothing is compiled here any more. The Alpine base below and its apk
# packages are NOT pinned to a digest and will float to whatever `apk add`
# resolves at build time.
FROM ghcr.io/webtor-io/torrent-store:master@sha256:2b584aa61b6f596e5fff9bc81745dc3a4a4f1b7b618139c3acac09ecfe1f05f3 AS torrent-store
FROM ghcr.io/webtor-io/magnet2torrent:master@sha256:c28c6c94f6d976b831fca3a2632371bec61463f7062e7d75cf7f3091f8c64bb5 AS magnet2torrent
FROM ghcr.io/webtor-io/external-proxy:master@sha256:a7a267df98865d1e9e3c27cd47053db9ff9ed4b6b5e93fbf9a69d343d0c97c0f AS external-proxy
FROM ghcr.io/webtor-io/torrent-web-seeder:master@sha256:50efc749fe9c55be9a6fa7082e9ad73958e6ac08ec5447136fe086fa059ddc88 AS torrent-web-seeder
FROM ghcr.io/webtor-io/torrent-web-seeder-cleaner:main@sha256:84ffc9c054094b3c2a077b8247dc74e3ae75b7ca965b473a8ada92143e1fdba0 AS torrent-web-seeder-cleaner
FROM ghcr.io/webtor-io/content-transcoder:master@sha256:98a3e5ea8171fd712b264c63e1d6a74c5950ff9a4a905888bd63f3235ef0411a AS content-transcoder
FROM ghcr.io/webtor-io/torrent-archiver:master@sha256:d1c158eda4d39242f84981a895eece2218c14e51916f81e27d991fbbd90c7364 AS torrent-archiver
FROM ghcr.io/webtor-io/srt2vtt:master@sha256:a78915ff19ac490253e0cba8c7b01b4c73a7e961e58120315caa7f58c14a2bbb AS srt2vtt
FROM ghcr.io/webtor-io/torrent-http-proxy:master@sha256:66826afad417782cfffc1d91a60c5fde47cae048083a274f968e468d0f1d66ab AS torrent-http-proxy
FROM ghcr.io/webtor-io/rest-api:main@sha256:b626a44bf6706db929b7321f86d9126abc30f76a7b39b5187de2855fe35aee99 AS rest-api
FROM ghcr.io/webtor-io/web-ui:main@sha256:eb264afdd6b91fe632b77f3ec4b13da9b7abdb5a3a7725004e8622df78219aff AS web-ui
FROM ghcr.io/webtor-io/nginx-vod:main@sha256:4d9aaa6ac3dc2e3e73bdf8afd47d4ffab0a932f22b91a4c8cdd7674290bd89dd AS nginx-vod

# Not a webtor component: the S3 gateway backing /storage. Apache 2.0, one
# static binary, and its posix backend keeps objects as ordinary files so a
# self-hoster can read their own data without this program. Pinned like every
# other stage; Renovate does not watch it (renovate.json matches
# ghcr.io/webtor-io/**), so bumps here are deliberate and manual.
FROM ghcr.io/versity/versitygw:latest@sha256:c4cbd9d9cb8dedbb055ac788dbd02635651b9b1cebac95b095b3217231aa87ad AS versitygw

FROM alpine:${ALPINE_VER}

ARG S6_OVERLAY_VER
ARG S6_VERBOSITY
ARG TARGETARCH
ENV S6_VERBOSITY=$S6_VERBOSITY

LABEL org.opencontainers.image.source="https://github.com/webtor-io/self-hosted"

RUN apk --no-cache add redis ffmpeg ca-certificates openssl pcre zlib envsubst uuidgen \
    postgresql postgresql-client postgresql-contrib curl attr

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
COPY --from=versitygw /usr/local/bin/versitygw ./versitygw
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
