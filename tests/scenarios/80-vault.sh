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

apiv1_json POST /vault/pledges --data-binary "{\"resource_id\":\"$rid\"}" >/dev/null \
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
