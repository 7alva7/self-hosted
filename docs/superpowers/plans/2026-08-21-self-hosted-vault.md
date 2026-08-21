# Vault in the self-hosted image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `vault` service to the all-in-one image so a self-hoster can keep a torrent permanently, served from the embedded S3 store whether or not the swarm still has seeders.

**Architecture:** Three new Dockerfile stages (vault, nats-server, nats CLI) assembled into the existing s6-overlay runtime. Vault runs from its own working directory with its own database, because its migration discovery and version tracking would otherwise collide with web-ui's. NATS carries one event — vault telling web-ui a transfer finished — and its stream and durable consumers are provisioned by a oneshot that both subscribers depend on.

**Tech Stack:** Docker multi-stage assembly, s6-overlay v3, NATS JetStream (memory storage), embedded PostgreSQL, versitygw (embedded S3), bash smoke suite.

**Spec:** `docs/superpowers/specs/2026-08-21-self-hosted-vault-design.md`

## Global Constraints

- Every variable added to `etc/webtor/common.template.env` uses the `${VAR:-default}` form, so `docker run -e` can override it. Exception, matching every other internal service: `*_SERVICE_HOST`/`*_SERVICE_PORT` are fixed at loopback and are deliberately **not** overridable.
- Every new s6 service is registered by an empty file at `s6-overlay/s6-rc.d/user/contents.d/<name>`, or it silently never starts.
- The binary name under `/app/<name>` matches what the s6 run script invokes. **One documented exception in this plan:** the service `nats` runs `/app/nats-server`, because `/app/nats` is the CLI.
- Secrets must never reach `docker logs`. The README tells users to read them.
- NATS binds `127.0.0.1:4222` only: not published, not proxied by nginx.
- Vault binds `127.0.0.1:8100` only: not published, not proxied by nginx.
- External S3 (`USE_LOCALS3=false`) and external PostgreSQL (`USE_LOCALPG=false`) must both keep working.
- **Backward compatibility:** an existing user upgrading with their saved `docker run -v data:/data -v pgdata:/pgdata -v storage:/storage` must get a working container. No new volume.
- Nothing but buckets goes under `$STORAGE_DIR` — versitygw's posix backend returns every directory there from `ListBuckets`.
- Vault must never discover web-ui's migrations, and must never share web-ui's database.
- `USE_VAULT=false` is a supported mode and must be coherent: service idle, web-ui degraded (not broken), crons skipped, navbar link absent.

## Build caveat (applies to every task that builds an image)

The `web-ui` stage in `Dockerfile` pins a published ghcr image that lacks changes this branch depends on. To build a testable image, temporarily repoint that one `FROM` at the locally built image `web-ui:cron`, and **restore it before committing**. Verify with `git diff -- Dockerfile` that no Dockerfile change to the web-ui pin is in the commit.

After Task 6 changes web-ui, rebuild that local image from the web-ui repo (`docker build -t web-ui:cron .`) so later tasks test against the navbar gate.

## Verification standard (applies to every task)

An assertion about a result must be a consequence of a check, not text printed beside one. `cmd; echo ok` prints ok regardless. Every guard added here gets a negative control: remove the guard, confirm the check goes red, restore it. Name explicitly anything left unverified — silence reads as "checked".

---

## File Structure

**self-hosted repo**

| File | Responsibility |
|---|---|
| `Dockerfile` | three new pinned stages; copies vault to `/app/vault/`, `nats-server` and `nats` to `/app/` |
| `etc/webtor/common.template.env` | `USE_VAULT`, `VAULT_*`, `NATS_SERVICE_*` |
| `s6-overlay/s6-rc.d/postgres/run` | also creates the `vault` database |
| `s6-overlay/s6-rc.d/nats/{run,type,dependencies.d/base}` | NATS server longrun |
| `s6-overlay/s6-rc.d/nats-provision/{up,type,dependencies.d/{base,nats}}` | stream + four consumers |
| `s6-overlay/scripts/nats-provision` | the provisioning script itself |
| `s6-overlay/s6-rc.d/vault/{run,type,dependencies.d/{base,nats-provision,generate-s3-credentials,generate-api-key-and-secret,postgres}}` | vault longrun |
| `s6-overlay/s6-rc.d/web-ui/{run,dependencies.d/nats-provision}` | moved to `/app/web-ui` (Task 2b); vault wiring, blanking on `USE_VAULT=false` |
| `s6-overlay/scripts/run-cron-job` | working directory moves to `/app/web-ui` (Task 2b); vault job dispatch (Task 7) |
| `s6-overlay/s6-rc.d/user/contents.d/{nats,nats-provision,vault}` | registration |
| `etc/webtor/cron/crontab` | two vault jobs |
| `tests/scenarios/80-vault.sh` | smoke scenario |
| `README.md`, `CLAUDE.md` | documentation |

**web-ui repo**

| File | Responsibility |
|---|---|
| `services/web/context.go` | `Vault bool` on `Context` |
| `serve.go` | sets it from `vaultApi != nil` |
| `templates/partials/nav.html` | guards both link sites |

---

## Task 1: Vault publishes for arm64

**Repository:** `/Users/vintikzzzz/Projects/webtor/vault` — not the self-hosted repo.

**Files:**
- Modify: `.github/workflows/docker-image.yml`

**Interfaces:**
- Produces: a multi-arch manifest at `ghcr.io/webtor-io/vault:main`, and its new index digest, which Task 2 pins.

Twelve component repositories already delegate their build to a shared reusable workflow. Vault was missed, so it publishes a single-platform amd64 manifest. The self-hosted image is multi-arch; without this, an arm64 build fails or silently assembles an unrunnable binary.

- [ ] **Step 1: Read a repository that already does this**

Read `/Users/vintikzzzz/Projects/webtor/torrent-store/.github/workflows/docker-image.yml`. It calls `webtor-io/.github/.github/workflows/docker-multiarch.yml`. Copy its shape exactly — same trigger set, same inputs, same permissions block. Do not invent a variant.

- [ ] **Step 2: Confirm the current state before changing it**

```bash
docker buildx imagetools inspect ghcr.io/webtor-io/vault:main --raw | head -3
```
Expected: `"mediaType": "application/vnd.docker.distribution.manifest.v2+json"` — a single manifest, not an index. Record this output in the report; it is the before-picture that makes the after meaningful.

- [ ] **Step 3: Replace the workflow**

Write the delegating workflow, matching the reference repository.

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/docker-image.yml
git commit -m "ci: publish multi-arch images via the shared workflow"
git push
```

- [ ] **Step 5: Wait for the build and verify the manifest**

```bash
gh run watch
docker buildx imagetools inspect ghcr.io/webtor-io/vault:main | grep -E "^Name|Platform"
```
Expected: `linux/amd64` **and** `linux/arm64` both listed.

- [ ] **Step 6: Record the new digest**

```bash
docker buildx imagetools inspect ghcr.io/webtor-io/vault:main | awk '/^Digest:/{print $2}'
```
Put this digest in the report. Task 2 pins it. **Do not reuse the digest recorded during design (`sha256:bb5209217a1a8081788447918137ad8bd41a388906ad870514fbef903a1a44c8`)** — that is the old amd64-only manifest, and pinning it would silently undo this task.

---

## Task 2: Vault binary and migrations in the image

**Files:**
- Modify: `Dockerfile`

**Interfaces:**
- Consumes: the multi-arch digest from Task 1.
- Produces: `/app/vault/vault` (binary) and `/app/vault/migrations/` (SQL), which Task 5's run script executes.

Vault's migration discovery is `DiscoverSQLMigrations("migrations")` — relative to the working directory. web-ui's 69 migrations sit at `/app/migrations`, and run scripts `cd /app`. Vault started there would apply web-ui's migrations to vault's database. Its own directory is what prevents that.

- [ ] **Step 1: Add the stage**

Near the other component stages in `Dockerfile`:

```dockerfile
FROM ghcr.io/webtor-io/vault:main@sha256:<digest-from-task-1> AS vault
```

- [ ] **Step 2: Copy the artifacts into their own directory**

In the final stage, after the other `COPY --from` lines:

```dockerfile
# Vault gets its own working directory, not /app, because common-services
# discovers migrations at the CWD-relative path "migrations" -- and /app/migrations
# is web-ui's 69 migrations. Started from /app, vault would apply web-ui's schema
# to vault's database.
COPY --from=vault /server ./vault/vault
COPY --from=vault /migrations ./vault/migrations
```

- [ ] **Step 3: Build**

```bash
docker build -t webtor-self-hosted:vault-bin .
```
Expected: success.

- [ ] **Step 4: Verify the layout is what the next task will rely on**

```bash
docker run --rm --entrypoint sh webtor-self-hosted:vault-bin -c \
  'ls /app/vault/vault && ls /app/vault/migrations | head -3 && echo "--- count ---" && ls /app/vault/migrations | wc -l'
```
Expected: the binary exists; the migrations listing starts at `1_init.down.sql`; the count is small (vault has 8 migrations, so 16 files).

- [ ] **Step 5: Prove vault's directory does not contain web-ui's migrations**

This is the assertion that matters, and it must be able to fail.

```bash
docker run --rm --entrypoint sh webtor-self-hosted:vault-bin -c \
  'ls /app/vault/migrations | grep -c "^6[0-9]_" || true'
```
Expected: `0`. web-ui's migrations run to 69; vault's stop at 8. A non-zero count means the two sets have been merged into one directory.

Then confirm the check can go red:

```bash
docker run --rm --entrypoint sh webtor-self-hosted:vault-bin -c \
  'ls /app/migrations | grep -c "^6[0-9]_"'
```
Expected: non-zero — proving the grep does detect web-ui's numbering when it is present, so the `0` above is a real result and not a broken pattern.

- [ ] **Step 6: Verify the binary runs on this architecture**

```bash
docker run --rm --entrypoint /app/vault/vault webtor-self-hosted:vault-bin --version
```
Expected: prints a version. On an arm64 host this also confirms Task 1 actually took effect — an amd64-only image would fail here with an exec format error.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile
git commit -m "build: add the vault binary and its migrations"
```

---

## Task 2b: Move web-ui into its own directory

**Files:**
- Modify: `Dockerfile`
- Modify: `s6-overlay/s6-rc.d/web-ui/run`
- Modify: `s6-overlay/scripts/run-cron-job`
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:**
- Produces: `/app/web-ui/` holding the binary, `templates/`, `pub/`, `migrations/`, `assets/dist`. Later tasks that edit `web-ui/run` and `run-cron-job` must use the new working directory.

Task 2 gave vault its own directory to keep it away from `/app/migrations`.
That fixed vault; it left the cause. `/app/migrations` belongs to web-ui only
by convention, and the next component with a `migrations/` directory walks into
the same silent failure. Moving web-ui into `/app/web-ui/` removes the shared
namespace instead of routing around it.

Every path web-ui resolves is already relative to its working directory —
`templates/` (`services/template/template.go`), `pub` and `./assets/dist`
(`handlers/static/handler.go`), and `migrations` through common-services — so
moving the directory and the `cd` together is the whole change. Nothing needs a
new flag.

- [ ] **Step 1: Confirm the paths really are all CWD-relative before moving anything**

```bash
cd /Users/vintikzzzz/Projects/webtor/web-ui
grep -rn 'base:      "templates/"' services/template/template.go
grep -n 'pubPath := "pub"' handlers/static/handler.go
grep -n 'Value:  "./assets/dist"' handlers/static/handler.go
```
Expected: all three present. If any has become absolute, stop and report —
the move would silently serve nothing.

- [ ] **Step 2: Move the COPY destinations**

In `Dockerfile`, the five web-ui lines become:

```dockerfile
COPY --from=web-ui /app/server ./web-ui/web-ui
COPY --from=web-ui /app/templates ./web-ui/templates
COPY --from=web-ui /app/pub ./web-ui/pub
COPY --from=web-ui /app/migrations ./web-ui/migrations
COPY --from=web-ui /app/assets/dist ./web-ui/assets/dist
```

- [ ] **Step 3: Move the two working directories**

`s6-overlay/s6-rc.d/web-ui/run`, last line:

```sh
cd /app/web-ui && ./web-ui serve 2>&1 | s6-log p"[web-ui]" 1
```

`s6-overlay/scripts/run-cron-job`, the `cd /app || exit 1` line:

```sh
cd /app/web-ui || exit 1
```

Leave that script's exit-status handling alone — the `status_file` dance
exists because a pipeline's status is `sed`'s, not the job's.

- [ ] **Step 4: Build and verify the layout**

```bash
docker build -t webtor-self-hosted:webuimove .
docker run --rm --entrypoint sh webtor-self-hosted:webuimove -c \
  'ls /app/web-ui/web-ui && ls -d /app/web-ui/templates /app/web-ui/pub /app/web-ui/migrations /app/web-ui/assets/dist'
```
Expected: all five listed.

- [ ] **Step 5: Verify the trap is gone, not merely moved**

```bash
docker run --rm --entrypoint sh webtor-self-hosted:webuimove -c 'ls /app/migrations 2>&1'
```
Expected: `ls: /app/migrations: No such file or directory`. That absence is the
point of this task: a future component starting from `/app` can no longer
discover web-ui's migrations, because there is nothing there to discover.

- [ ] **Step 6: Prove the app actually works from the new directory**

Layout checks do not show that web-ui serves. Run the full smoke suite, which
exercises pages, templates, static assets, the database and the admin password:

```bash
WEBTOR_HOST_PORT=18080 tests/run.sh webtor-self-hosted:webuimove
```
Expected: `SUITE PASSED`. A missing `templates/` or `pub/` shows up here as
failing page scenarios, and a missing `migrations/` as a failing DDL scenario —
which is why this step is not optional.

- [ ] **Step 7: Verify the documented recovery command against the new layout**

The README publishes a password-recovery command that names the path. Run the
new form and confirm it works:

```bash
docker rm -f wmv; docker volume rm wmvpg
docker run -d --name wmv -v wmvpg:/pgdata webtor-self-hosted:webuimove
sleep 40
docker exec wmv sh -c 'set -a; . /etc/webtor/common.env; cd /app/web-ui && ./web-ui admin set-password testpass123'
echo "exit: $?"
docker rm -f wmv; docker volume rm wmvpg
```
Expected: exit 0. It must source `common.env` first — without it web-ui connects
to Postgres with common-services' defaults (`PG_USER=webhook`,
`PG_DATABASE=webhook`) instead of `app`/`app`.

- [ ] **Step 8: Update both documents**

`README.md` and `CLAUDE.md` each carry that recovery command with `cd /app`.
Change both to `cd /app/web-ui`. Grep to be sure none is missed:

```bash
grep -rn "cd /app &&" README.md CLAUDE.md
```
Expected after the edit: no matches.

- [ ] **Step 9: Commit**

```bash
git add Dockerfile s6-overlay/ README.md CLAUDE.md
git commit -m "refactor: give web-ui its own directory under /app"
```

---

## Task 3: A separate database for vault

**Files:**
- Modify: `etc/webtor/common.template.env`
- Modify: `s6-overlay/s6-rc.d/postgres/run`

**Interfaces:**
- Produces: `VAULT_PG_DATABASE` (default `vault`), and that database existing in the embedded instance.

`go-pg/migrations` records the schema version in one table per database, `gopg_migrations`. web-ui is at version 69, vault at 8. Sharing a database makes vault read web-ui's version, conclude its own migrations are applied, and create no tables at all — a silent, total failure.

- [ ] **Step 1: Add the variable**

In `etc/webtor/common.template.env`, beside the other `PG_*` entries:

```
VAULT_PG_DATABASE=${VAULT_PG_DATABASE:-vault}
```

- [ ] **Step 2: Create the database in the background initializer**

In `s6-overlay/s6-rc.d/postgres/run`, after the existing `CREATE DATABASE`/`GRANT` pair for `$PG_DATABASE`, add the same pair for the vault database:

```sh
  # Vault keeps its own database. go-pg/migrations tracks the schema version in
  # a single gopg_migrations row per database; web-ui is at 69 and vault at 8,
  # so a shared database would make vault skip its own schema entirely.
  su -s /bin/sh -c "psql -p ${PG_PORT:-5432} -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='${VAULT_PG_DATABASE}'\" | grep -q 1 || psql -p ${PG_PORT:-5432} -U postgres -c \"CREATE DATABASE \"\"${VAULT_PG_DATABASE}\"\" OWNER \"\"${PG_USER}\"\"\"" postgres || true
  su -s /bin/sh -c "psql -p ${PG_PORT:-5432} -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE \"\"${VAULT_PG_DATABASE}\"\" TO \"\"${PG_USER}\"\"\"" postgres || true
```

- [ ] **Step 3: Build and run**

```bash
docker build -t webtor-self-hosted:vault-db .
docker rm -f vdb; docker volume rm vdbpg
docker run -d --name vdb -v vdbpg:/pgdata webtor-self-hosted:vault-db
sleep 30
```

- [ ] **Step 4: Verify both databases exist**

```bash
docker exec vdb su -s /bin/sh -c "psql -U postgres -tAc \"SELECT datname FROM pg_database WHERE datname IN ('app','vault') ORDER BY datname\"" postgres
```
Expected, exactly two lines:
```
app
vault
```

- [ ] **Step 5: Verify the override works**

```bash
docker rm -f vdb2; docker volume rm vdbpg2
docker run -d --name vdb2 -v vdbpg2:/pgdata -e VAULT_PG_DATABASE=myvault webtor-self-hosted:vault-db
sleep 30
docker exec vdb2 su -s /bin/sh -c "psql -U postgres -tAc \"SELECT datname FROM pg_database WHERE datname='myvault'\"" postgres
```
Expected: `myvault`. This proves the `${VAR:-default}` form reached the initializer rather than the default being hardcoded.

- [ ] **Step 6: Clean up and commit**

```bash
docker rm -f vdb vdb2; docker volume rm vdbpg vdbpg2
git add etc/webtor/common.template.env s6-overlay/s6-rc.d/postgres/run
git commit -m "feat: create a separate database for vault"
```

---

## Task 4: NATS server and JetStream provisioning

**Files:**
- Modify: `Dockerfile`, `etc/webtor/common.template.env`
- Create: `s6-overlay/s6-rc.d/nats/{run,type}`, `s6-overlay/s6-rc.d/nats/dependencies.d/base`
- Create: `s6-overlay/s6-rc.d/nats-provision/{up,type}`, `s6-overlay/s6-rc.d/nats-provision/dependencies.d/{base,nats}`
- Create: `s6-overlay/scripts/nats-provision`
- Create: `s6-overlay/s6-rc.d/user/contents.d/nats`, `s6-overlay/s6-rc.d/user/contents.d/nats-provision`

**Interfaces:**
- Produces: a NATS server on `127.0.0.1:4222` with JetStream; the stream `common`; four durable consumers. Task 5 makes vault and web-ui depend on `nats-provision`.

Both vault and web-ui subscribe with `nats.Bind(stream, consumer)`, which requires the stream **and the durable consumer** to already exist. web-ui's event handler joins its main serve group, so a failed subscribe takes web-ui down. Provisioning is therefore a hard dependency, and it must fail loudly on its own rather than let web-ui crash-loop.

- [ ] **Step 1: Add the two stages**

```dockerfile
# Not webtor components: the event bus and the CLI that provisions its stream.
# Both publish linux/amd64 and linux/arm64. Renovate does not watch either
# (renovate.json matches ghcr.io/webtor-io/**), so bumps here are manual.
FROM nats:alpine@sha256:d4ac35882ac65aff236cd65b9d3fa4d24332c681e1a85f94eedccd3cdd65b1da AS nats
FROM natsio/nats-box:latest@sha256:ffce8bd103383f179f8c7f11cf645726acf5d17280706c530c3b342dbe16334c AS natsbox
```

And in the final stage:

```dockerfile
COPY --from=nats /usr/local/bin/nats-server ./nats-server
COPY --from=natsbox /usr/local/bin/nats ./nats
```

Note the two names are different things and both are load-bearing: `nats-server` is the broker, `nats` is the CLI. Do not rename either to match the other.

- [ ] **Step 2: Add the variables**

In `etc/webtor/common.template.env`:

```
NATS_SERVICE_HOST=127.0.0.1
NATS_SERVICE_PORT=4222
```

Fixed at loopback, like every other internal service, and deliberately not overridable — the constraint that NATS is not reachable from outside depends on it.

- [ ] **Step 3: Write the NATS service**

`s6-overlay/s6-rc.d/nats/type`:
```
longrun
```

`s6-overlay/s6-rc.d/nats/run`:
```sh
#!/command/with-contenv sh
set -a
source /etc/webtor/common.env
set +a

# JetStream with memory-backed streams. The one live subject is
# resource.vaulted, published and consumed inside this container, so the
# delivery window is milliseconds; only a full container restart can drop an
# event. Memory storage keeps the operator's docker run line unchanged, and
# there is nowhere good to put a file store: $STORAGE_DIR turns directories
# into S3 buckets, $DATA_DIR is swept by the autocleaner, and $PGDATA_DIR is
# the database's. The server still writes its own JetStream metadata under
# /tmp, which is what we want -- ephemeral.
exec /app/nats-server \
  --addr "$NATS_SERVICE_HOST" \
  --port "$NATS_SERVICE_PORT" \
  --jetstream 2>&1 | s6-log p"[nats]" 1
```

`s6-overlay/s6-rc.d/nats/dependencies.d/base` — empty file.
`s6-overlay/s6-rc.d/user/contents.d/nats` — empty file.

- [ ] **Step 4: Write the provisioning script**

`s6-overlay/scripts/nats-provision`:
```sh
#!/command/with-contenv sh
set -a
source /etc/webtor/common.env
set +a

log() {
  echo "$1" | s6-log p"[nats-provision]" 1
}

url="nats://$NATS_SERVICE_HOST:$NATS_SERVICE_PORT"

# Wait for the broker. nats-provision depends on nats, but s6 only guarantees
# the process was started, not that it is accepting connections.
i=0
while [ "$i" -lt 60 ]; do
  if /app/nats -s "$url" server check connection >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

# Both vault and web-ui subscribe with nats.Bind, which fails unless the
# stream AND the durable consumer already exist -- and web-ui's event handler
# is part of its main serve group, so that failure crash-loops web-ui. This
# oneshot is the reason that cannot happen, so it fails loudly instead of
# letting a half-provisioned broker through.
fail() {
  log "FATAL: $1"
  log "vault and web-ui bind to durable consumers that must exist before they start."
  log "web-ui will not start against a half-provisioned broker."
  exit 1
}

# JetStream returns the existing object when the requested configuration is
# identical, so re-running this on every boot is a no-op. A genuine conflict
# -- same name, different configuration -- exits non-zero and is reported.
/app/nats -s "$url" stream add common \
  --subjects='user.*,resource.*' \
  --storage=memory \
  --retention=limits \
  --max-age=24h \
  --replicas=1 \
  --defaults >/dev/null 2>&1 || fail "could not create the 'common' stream"

# Only resource.vaulted carries traffic in this image: user.updated is
# published by the webhook service and resource.banned by the abuse pipeline,
# neither of which ships here. All four must exist anyway -- each subscriber
# binds to its own by name and errors if it is missing.
add_consumer() {
  name=$1
  subject=$2
  /app/nats -s "$url" consumer add common "$name" \
    --filter="$subject" \
    --ack=explicit \
    --deliver=all \
    --pull \
    --wait=30s \
    --replay=instant \
    --max-deliver=-1 \
    --defaults >/dev/null 2>&1 || fail "could not create the '$name' consumer"
}

add_consumer web-ui-resource-vaulted resource.vaulted
add_consumer web-ui-resource-banned  resource.banned
add_consumer web-ui-user-updated     user.updated
add_consumer vault-resource-banned   resource.banned

log "stream 'common' and four consumers are ready"
```

- [ ] **Step 5: Write the oneshot service**

`s6-overlay/s6-rc.d/nats-provision/type`:
```
oneshot
```

`s6-overlay/s6-rc.d/nats-provision/up`:
```
/etc/s6-overlay/scripts/nats-provision 2>&1
```

`s6-overlay/s6-rc.d/nats-provision/dependencies.d/base` — empty file.
`s6-overlay/s6-rc.d/nats-provision/dependencies.d/nats` — empty file.
`s6-overlay/s6-rc.d/user/contents.d/nats-provision` — empty file.

- [ ] **Step 6: Build and run**

```bash
docker build -t webtor-self-hosted:nats .
docker rm -f vn; docker run -d --name vn webtor-self-hosted:nats
sleep 30
```

- [ ] **Step 7: Verify the stream and all four consumers exist**

```bash
docker exec vn /app/nats -s nats://127.0.0.1:4222 stream info common --json | grep -o '"name":"common"'
docker exec vn /app/nats -s nats://127.0.0.1:4222 consumer ls common
```
Expected: the stream name matches, and the consumer listing contains exactly `web-ui-resource-vaulted`, `web-ui-resource-banned`, `web-ui-user-updated`, `vault-resource-banned`.

- [ ] **Step 8: Verify loopback-only**

```bash
docker exec vn netstat -tlnp 2>/dev/null | grep 4222
docker rm -f vnpub; docker run -d --name vnpub -p 14222:4222 webtor-self-hosted:nats
sleep 25
docker run --rm --network host --entrypoint nats natsio/nats-box:latest \
  -s nats://127.0.0.1:14222 server check connection --connect-warn=2s --connect-critical=3s
echo "connection check exit: $?"
docker rm -f vnpub
```
Expected: `netstat` shows `127.0.0.1:4222`, not `0.0.0.0:4222`, and the connection check exits non-zero. Publishing the port and still failing to connect is what proves the bind address, rather than merely that nothing proxies it.

Use the NATS client, not curl: NATS is not HTTP, so curl's failure says nothing
about whether the port is reachable — through Docker's userland proxy it can
return "empty reply" for a live socket and "connection refused" for a dead one,
codes too close together to rest an assertion on.

- [ ] **Step 9: Verify idempotency across a restart**

```bash
docker restart vn
sleep 30
docker logs vn 2>&1 | grep -c "FATAL"
docker exec vn /app/nats -s nats://127.0.0.1:4222 consumer ls common | wc -l
```
Expected: zero FATAL lines, and the same four consumers. The oneshot runs again on every boot; if it were not idempotent this is where it would fail.

- [ ] **Step 10: Negative control — the guard must be able to fire**

Prove `fail` is reachable and that the oneshot does not report success on a broken broker:

```bash
docker rm -f vnneg
docker run -d --name vnneg --entrypoint sh webtor-self-hosted:nats -c \
  'mv /app/nats-server /app/nats-server.hidden; exec /init'
sleep 100
docker logs vnneg 2>&1 | grep "\[nats-provision\] FATAL" | head -2
docker rm -f vnneg
```

The wait is 100 seconds, not the ~30 the other steps use, because the script
retries the connection for 60 seconds before giving up. Checking sooner finds no
FATAL line yet and reads as "the guard does not work" — which would send you off
fixing code that is fine.

Expected: the FATAL line appears. With the broker absent, provisioning cannot succeed, and this confirms that state is reported rather than passed over silently.

- [ ] **Step 11: Clean up and commit**

```bash
docker rm -f vn
git add Dockerfile etc/webtor/common.template.env s6-overlay/
git commit -m "feat: run NATS with JetStream and provision its stream"
```

---

## Task 5: The vault service, and web-ui wired to it

**Files:**
- Modify: `etc/webtor/common.template.env`
- Create: `s6-overlay/s6-rc.d/vault/{run,type}`, `s6-overlay/s6-rc.d/vault/dependencies.d/{base,nats-provision,generate-api-key-and-secret,generate-s3-credentials}`
- Create: `s6-overlay/s6-rc.d/user/contents.d/vault`
- Modify: `s6-overlay/s6-rc.d/web-ui/run`
- Create: `s6-overlay/s6-rc.d/web-ui/dependencies.d/nats-provision`

**Interfaces:**
- Consumes: `/app/vault/vault` and `/app/vault/migrations` (Task 2), `VAULT_PG_DATABASE` (Task 3), `nats-provision` (Task 4).
- Produces: vault serving on `127.0.0.1:8100`; `VAULT_SERVICE_HOST`/`VAULT_SERVICE_PORT` for web-ui.

- [ ] **Step 1: Add the variables**

In `etc/webtor/common.template.env`:

```
USE_VAULT=${USE_VAULT:-true}
VAULT_SERVICE_HOST=127.0.0.1
VAULT_SERVICE_PORT=8100
VAULT_AWS_BUCKET=${VAULT_AWS_BUCKET:-vault}
```

Port 8100 continues the map; 8090–8099 are taken. `VAULT_SERVICE_HOST`/`PORT` are fixed at loopback like every other internal service.

- [ ] **Step 2: Write the vault service**

`s6-overlay/s6-rc.d/vault/type`:
```
longrun
```

`s6-overlay/s6-rc.d/vault/run`:
```sh
#!/command/with-contenv sh
set -a
source /etc/webtor/common.env
source /etc/webtor/secrets/api.env
source /etc/webtor/secrets/s3.env
set +a

log() {
  echo "$1" | s6-log p"[vault]" 1
}

if [ "${USE_VAULT:-true}" = "false" ]; then
  log "USE_VAULT=false -- not starting vault; web-ui will hide the vault UI"
  # s6 restarts a longrun that exits, so idle rather than exiting.
  exec sleep infinity
fi

set -a
WEB_PORT=$VAULT_SERVICE_PORT
PG_DATABASE=$VAULT_PG_DATABASE
AWS_BUCKET=$VAULT_AWS_BUCKET
WEBTOR_API_KEY=$API_KEY
WEBTOR_API_SECRET=$API_SECRET
# rest-api hands out export URLs built from DOMAIN, which names how the
# instance is reached from outside -- a host port, or a public name that does
# not resolve in here. This makes vault rewrite the host of every content URL
# to the in-container proxy before fetching. Without it the worker fetches
# from an address that does not exist inside the container and nothing is ever
# stored, while the service itself looks healthy.
USE_INTERNAL_TORRENT_HTTP_PROXY=true
set +a

# cd into vault's own directory, not /app. common-services discovers
# migrations at the CWD-relative path "migrations", and /app/migrations is
# web-ui's. Started from /app, vault would apply web-ui's 69 migrations to
# vault's database.
cd /app/vault && ./vault serve 2>&1 | s6-log p"[vault]" 1
```

`s6-overlay/s6-rc.d/vault/dependencies.d/base` — empty file.
`s6-overlay/s6-rc.d/vault/dependencies.d/nats-provision` — empty file.
`s6-overlay/s6-rc.d/vault/dependencies.d/generate-api-key-and-secret` — empty file.
`s6-overlay/s6-rc.d/vault/dependencies.d/generate-s3-credentials` — empty file.
`s6-overlay/s6-rc.d/user/contents.d/vault` — empty file.

- [ ] **Step 3: Wire web-ui**

In `s6-overlay/s6-rc.d/web-ui/run`, inside the existing `set -a` block, after the other overrides:

```sh
# web-ui keys its vault degradation off an empty VAULT_SERVICE_HOST:
# vault.NewApi returns nil, the /vault routes are never registered, and the
# page-level CTAs disappear. common.env sets the host unconditionally --
# envsubst has no conditionals -- so blank it here when the store is off.
# Leaving it set would point web-ui at a sleeping service: the UI would
# render and every vault page would fail against a dead endpoint instead of
# degrading.
if [ "${USE_VAULT:-true}" = "false" ]; then
  VAULT_SERVICE_HOST=
fi
```

Create `s6-overlay/s6-rc.d/web-ui/dependencies.d/nats-provision` — empty file. web-ui's event handler binds to three durable consumers; without this dependency it can start before they exist and crash-loop.

- [ ] **Step 4: Build and run**

```bash
docker build -t webtor-self-hosted:vault .
docker rm -f vv; docker volume rm vvpg vvst
docker run -d --name vv -p 18080:8080 -v vvpg:/pgdata -v vvst:/storage webtor-self-hosted:vault
sleep 45
```

- [ ] **Step 5: Verify vault serves and web-ui is healthy**

```bash
docker exec vv sh -c 'ps aux | grep -c "[v]ault serve"'
docker exec vv netstat -tlnp 2>/dev/null | grep 8100
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/
docker inspect -f 'RestartCount={{.RestartCount}}' vv
```
Expected: one vault process; `127.0.0.1:8100` listening; the front page returns 200; RestartCount 0. The last two together are what show web-ui did not crash-loop on its new NATS dependency.

- [ ] **Step 6: Verify migrations landed in vault's database and nowhere else**

This is the observable consequence of Tasks 2 and 3, and the single most important check in this plan.

```bash
docker exec vv su -s /bin/sh -c \
  "psql -U postgres -d vault -tAc \"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename\"" postgres
```
Expected: includes `resource`, `file`, `resource_file` — vault's own tables.

```bash
docker exec vv su -s /bin/sh -c \
  "psql -U postgres -d vault -tAc \"SELECT max(version) FROM gopg_migrations\"" postgres
```
Expected: `8` or lower — vault's own migration count. **If this reports 69, vault applied web-ui's migrations**, which is exactly the failure Task 2's working directory exists to prevent.

```bash
docker exec vv su -s /bin/sh -c \
  "psql -U postgres -d app -tAc \"SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename IN ('resource','file','resource_file')\"" postgres
```
Expected: `0` — vault's tables did not leak into web-ui's database.

- [ ] **Step 7: Verify USE_VAULT=false**

```bash
docker rm -f vvoff; docker volume rm vvoffpg vvoffst
docker run -d --name vvoff -p 18081:8080 -e USE_VAULT=false -v vvoffpg:/pgdata -v vvoffst:/storage webtor-self-hosted:vault
sleep 45
docker logs vvoff 2>&1 | grep "\[vault\] USE_VAULT=false"
docker exec vvoff sh -c 'ps aux | grep -c "[v]ault serve"'
docker exec vvoff netstat -tlnp 2>/dev/null | grep -c 8100
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/vault
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/
docker inspect -f 'RestartCount={{.RestartCount}}' vvoff
```
Expected: the log line is present; no vault process; nothing on 8100; the front page still returns 200; RestartCount 0. `/vault` answers with web-ui's generic not-found handling — a 302 to `/?err=error.invalid_resource...`, byte-for-byte what any nonexistent path returns, not a bare 404. Compare it against a path you know does not exist rather than asserting a status code: the claim being tested is that the routes were never registered.

- [ ] **Step 8: Negative control on the blanking**

Remove the three-line `if` added in Step 3, rebuild, and re-run Step 7. Expected: `/vault` answers 200 — web-ui registers the routes and points at a sleeping service. Restore the guard and confirm the not-found response returns. Report both directions verbatim.

- [ ] **Step 9: Clean up and commit**

```bash
docker rm -f vv vvoff; docker volume rm vvpg vvst vvoffpg vvoffst
git add etc/webtor/common.template.env s6-overlay/
git commit -m "feat: run vault and point web-ui at it"
```

---

## Task 6: Gate the navbar link

**Repository:** `/Users/vintikzzzz/Projects/webtor/web-ui` — not the self-hosted repo.

**Files:**
- Modify: `services/web/context.go`
- Modify: `serve.go`
- Modify: `templates/partials/nav.html`

**Interfaces:**
- Produces: `Context.Vault bool`, true when the vault API client exists.

`templates/partials/nav.html` renders the Vault link unconditionally inside `{{ if .User | hasAuth }}` — in the desktop bar and again in the mobile burger — while the `/vault` routes are registered only when vault exists. Today that link is a 404 in every self-hosted instance. Adding vault fixes it for the default configuration and re-creates it exactly for operators who set `USE_VAULT=false`, a mode this plan introduces.

- [ ] **Step 1: Find the two link sites and the context struct**

```bash
grep -n "nav.vault" templates/partials/nav.html
grep -n "type Context struct" -A 20 services/web/context.go
```
Record the line numbers; there are two link sites and both need the guard.

- [ ] **Step 2: Write the failing test**

In `services/web/context_test.go` (create if absent):

```go
func TestContextCarriesVaultAvailability(t *testing.T) {
	c := Context{Vault: true}
	if !c.Vault {
		t.Fatal("Context.Vault should round-trip true")
	}
	var zero Context
	if zero.Vault {
		t.Fatal("Context.Vault must default to false, so a caller that forgets to set it hides the link rather than showing a broken one")
	}
}
```

The second assertion is the point: the safe default is "absent". A field that defaulted to true would put the 404 back for anyone who forgets to set it.

- [ ] **Step 3: Run it and watch it fail**

```bash
go test ./services/web/ -run TestContextCarriesVaultAvailability -v
```
Expected: FAIL — `Vault` is not a field of `Context`.

- [ ] **Step 4: Add the field and the plumbing**

`NewContext(c *gin.Context)` builds from the gin context and has no access to
`vaultApi`, so the value arrives the way `UserSettings` already does — a
middleware sets it, the constructor reads it.

In `services/web/context.go`, beside the existing `userSettingsContextKey`
declaration:

```go
const vaultEnabledContextKey = "web.vault_enabled"

// SetVaultEnabled records whether the vault service is configured. The navbar
// link and the /vault routes must agree: the routes are registered only when
// the vault API client exists, so an ungated link is a 404.
func SetVaultEnabled(c *gin.Context, enabled bool) {
	c.Set(vaultEnabledContextKey, enabled)
}

// vaultEnabled defaults to false when nothing set it, so a caller that forgets
// hides the link rather than rendering a broken one.
func vaultEnabled(c *gin.Context) bool {
	v, ok := c.Get(vaultEnabledContextKey)
	if !ok {
		return false
	}
	b, _ := v.(bool)
	return b
}
```

On the `Context` struct:

```go
	// Vault reports whether the vault service is configured.
	Vault bool
```

And in the `return &Context{...}` literal at the end of `NewContext`, beside
`OpenInstance`:

```go
		Vault:        vaultEnabled(c),
```

- [ ] **Step 5: Run it and watch it pass**

```bash
go test ./services/web/ -run TestContextCarriesVaultAvailability -v
```
Expected: PASS.

- [ ] **Step 6: Populate it**

In `serve.go`, immediately after the `r.Use(w.OnboardingMiddleware(onboardingSvc))`
line (around line 371):

```go
	// Mounted here for the same reason the onboarding middleware above is:
	// gin's r.Use only applies to routes registered after it, and the navbar
	// renders on every page. vaultApi != nil is the existing source of truth
	// for whether vault is configured -- do not introduce a second one.
	vaultConfigured := vaultApi != nil
	r.Use(func(c *gin.Context) {
		web.SetVaultEnabled(c, vaultConfigured)
		c.Next()
	})
```

`vaultApi` is created a few lines above (around 364) and the first route is
registered around 379, so this sits in the gap. Confirm that ordering still
holds before writing:

```bash
grep -n "vaultApi := \|RegisterHandler" serve.go | head -3
```

Use whatever import alias `serve.go` already has for `services/web`.

- [ ] **Step 7: Guard both link sites**

Wrap each of the two anchors found in Step 1:

```
{{ if $.Vault }}
... the existing anchor, unchanged ...
{{ end }}
```

- [ ] **Step 7a: Verify both states render correctly**

A template guard that is never exercised proves nothing. Start the app both
ways and check the rendered HTML:

```bash
# vault absent
VAULT_SERVICE_HOST= go run . serve &
sleep 5; curl -sS http://localhost:8080/ | grep -c 'href="/vault"'; kill %1
```
Expected: `0`.

```bash
# vault present (host need not answer; only the client's existence is read here)
VAULT_SERVICE_HOST=127.0.0.1 VAULT_SERVICE_PORT=8100 go run . serve &
sleep 5; curl -sS http://localhost:8080/ | grep -c 'href="/vault"'; kill %1
```
Expected: non-zero.

If the second command also reports `0`, the guard is hiding the link
unconditionally — which passes a naive test while removing the feature. Report
both numbers.

- [ ] **Step 8: Run the full suite**

```bash
go test ./... 2>&1 | grep -E "^(FAIL|ok)" | grep -c FAIL
```
Expected: `0`. Report the actual command output, not a summary of it.

- [ ] **Step 9: Commit and rebuild the local image**

```bash
git add services/web/context.go services/web/context_test.go serve.go templates/partials/nav.html
git commit -m "fix(nav): hide the Vault link when no vault service is configured"
docker build -t web-ui:cron .
```

The rebuilt `web-ui:cron` is what later tasks in the self-hosted repo test against.

---

## Task 7: The two cron jobs

**Files:**
- Modify: `etc/webtor/cron/crontab`

**Interfaces:**
- Consumes: `run-cron-job`, which already sources the service environment and reports a job's real exit status.

- [ ] **Step 1: Remove the note that no longer holds and add the jobs**

Delete these two lines from the header comment:

```
# vault reap is deliberately absent: the vault service is not part of this
# image, so there is nothing to reap.
```

Add, keeping the file's existing style of a comment explaining each schedule:

```
# Mirrors the production CronJobs. reap is web-ui's own subcommand and expires
# pledges against web-ui's tables; gc is vault's and sweeps files that no
# resource_file row references. Both skip when USE_VAULT=false.
0 * * * * /etc/s6-overlay/scripts/run-cron-job vault-reap vault reap
0 4 * * * /etc/s6-overlay/scripts/run-cron-job vault-gc-unused vault gc
```

**Careful:** the first invokes `web-ui vault reap` and the second invokes `vault gc` — different binaries. Read `s6-overlay/scripts/run-cron-job` before writing these lines: it currently runs `./web-ui "$@"` from `/app`. `vault gc` must run `/app/vault/vault` from `/app/vault`, so the wrapper needs to dispatch on the job. Implement that dispatch in the wrapper rather than adding a second wrapper, and keep its existing exit-status handling intact — that code exists because a pipeline's status is `sed`'s, not the job's.

- [ ] **Step 2: Build and force each job to run**

```bash
docker build -t webtor-self-hosted:vault-cron .
docker rm -f vc; docker volume rm vcpg vcst
docker run -d --name vc -v vcpg:/pgdata -v vcst:/storage webtor-self-hosted:vault-cron
sleep 45
docker exec vc /etc/s6-overlay/scripts/run-cron-job vault-reap vault reap; echo "reap exit: $?"
docker exec vc /etc/s6-overlay/scripts/run-cron-job vault-gc-unused vault gc; echo "gc exit: $?"
```
Expected: both exit 0 and print `[cron:vault-reap]` / `[cron:vault-gc-unused]` prefixed output. An empty database is a valid input for both.

- [ ] **Step 3: Verify the wrapper reports a real failure**

The wrapper's exit-status handling is load-bearing; confirm it still works after the dispatch change:

```bash
docker exec vc /etc/s6-overlay/scripts/run-cron-job vault-gc-unused vault nonsense-subcommand; echo "exit: $?"
```
Expected: non-zero. If this reports 0, the dispatch has re-broken the pipeline-status masking the wrapper was written to avoid.

- [ ] **Step 4: Clean up and commit**

```bash
docker rm -f vc; docker volume rm vcpg vcst
git add etc/webtor/cron/crontab s6-overlay/scripts/run-cron-job
git commit -m "feat: schedule the vault reap and gc jobs"
```

---

## Task 8: Smoke scenario

**Files:**
- Create: `tests/scenarios/80-vault.sh`

**Interfaces:**
- Consumes: `tests/lib.sh` helpers — `fail`, `assert_eq`, `wait_for`, `apiv1`, `webtor_exec`, `BASE_URL`.

Read `tests/scenarios/70-s3.sh` first and match its shape: it drives a signed request from inside the container rather than publishing a port, and its comments record why. The suite runs every `tests/scenarios/*.sh` in filename order against one shared container.

- [ ] **Step 1: Write the scenario**

The suite already builds the fixture this needs: `tests/fixtures/build.sh`
renders a 10-second synthetic clip plus a subtitle and a readme (212 KB, 7
pieces) into `smoke.torrent`, whose webseed URL points at the `webseed` nginx
container in `tests/docker-compose.yml`. Content therefore flows with no real
swarm, over the same path production uses — seeder, then torrent-http-proxy —
which is exactly what vault's worker walks. Reuse it; do not invent a second
fixture and do not preseed files into `/data`, which would skip the fetch path
this test exists to exercise.

`tests/scenarios/80-vault.sh`:

```bash
#!/usr/bin/env bash
# Vault stores a torrent permanently and tells web-ui that it did.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# psql_db <database> <sql> -- one scalar out of the embedded postgres.
psql_db() {
  webtor_exec su -s /bin/sh -c "psql -U postgres -d $1 -tAc \"$2\"" postgres </dev/null | tr -d ' \r'
}

# 1. Vault migrated its own database. If its working directory were /app it
# would have discovered web-ui's 69 migrations and applied those instead, so
# the version is the observable difference, not a detail.
for t in resource file resource_file; do
  got="$(psql_db vault "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='$t'")"
  assert_eq "$got" "1" "vault database is missing its own table '$t'"
done

version="$(psql_db vault "SELECT coalesce(max(version),0) FROM gopg_migrations")"
[ "$version" -le 8 ] \
  || fail "vault's database is at migration version $version; vault has 8 of its own, so it applied web-ui's instead"

# 2. And nothing of vault's leaked into web-ui's database.
leaked="$(psql_db app "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename IN ('resource','file','resource_file')")"
assert_eq "$leaked" "0" "vault's tables were created in web-ui's database"

# 3. The stream and every consumer both subscribers bind to. A missing one
# does not degrade -- web-ui's event handler is part of its serve group, so a
# failed bind crash-loops it.
nats_cli() { webtor_exec /app/nats -s nats://127.0.0.1:4222 "$@" </dev/null; }
consumers="$(nats_cli consumer ls common)"
for cn in web-ui-resource-vaulted web-ui-resource-banned web-ui-user-updated vault-resource-banned; do
  printf '%s' "$consumers" | grep -q "$cn" \
    || fail "durable consumer '$cn' is missing; its subscriber cannot bind and will not start
  consumers present: $consumers"
done

# 4. Vault is serving, not idling on sleep infinity after a fatal.
vault_up() {
  webtor_exec sh -c 'curl -sS --fail-with-body -o /dev/null http://127.0.0.1:8100/resource/0000000000000000000000000000000000000000 || [ $? -ne 7 ]' </dev/null
}
wait_for 60 "vault answering on 127.0.0.1:8100" vault_up

# 5. The whole point: a pledged torrent gets stored, and web-ui finds out.
# Everything above can pass while the event never arrives.
resource="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")"
rid="$(printf '%s' "$resource" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
[ -n "$rid" ] || fail "could not read the resource id from: $resource"

apiv1 POST /vault/pledges --data-binary "{\"resource_id\":\"$rid\"}" >/dev/null \
  || fail "POST /api/v1/vault/pledges was rejected for $rid"

# The transfer and the notification are asynchronous: vault fetches the
# content through torrent-http-proxy, verifies every piece hash, uploads to
# the embedded S3, then publishes resource.vaulted for web-ui to consume.
pledge_vaulted() {
  local body
  body="$(apiv1 GET "/vault/pledges/$rid")" || return 1
  printf '%s' "$body" | python3 -c '
import json, sys
p = json.load(sys.stdin)
sys.exit(0 if p.get("vaulted") else 1)
'
}
if ! wait_for 240 "pledge to report vaulted=true" pledge_vaulted; then
  # wait_for exits on failure; this is here for the case it ever returns.
  fail "pledge never reported vaulted"
fi

# And the bytes are really in the bucket, not just a flag flipped.
stored="$(webtor_exec sh -c 'find /storage/vault -type f | head -1' </dev/null | tr -d '\r')"
[ -n "$stored" ] || fail "pledge reports vaulted but /storage/vault holds no files"

# 6. Running the cron jobs must not touch web-ui's database. The wrapper
# sources common.env, where PG_DATABASE names web-ui's database, so the gc
# branch has to override it -- and a naive dispatch already ran gc against
# web-ui's database once during implementation, applying vault's migrations
# there and then sweeping nothing forever. That override now exists in two
# places (the wrapper and s6-rc.d/vault/run), so a rename in one and not the
# other silently restores the bug. This is what would notice.
before="$(psql_db app "SELECT max(version) FROM gopg_migrations")"
webtor_exec /etc/s6-overlay/scripts/run-cron-job vault-reap vault reap </dev/null >/dev/null \
  || fail "cron job vault-reap failed"
webtor_exec /etc/s6-overlay/scripts/run-cron-job vault-gc-unused vault gc </dev/null >/dev/null \
  || fail "cron job vault-gc-unused failed"

after="$(psql_db app "SELECT max(version) FROM gopg_migrations")"
assert_eq "$after" "$before" "running the vault cron jobs changed web-ui's migration version -- gc ran against the wrong database"

leaked_after="$(psql_db app "SELECT count(*) FROM pg_tables WHERE tablename IN ('file','resource_file')")"
assert_eq "$leaked_after" "0" "running the vault cron jobs created vault's tables in web-ui's database"

echo "PASS: vault"
```

Note on assertion 5's failure reporting: `wait_for` already prints the last
attempt's exit status and output, so a pledge that stays `vaulted=false` and a
pledge that 404s produce visibly different diagnostics. Do not replace it with
a bare loop that reports only "timed out" — a false flag and a missing row have
different causes and different fixes.

**Content-Type caveat, read before debugging a 400.** `apiv1` in `tests/lib.sh`
sends `Content-Type: application/x-bittorrent` on every call, and that is
load-bearing for `POST /resource`: curl would otherwise default a
`--data-binary` body to form encoding, the CSRF middleware would parse and
consume it, and the handler would see nothing. The pledge endpoint wants JSON.
`ShouldBindJSON` decodes the body without inspecting the header, so this may
work as written — but if `POST /vault/pledges` answers 400, that is the cause.
Fix it by giving `lib.sh` a small `apiv1_json` variant that sets
`application/json`, rather than by changing `apiv1` itself and breaking the
four scenarios that depend on its current header.

- [ ] **Step 2: Run the full suite**

```bash
WEBTOR_HOST_PORT=18080 tests/run.sh webtor-self-hosted:vault-cron
```
Expected: `SUITE PASSED`, with `PASS: vault` among the results.

- [ ] **Step 3: Negative control — break the event path only**

The scenario must distinguish "vault stored the file" from "web-ui learned about it". Delete just the consumer web-ui binds to, restart web-ui, and re-run:

```bash
docker compose -f tests/docker-compose.yml -p webtor-smoke exec -T webtor \
  /app/nats -s nats://127.0.0.1:4222 consumer rm common web-ui-resource-vaulted -f
```

Expected: assertion 5 fails while assertions 1–4 still pass. Restore by re-running `/etc/s6-overlay/scripts/nats-provision`, confirm green, and report both directions verbatim.

If assertion 5 passes with that consumer deleted, it is not testing what it claims and must be rewritten.

- [ ] **Step 4: Commit**

```bash
git add tests/scenarios/80-vault.sh
git commit -m "test: cover vault end to end, including the vaulted event"
```

---

## Task 9: Documentation

**Files:**
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: README**

Add a vault section in the user's language covering: what vault does for a self-hoster (keeps a torrent's content permanently, served from the built-in store even when the swarm is gone); that storage is unlimited by construction, so the real limit is disk; that `/storage` grows as they save things and this is intended; and the variables `USE_VAULT`, `VAULT_PG_DATABASE`, `VAULT_AWS_BUCKET`.

State plainly that with `USE_LOCALPG=false` the operator must create the vault database themselves, and name the default (`vault`).

- [ ] **Step 2: CLAUDE.md**

In Russian, matching the file's voice:

- vault and NATS in the service list and the port map (8100, 4222 — both loopback, neither proxied);
- a new section on vault covering the two mechanisms a future reader would otherwise go hunting for: its own working directory (because migration discovery is CWD-relative) and its own database (because `go-pg/migrations` keeps one version row per database). Say what breaks in each case, not just what the rule is — a silent failure is worth naming;
- NATS: the stream and four consumers, that only `resource.vaulted` carries traffic here, memory storage and what it costs, and that provisioning is a hard dependency because web-ui's event handler joins its serve group and a failed bind crash-loops it;
- the naming exception: service `nats` runs `/app/nats-server` while `/app/nats` is the CLI;
- extend the existing note that Renovate does not watch non-webtor stages — it currently names only versitygw — to cover `nats` and `nats-box`;
- add `80-vault.sh` to the list of smoke scenarios.

- [ ] **Step 3: Verify every claim against the code**

Re-read each statement and check it against the file it describes. Anything that cannot be confirmed comes out of the document rather than being written from this plan's description. Report anything removed.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: describe vault and the event bus"
```

---

## Order and dependencies

Task 1 is a prerequisite in the `vault` repository and blocks Task 2, which pins its output. Task 2b lands right after Task 2 and before Tasks 5 and 7, which edit the two files it moves — doing it later would mean writing those files twice. Tasks 2–5 are strictly sequential: each builds on the artifact the previous one puts in the image. Task 6 is in the `web-ui` repository and is independent of 2–5, but its rebuilt `web-ui:cron` image is what Tasks 7–8 test against, so it lands before them. Task 7 needs vault running. Task 8 needs everything. Task 9 lands last so it describes what shipped.

## Out of scope

- `vault verify-existing` — a manual operations command, unscheduled even in production.
- The `s3-cache` redirect path (`S3_CACHE_URL`).
- Publishing `user.updated` or `resource.banned`. Their consumers exist so subscribers can bind; nothing in this image produces those events.
- Any payment or tier integration. Quota is unlimited because `UserVP.Total` is nil, which is already the behaviour — no code change.
