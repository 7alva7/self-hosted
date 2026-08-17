#!/usr/bin/env bash
# All s6 services come up and the front door answers.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

wait_for 180 "web-ui front page" curl -fsS "$BASE_URL/"

code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")"
assert_eq "$code" "200" "front page status"

# rest-api must be reachable through the nginx /rest-api/ prefix.
wait_for 60 "rest-api swagger" curl -fsS "$BASE_URL/rest-api/swagger/index.html"

echo "PASS: boot"
