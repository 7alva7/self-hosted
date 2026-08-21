#!/usr/bin/env bash
# Vault stores a torrent permanently and tells web-ui that it did.
#
# Not re-runnable against a warm container: smoke.torrent has a fixed
# infohash, so a second `POST /vault/pledges` for it answers 409 and
# assertion 5 below never sees vaulted=true. Harmless in CI, because
# tests/run.sh recreates the container for every run -- but re-invoking this
# script by hand against a container it already ran in will fail here, and
# any scenario added after this one in the suite would inherit an
# already-pledged resource if the suite ever stops being one-shot-per-run.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# psql_db <database> <sql> -- one scalar out of the embedded postgres.
psql_db() {
  webtor_exec su -s /bin/sh -c "psql -U postgres -d $1 -tAc \"$2\"" postgres </dev/null | tr -d ' \r'
}

# 1. Vault migrated its own database. If its working directory were /app it
# would find no "migrations" directory at all now (web-ui's own moved under
# /app/web-ui), so it would silently apply none of its own -- caught below
# by the missing resource/file/resource_file tables, not by the version
# number: gopg_migrations would sit at 0, comfortably under the <=8 bound
# checked further down, so that bound alone would not catch this failure.
for t in resource file resource_file; do
  got="$(psql_db vault "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='$t'")"
  assert_eq "$got" "1" "vault database is missing its own table '$t'"
done

version="$(psql_db vault "SELECT coalesce(max(version),0) FROM gopg_migrations")"
[ "$version" -le 8 ] \
  || fail "vault's database is at migration version $version, past vault's own highest migration (8) -- something applied migrations that aren't vault's"

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
# branch has to override it. That override now exists in two places (the
# wrapper and s6-rc.d/vault/run), so a rename in one and not the other
# silently restores the bug.
#
# By the time this scenario runs, app is already migrated to version 69 --
# past vault's own 8 -- so a misdirected gc does NOT quietly apply vault's
# migrations and sweep nothing: it hard-fails immediately with
# `ERROR #42P01 relation "file" does not exist`, because gc's sweep query
# reads from a table that only exists in vault's own database. That failure
# is caught by the `|| fail "cron job vault-gc-unused failed"` exit-status
# check right below, before either assert_eq further down ever runs. The two
# assert_eq's are a backstop for a different failure mode: someone changing
# the job to swallow that error and return 0 anyway, in which case the
# exit-status check would no longer notice.
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
