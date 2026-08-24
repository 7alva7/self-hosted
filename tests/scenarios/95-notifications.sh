#!/usr/bin/env bash
# The in-app notification feed: a vault pledge should leave the pledging
# user a feed entry even though this container has no SMTP configured and
# the pledging account is the self-hosted admin sentinel (email literally
# "admin", not empty -- see services/notification/deliverable.go in web-ui).
#
# Depends on 80-vault.sh having already run in this same container: it is
# the one that pledges the fixture torrent and waits for vaulted=true. This
# scenario does not repeat that pledge -- 80-vault.sh's own header notes
# smoke.torrent has a fixed infohash, so a second POST /vault/pledges for it
# answers 409 -- it reads the notification that pledge's resolution should
# have produced. The numeric prefix (95 after 80) is load-bearing: run.sh
# iterates scenarios in that sorted order within one container lifetime.
#
# Not re-runnable against a warm container, for the same reason 80-vault.sh
# isn't: a second run finds the same 'webtor-smoke' resource and the same
# notification row already there (harmless -- the assertions below don't
# care how many prior runs produced it), but a second run's own steps 3-4
# (mark-all-read) will have already flipped read_at on a previous run,
# so the "badge visible before markRead" half of assertion 4 would fail
# under a warm re-run. CI always starts from a fresh container.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# psql_db <database> <sql> -- one flat |-separated row (or scalar) out of
# the embedded postgres. Same helper as 80-vault.sh; the query below sticks
# to single-quoted literals and unquoted identifiers, so it doesn't hit the
# double-quoting trap a reserved identifier (e.g. "user") would run into
# through this su -c / sh -c / psql -tAc quoting stack.
psql_db() {
  webtor_exec su -s /bin/sh -c "psql -U postgres -d $1 -tAc \"$2\"" postgres </dev/null | tr -d '\r'
}

split_status() {
  STATUS="${1##*HTTPSTATUS:}"
  BODY="${1%HTTPSTATUS:*}"
}

# --- 1 & 2. The pledge produced a feed row, and it was never mailed -------
#
# Joined against vault.resource by name rather than a hardcoded infohash:
# ties this query to the actual resource 80-vault.sh vaulted instead of a
# magic string that would silently stop matching if the fixture ever changed.
_NOTIF_ROW_FILE="$(mktemp)"
jar="$(mktemp)"
trap 'rm -f "$_NOTIF_ROW_FILE" "$jar"' EXIT

fetch_notif_row() {
  local row
  row="$(psql_db app "SELECT n.notification_id, n.user_id, n.mailed_at, n.read_at, n.title FROM notification n JOIN vault.resource r ON n.key = 'vaulted-' || r.resource_id WHERE r.name = 'webtor-smoke' ORDER BY n.created_at DESC LIMIT 1")"
  [ -n "$row" ] || return 1
  printf '%s' "$row" > "$_NOTIF_ROW_FILE"
}
wait_for 30 "a notification row for the vaulted 'webtor-smoke' resource" fetch_notif_row

row="$(cat "$_NOTIF_ROW_FILE")"
IFS='|' read -r notification_id user_id mailed_at read_at title <<<"$row"

[ -n "$notification_id" ] || fail "notification row for the vaulted pledge has no notification_id: '$row'"
[ -n "$user_id" ] || fail "notification row for the vaulted pledge has user_id NULL (want the admin's user id): '$row'"

# The assertion this scenario exists for: before the notification project's
# fix, smtpMailer.Send returned nil with no SMTP_HOST configured, so
# Service.Send could not tell "delivered" from "never attempted" and stamped
# mailed_at anyway. That lie fed straight into the 24h dedupe, which then
# suppressed the real send once SMTP was configured. A non-null mailed_at
# here, on a container with no SMTP_HOST set at all, is that regression.
[ -z "$mailed_at" ] || fail "notification row has mailed_at='$mailed_at' even though this container has no SMTP configured -- Service.Send is claiming a delivery that never happened (the journal-lying bug this scenario exists to catch)"

[ -n "$title" ] || fail "notification row for the vaulted pledge has an empty title"

# --- 3. GET /notifications renders the entry ------------------------------
#
# Session cookie only, no API key: /notifications is a session-authed HTML
# page (auth.HasAuth), not part of /api/v1. This container has no
# ADMIN_PASSWORD (see 90-api.sh's comment on the same open-instance
# behavior), so the first request auto-registers the caller as the admin
# user -- the same account 80-vault.sh's pledge ran as -- without a login
# step.
resp="$(curl -sS -c "$jar" -b "$jar" -w 'HTTPSTATUS:%{http_code}' "$BASE_URL/notifications")"
split_status "$resp"
assert_eq "$STATUS" "200" "GET /notifications status"
# Body matches use a herestring, never `printf ... | grep -q`. Under
# `set -o pipefail` (tests/lib.sh) that pipeline reports failure when grep
# exits on its first match and printf is still writing: the write dies with
# EPIPE and pipefail surfaces it, so a body that DOES match is reported as a
# miss. It bit the navbar check below, whose page is the largest response the
# suite fetches. Same reason `grep -m1` replaces `| head -1` further down.
grep -qF "$title" <<<"$BODY" \
  || fail "GET /notifications body does not contain the notification's title ('$title')"

# --- 4. Navbar badge before/after POST /notifications/read ----------------
#
# nav.html only emits the badge markup at all when
# {{ if gt $.UnreadNotifications 0 }} -- it isn't a hidden element toggled
# by CSS, so its absence from the body is a real assertion about server
# state, not a rendering nuance.
home_before="$(curl --fail-with-body -sS -c "$jar" -b "$jar" "$BASE_URL/")" \
  || fail "GET / (before markRead) failed"
grep -q 'notification-badge' <<<"$home_before" \
  || fail "navbar on / shows no unread badge before POST /notifications/read, even though the vaulted-pledge notification is unread"

csrf_token="$(grep -m1 -o 'name="_csrf" value="[^"]*"' <<<"$BODY" | sed -E 's/.*value="([^"]*)".*/\1/')"
[ -n "$csrf_token" ] || fail "GET /notifications did not render a _csrf token to submit to /notifications/read"

curl --fail-with-body -sS -c "$jar" -b "$jar" \
  -X POST --data-urlencode "_csrf=$csrf_token" \
  "$BASE_URL/notifications/read" >/dev/null \
  || fail "POST /notifications/read was rejected"

home_after="$(curl --fail-with-body -sS -c "$jar" -b "$jar" "$BASE_URL/")" \
  || fail "GET / (after markRead) failed"
grep -q 'notification-badge' <<<"$home_after" \
  && fail "navbar on / still shows the unread badge after POST /notifications/read"

# --- 5. Profile offers no email input: no SMTP configured -----------------
#
# templates/views/profile/get.html gates the whole section on
# Data.ShowEmailSection (identityEditable && MailConfigured()), not just
# hiding the input -- so the id="email" wrapper div is entirely absent from
# the response body, not merely empty or disabled.
profile_body="$(curl --fail-with-body -sS -c "$jar" -b "$jar" "$BASE_URL/profile")" \
  || fail "GET /profile failed"
grep -q 'id="email"' <<<"$profile_body" \
  && fail "GET /profile renders the notification-email input section even though no SMTP is configured"

echo "PASS: notifications"
