#!/usr/bin/env bash
# A NEW PERSON'S FIRST REQUESTS PROVISION THEM AT ONCE, AND ALL OF THEM SUCCEED
# (REM-792).
#
#     CONTAINER=p8-mine DB=p8mine dev/provision-race.sh
#
# The application provisions a person on their first request, and a first page
# load makes several requests together. rbac.provision_application_user wrote
# `on conflict (id) do nothing`, but the row's email is made from the id and
# has its own unique index, which was not an arbiter: when two calls both
# passed the id check before either wrote, the second met users_email_key and
# raised. Measured on 0.2.22: eight concurrent calls for one new id failed in
# 18 of 20 batches, and the app answered 409 at the consent page.
#
# A RACE, SO A COUNT RATHER THAN A SCRIPT. There is no way to hold a statement
# between its conflict check and its insert, so this runs the measurement that
# found it -- batches of eight concurrent calls on one new id -- and passes only
# when no call in any batch raised. Against the old function on a local
# container, 5 of 20 batches raised users_email_key; at that rate 40 batches
# pass by luck about once in 100,000 runs. The credential is raced the same way:
# its key_hash is made from its id too.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${CONTAINER:-p8-dev-db}"
DB="${DB:-p8dev}"
SU="${SUPERUSER:-p8}"
BATCHES="${BATCHES:-40}"
WIDTH=8
TMP=$(mktemp -d)
PREFIX=79200000

sql() { docker exec -i "$CONTAINER" psql -U "$SU" -d "$DB" -v ON_ERROR_STOP=1 -qtA "$@"; }
cleanup() {
    sql -c "delete from rbac.api_keys where id::text like '$PREFIX-%'" \
        -c "delete from rbac.users where id::text like '$PREFIX-%'" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup
TMP=$(mktemp -d)

# As the superuser, which rbac.is_app_provisioner() admits: the race is in the
# insert, not in who calls it, and an app_provisioner role made here after the
# install would hold none of the grants the install gives it.
#
# The eight calls start inside the container, from one shell, so they reach the
# server within milliseconds of each other. One `docker exec` per call spread
# them out enough that the race fired in 1 batch of 20.
batch() {
    docker exec -i "$CONTAINER" sh -c '
        for i in $(seq 1 '"$WIDTH"'); do
            psql -U "$0" -d "$1" -v ON_ERROR_STOP=1 -qtA -c "begin" \
                -c "select rbac.provision_application_user('"'"'$2'"'"')" \
                -c "select rbac.provision_application_credential('"'"'$3'"'"', '"'"'$2'"'"', '"'"'race'"'"', '"'"'{}'"'"')" \
                -c "commit" > /tmp/race.$i 2>&1 &
        done
        wait
        cat /tmp/race.*; rm -f /tmp/race.*' "$SU" "$DB" "$1" "$2"
}

failed_batches=0
for b in $(seq 1 "$BATCHES"); do
    user=$(printf '%s-0000-4000-8000-%012d' "$PREFIX" "$b")
    key=$(printf '%s-0000-4000-9000-%012d' "$PREFIX" "$b")
    batch "$user" "$key" > "$TMP/$b"
    if grep -q ERROR "$TMP/$b"; then
        failed_batches=$((failed_batches + 1))
        [ "$failed_batches" = 1 ] && grep -h ERROR "$TMP/$b" | sort | uniq -c | sed 's/^/    /'
    fi
done
rows=$(sql -c "select count(*) from rbac.users where id::text like '$PREFIX-%'")
keys=$(sql -c "select count(*) from rbac.api_keys where id::text like '$PREFIX-%'")
if [ "$failed_batches" = 0 ] && [ "$rows" = "$BATCHES" ] && [ "$keys" = "$BATCHES" ]; then
    echo "  $BATCHES batches of $WIDTH concurrent first provisions: every call succeeded, one person and one key each -- ok"
else
    echo "FAILED: $failed_batches of $BATCHES batches of $WIDTH concurrent first provisions raised; $rows people and $keys keys for $BATCHES"
    exit 1
fi
