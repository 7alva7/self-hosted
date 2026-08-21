# Vault in the self-hosted image — design

**Status:** approved for planning
**Date:** 2026-08-21

## Goal

Add the `vault` service to the all-in-one image so a self-hoster can keep a
torrent permanently: the content is copied out of the ephemeral peer-to-peer
path into the embedded S3 store and served from there, whether or not the
swarm still has seeders.

The embedded S3 sub-project already created the `vault` bucket for exactly
this. Nothing reads it today.

## What already exists — do not rebuild it

Four things that look like work but are not:

- **The database schema for pledges.** web-ui migrations 24–26 create
  `vault.pledge`, `vault.user_vp`, `vault.tx_log`, `vault.resource`. They are
  applied by every self-hosted instance today.
- **Unlimited storage quota.** Vault Points ration a shared disk on
  webtor.io. A self-hoster owns their disk, so they get no quota — and that
  is already the behaviour: `UpdateUserVP` leaves `UserVP.Total` nil when
  claims carry no `Vault.Points`, and the pledge path reads
  `if userVP.Total == nil { /* Unlimited VP */ }`. Self-hosted has no
  claims-provider, so `makeAdminClaims()` returns claims with no `Vault`
  field, and users are already unlimited. **No web-ui change for quota.**
- **The cron mechanism.** `run-cron-job` already sources the service
  environment and skips jobs whose optional configuration is absent. Adding
  the two vault jobs is two crontab lines.
- **Probe/pprof/metrics port collisions.** Every webtor service defaults
  `PROBE_PORT=8081`, `PPROF_PORT=8082`, `PROM_PORT=8083` with the `USE_*`
  flags on. `common.template.env` disables all three globally, so vault
  inherits that and collides with nothing.

## Hazards found while designing

Each of these produces a wrong state that looks healthy, which is the failure
shape this repo keeps hitting. They are constraints, not suggestions.

### 1. Vault's migrations must not see web-ui's

`common-services` discovers migrations with
`DiscoverSQLMigrations("migrations")` — a path relative to the working
directory. web-ui's 69 migrations are at `/app/migrations`, and every run
script does `cd /app`. A vault process started there would discover web-ui's
migrations and apply them to vault's database.

**Therefore:** vault gets its own working directory, `/app/vault/`, holding
the binary and its `migrations/`. Its run script does `cd /app/vault`.

This departs from the repo's one-binary-per-`/app/<name>` convention, which
`CLAUDE.md` calls the only link between Dockerfile and runtime. Document the
exception where that convention is stated.

### 2. Vault needs its own database

`go-pg/migrations` records the schema version in a single table,
`gopg_migrations`, per database. web-ui is at version 69; vault is at 8. In a
shared database whichever runs second misreads the other's version — vault
would conclude its migrations are applied and create no tables at all.

**Therefore:** a second database, `vault`, created by the same background
initializer in `s6-rc.d/postgres/run` that creates `app`, owned by the same
role. With `USE_LOCALPG=false` the operator creates it; say so in the README
and fail with a message that names the missing database.

### 3. Adding NATS can crash-loop web-ui

Vault publishes `resource.vaulted` when a transfer completes. web-ui consumes
it, sets `vault.resource.vaulted = true`, and emails everyone who pledged.
Without NATS neither happens — the resource shows as transferring forever.
So NATS is required, not optional.

But both services subscribe with `nats.Bind(stream, consumer)`, which
requires the stream **and the durable consumer** to already exist. And
web-ui's event handler joins the main serve group
(`servers = append(servers, eh)`), so a failed `PullSubscribe` returns an
error from `Serve()` and takes web-ui down with it.

Today web-ui never reaches that code, because `cs.NewNATS` returns nil with
no `NATS_SERVICE_HOST` and `event.New` is never called. **Introducing NATS
makes a currently-healthy service depend on correct JetStream
provisioning.** Provisioning must therefore be a hard dependency of both
consumers, and must fail loudly on its own rather than let web-ui loop.

### 4. Anything under `$STORAGE_DIR` becomes an S3 bucket

versitygw's posix backend returns whatever directories exist in the storage
root from `ListBuckets`. JetStream state, scratch files, or any other
directory placed there would appear as a bucket. Nothing but buckets goes in
`/storage`.

## Prerequisite: vault must publish for arm64

`ghcr.io/webtor-io/vault` is a single-platform amd64 manifest. Its CI was
never migrated to the shared `webtor-io/.github/.github/workflows/docker-multiarch.yml`
that the twelve other component repos use. The self-hosted image is
multi-arch, so an arm64 build would fail — or silently assemble an
unrunnable binary — at that stage.

Migrating vault's `.github/workflows/docker-image.yml` to the shared
workflow, and confirming the published manifest is an index carrying
`linux/amd64` and `linux/arm64`, is the first task and lives in the `vault`
repository, not this one.

## Components added to the image

Three new Dockerfile stages, all pinned by tag and digest:

| Stage | Source | What is copied |
|---|---|---|
| `vault` | `ghcr.io/webtor-io/vault` | `/server` → `/app/vault/vault`, `/migrations` → `/app/vault/migrations` |
| `nats` | `nats:alpine` | `/usr/local/bin/nats-server` → `/app/nats-server` |
| `natsbox` | `natsio/nats-box` | `/usr/local/bin/nats` → `/app/nats` (provisioning only) |

Both NATS images publish `linux/amd64` and `linux/arm64`. Neither is a webtor
component, so — like `versitygw` — Renovate does not watch them
(`renovate.json` matches `ghcr.io/webtor-io/**`) and bumps are manual. Add
them to the same note in `CLAUDE.md` that already carries this caveat for
versitygw.

Measured cost of the two NATS binaries: `nats-server` is 16.7 MB and the
`nats` CLI is 34.0 MB, so roughly 50 MB on top of an image whose content
size is about 236 MB. The CLI is the larger half and exists only to run the
provisioning oneshot at boot. It is still the cheapest option available:
both subscribers bind to durable consumers that must already exist, and
nothing in an Alpine base can create them.

Three new s6 services and one oneshot:

- **`nats`** (longrun) — runs `/app/nats-server` with JetStream enabled,
  memory storage, bound to `127.0.0.1:4222`. Not published, not proxied.
  Note the exception to this repo's naming rule: the service is `nats` but
  the binary is `nats-server`, because `/app/nats` is the CLI. Both names
  are load-bearing; do not "fix" either to match the other.
- **`nats-provision`** (oneshot) — creates the stream and the four consumers
  with `/app/nats`. Idempotent. `vault` and `web-ui` both depend on it.
- **`vault`** (longrun) — `cd /app/vault && ./vault serve`.

### JetStream storage is in memory

The stream carries a 24-hour retention and, in this image, one live subject.
Publisher and consumer are both inside the same container, so the delivery
window is milliseconds. NATS is a separate s6 service, so it survives
restarts of web-ui and vault; only a full container restart can drop an
event that has been published but not yet consumed.

Memory storage keeps the operator's `docker run` line unchanged, which
matters because the S3 sub-project just added a third volume to it. File
storage would need a home, and none is available: `/storage` turns
directories into buckets (hazard 4), `/data` is swept by the autocleaner,
and `/pgdata` is the database's.

### What must be provisioned

Stream `common`: subjects `user.*` and `resource.*`, memory storage, max age
24h, one replica.

Four durable consumers, all on stream `common`, `deliverPolicy: all`,
`ackPolicy: explicit`, `ackWait: 30s`:

| Durable name | Filter subject |
|---|---|
| `web-ui-resource-vaulted` | `resource.vaulted` |
| `web-ui-resource-banned` | `resource.banned` |
| `web-ui-user-updated` | `user.updated` |
| `vault-resource-banned` | `resource.banned` |

Only `resource.vaulted` carries traffic in this image. `user.updated` is
published by the `webhook` service and `resource.banned` by the abuse
pipeline; neither ships here. All four consumers must exist anyway, because
each subscriber binds to its own and errors if it is missing.

## Configuration

Vault's environment variable names match the ones this image already uses —
`PG_DATABASE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT`,
`AWS_REGION`, `AWS_NO_SSL`. The service's own README is stale and lists
`PG_DB` and `S3_*`; the code is what matters here.

New entries in `etc/webtor/common.template.env`, all in `${VAR:-default}`
form:

```
USE_VAULT=${USE_VAULT:-true}
VAULT_SERVICE_HOST=127.0.0.1
VAULT_SERVICE_PORT=8100
VAULT_PG_DATABASE=${VAULT_PG_DATABASE:-vault}
VAULT_AWS_BUCKET=${VAULT_AWS_BUCKET:-vault}
NATS_SERVICE_HOST=127.0.0.1
NATS_SERVICE_PORT=4222
```

Port 8100 continues the map; 8090–8099 are taken. `VAULT_SERVICE_HOST/PORT`
and `NATS_SERVICE_HOST/PORT` are fixed at loopback like every other internal
service.

The vault run script follows the established pattern of overriding generic
names for itself: `WEB_PORT=$VAULT_SERVICE_PORT`,
`PG_DATABASE=$VAULT_PG_DATABASE`, `AWS_BUCKET=$VAULT_AWS_BUCKET`. It sources
`/etc/webtor/secrets/api.env` for `WEBTOR_API_KEY`/`WEBTOR_API_SECRET` and
`/etc/webtor/secrets/s3.env` for the S3 credentials, and reaches rest-api
over the existing `REST_API_SERVICE_HOST`/`PORT`.

It also sets `USE_INTERNAL_TORRENT_HTTP_PROXY=true`. rest-api builds export
URLs from `DOMAIN`, which names how the instance is reached from outside — a
published host port, or a public hostname that does not resolve inside the
container. That flag makes vault rewrite the host of every content URL to the
in-container proxy before fetching. Without it the worker fetches from an
address that does not exist in here, nothing is ever stored, and the service
itself looks healthy throughout.

Left unset deliberately: `S3_CACHE_URL` (a production DaemonSet),
`VAULT_VERIFY_*` (a manual ops command), `RESOURCE_ID` (a debug knob).

## USE_VAULT=false

Turning the store off is a supported mode, so it has to be coherent
everywhere:

- the `vault` service logs the reason and idles with `exec sleep infinity`,
  the same shape `s3/run` uses, so s6 does not restart it forever;
- web-ui must see an empty `VAULT_SERVICE_HOST`, because that is what its
  degradation keys off — `vault.NewApi` returns nil, `/vault` routes are not
  registered, per-page CTAs and the onboarding step disappear. The template
  sets `VAULT_SERVICE_HOST=127.0.0.1` unconditionally and envsubst has no
  conditionals, so **web-ui's run script must blank it** when `USE_VAULT` is
  false, the same way run scripts already override generic names for
  themselves. Hardcoding the host and stopping there would leave web-ui
  pointed at a service that is sleeping: the menu would render and every
  vault page would fail against a dead endpoint instead of degrading;
- the two vault cron jobs skip;
- NATS still runs — web-ui's other two consumers are unaffected by vault.

### The navbar link must be gated

`templates/partials/nav.html` renders the Vault link unconditionally inside
`{{ if .User | hasAuth }}`, in both the desktop bar and the mobile burger,
while `/vault` routes are registered only when vault exists. Today, in every
self-hosted instance, that link is a 404.

Adding vault fixes it by accident for the default configuration — and
re-creates it precisely for the operators who set `USE_VAULT=false`, a mode
this design introduces. So the gate is in scope: a `Vault` field on
`services/web/context.go`'s `Context`, set from `vaultApi != nil`, and a
guard around both link sites. This is a change in the `web-ui` repository.

## Cron jobs

Two lines in `etc/webtor/cron/crontab`, and the comment saying `vault reap`
is deliberately absent comes out:

| Schedule | Command | Owner |
|---|---|---|
| hourly | `web-ui vault reap` | web-ui — expires pledges and resources against its own tables |
| daily 04:00 | `vault gc` | vault — sweeps files with no `resource_file` reference from S3 and its database |

Both mirror the production schedules. `vault gc` hard-fails without database
and S3 configuration rather than degrading, which is correct for a cron job:
the wrapper reports a non-zero status.

## Testing

A smoke scenario, `tests/scenarios/80-vault.sh`, asserting behaviour rather
than log lines:

- the `vault` database exists and carries vault's own tables — `resource`,
  `file`, `resource_file` — and **not** web-ui's, which is the observable
  consequence of hazards 1 and 2;
- the service answers on `127.0.0.1:8100`;
- the stream and all four consumers exist;
- a resource saved through web-ui reaches `/storage/vault`, and web-ui's
  `vault.resource.vaulted` flips to true — that last assertion is the one
  that proves the NATS path end to end, and it is the reason NATS is here;
- with `USE_VAULT=false` the service idles, `/vault` is not registered — web-ui
  answers it the way it answers any nonexistent path, a 302 to the error page
  rather than a bare 404 — and web-ui stays healthy.

Each guard added by this work needs a negative control: remove the guard,
watch the test go red. The provisioning oneshot in particular — a scenario
that passes with the consumers missing would be worthless, because that is
the exact state that crash-loops web-ui.

## Out of scope

- `vault verify-existing` — a manual operations command, unscheduled even in
  production.
- The `s3-cache` redirect path.
- Any payment or tier integration. Quota is unlimited by construction.
- Publishing `user.updated` or `resource.banned`. Their consumers exist so
  subscribers can bind; nothing in this image produces those events.
