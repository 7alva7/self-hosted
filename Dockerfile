ARG ALPINE_VER="3.22"
ARG S6_OVERLAY_VER="3.2.0.2"
ARG S6_VERBOSITY=1

# Component images are pinned by tag AND digest so Renovate can bump them
# one at a time and each component's provenance is fully reproducible.
# Nothing is compiled here any more. The Alpine base below and its apk
# packages are NOT pinned to a digest and will float to whatever `apk add`
# resolves at build time.
FROM ghcr.io/webtor-io/torrent-store:master@sha256:d1fca505c913e20536726e7a079dcb2350abdabf86fd20b8200cbc022cd2d260 AS torrent-store
FROM ghcr.io/webtor-io/magnet2torrent:master@sha256:2b3ea8452ccc080015637efd2878e2666712e013a38d5cada1ec33f392c381b3 AS magnet2torrent
FROM ghcr.io/webtor-io/external-proxy:master@sha256:04a3307b026601a3d0e32a28ca6bc2823752fb0866f518120bc4e5b7526aebed AS external-proxy
FROM ghcr.io/webtor-io/torrent-web-seeder:master@sha256:ca3f8bb2677116dfcd49307379d9f2cb4a70001e1051a10e698f1422fbd46a51 AS torrent-web-seeder
FROM ghcr.io/webtor-io/torrent-web-seeder-cleaner:main@sha256:f8f3216c1266990d83d659cadd4b80784cc78fe330668c9bfd9186dfebe03612 AS torrent-web-seeder-cleaner
FROM ghcr.io/webtor-io/content-transcoder:master@sha256:dcdb70757cdb787bb10d439880a6749ae936da7462fb53bcc45b11791332cbeb AS content-transcoder
FROM ghcr.io/webtor-io/torrent-archiver:master@sha256:89d4aa17cb9f1cda31fe45b07ad9f245867d23326c867a749d7b06b16075d9e7 AS torrent-archiver
FROM ghcr.io/webtor-io/srt2vtt:master@sha256:f6f9079609fd5ff725545bafedee9df4b8c1c803f2b829435fee28e24648dac1 AS srt2vtt
FROM ghcr.io/webtor-io/torrent-http-proxy:master@sha256:3610ea561c91dacb5bc64dcd9d39ac9cd118edc7f0336e0d9872b93e70623666 AS torrent-http-proxy
FROM ghcr.io/webtor-io/rest-api:main@sha256:5eb1f291233c67641463a464094befd84b4fc2f8e8f989eeadbc58f6a808eae2 AS rest-api
FROM ghcr.io/webtor-io/web-ui:main@sha256:ac51803286cea36036559ec9a930eaf24b6269c83537818d56f6604a9616ca13 AS web-ui
FROM ghcr.io/webtor-io/nginx-vod:main@sha256:fa680395abe41a2a367cc44ddfb15fb9670a9e3f0d87ab8d0701d4e528019389 AS nginx-vod

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
