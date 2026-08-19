#!/usr/bin/env bash
# All s6 services come up and the front door answers.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

wait_for 180 "web-ui front page" curl -fsS "$BASE_URL/"

code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")"
assert_eq "$code" "200" "front page status"

# rest-api must be reachable through the nginx /rest-api/ prefix.
wait_for 60 "rest-api swagger" curl -fsS "$BASE_URL/rest-api/swagger/index.html"

# The two checks above only prove web-ui and rest-api are up. Nothing else in
# the suite touches magnet2torrent or external-proxy (no scenario resolves a
# magnet link or exercises the ~ext leg), so a dependency bump that ships a
# binary which exits on start (renamed flag, moved path, missing runtime lib)
# would otherwise leave all seven scenarios green. Check every s6 service
# that's supposed to run is actually up, inside the container.
#
# Note this can't use `s6-rc list <bundle>`: that reports a service as "up"
# based on s6-rc's scheduling state, which does not change when a running
# service is forced down (verified with `s6-svc -d` on a live container --
# the service disappeared from `s6-svstat` output but stayed listed by
# `s6-rc list user`). `s6-svstat` against the live /run/service/<name>
# supervise directory is the thing that actually reflects process state.
#
# The expected set is derived from s6-overlay/s6-rc.d/user/contents.d/ (the
# "user" bundle -- what gets started at boot) rather than hardcoded, so
# adding a service to the image automatically extends this check. Oneshots
# (currently just generate-api-key-and-secret) run once to completion and
# are never supervised in /run/service, so they're excluded -- there's
# nothing to poll "up" for.
S6_RC_DIR="$REPO_ROOT/s6-overlay/s6-rc.d"
CONTENTS_DIR="$S6_RC_DIR/user/contents.d"

s6_longrun_services() {
  local svc
  for entry in "$CONTENTS_DIR"/*; do
    svc="$(basename "$entry")"
    [ "$(cat "$S6_RC_DIR/$svc/type")" = "longrun" ] || continue
    printf '%s\n' "$svc"
  done
}

s6_missing_services() {
  # Service names never contain whitespace, so word-splitting this is safe --
  # deliberately avoiding `while read ... < <(...)`: `docker compose exec`
  # inherits stdin, and the first iteration's exec call drained the rest of
  # the process-substitution pipe before the loop could read past it,
  # silently short-circuiting the check after one service.
  local svc missing=() services
  services="$(s6_longrun_services)"
  for svc in $services; do
    webtor_exec /command/s6-svstat "/run/service/$svc" </dev/null 2>/dev/null | grep -q '^up' \
      || missing+=("$svc")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "not up: ${missing[*]}" >&2
    return 1
  fi
}

wait_for 60 "all s6 services up" s6_missing_services

echo "PASS: boot"
