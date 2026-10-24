#!/usr/bin/env bash
# Puts a backup made by backup.sh back into Postiz (docker-infrastructure's README, "What an app
# ships"). Run it as deploy from ~/apps/postiz/, with the decrypted postiz.tar the runner's helpers
# fetched:
#
#   bash restore.sh <path to postiz.tar>
#
# It replaces every database in the backup (postiz, temporal, temporal_visibility) and the uploads
# volume with the backup's: anything changed since that backup is lost. Postiz, Temporal and Redis
# are stopped while it runs. Redis keeps no data Postiz can't refill, so it is left as it is.

# The single-quoted commands below are expanded inside the containers, not here.
# shellcheck disable=SC2016
set -euo pipefail

backup="${1:?usage: bash restore.sh <path to postiz.tar>}"
[ -f "$backup" ] || { echo "restore.sh: no such file: $backup" >&2; exit 1; }
backup="$(cd "$(dirname "$backup")" && pwd)/$(basename "$backup")"

# Run from this script's folder, so `docker compose` finds this app's compose file.
cd "$(dirname "$0")"

say() { echo "restore.sh: $*"; }

# Where the backup is unpacked inside the db container. Commands run there by in_db get it as
# $RESTORE_DIR. It is removed however this script ends.
work=/tmp/restore
in_db() { docker compose exec -T -e RESTORE_DIR="$work" db "$@"; }
trap 'in_db rm -rf "$work" < /dev/null || true' EXIT

# 1. Make sure the database is running (after a rebuild it may not be yet), then unpack the backup
#    inside it and check every part is readable, all before Postiz is touched. A bad file stops
#    here with Postiz still up.
say "starting the database if it isn't running"
docker compose up -d --wait db
say "checking $backup"
unreadable() { say "$backup isn't a readable backup from backup.sh; nothing was changed" >&2; exit 1; }
in_db sh -c 'rm -rf "$RESTORE_DIR" && mkdir "$RESTORE_DIR" && tar -x -C "$RESTORE_DIR"' \
  < "$backup" || unreadable
in_db sh -c '
  set -eu
  cd "$RESTORE_DIR"
  [ -f "databases/$POSTGRES_DB.dump" ] && [ -f uploads.tar ]
  for dump in databases/*.dump; do pg_restore --list "$dump" > /dev/null; done
  tar -tf uploads.tar > /dev/null
' < /dev/null || unreadable

# 2. Stop Postiz, Temporal and Redis, so nothing writes while the data is replaced. From here until
#    it has all been put back, the restore-failed marker in this folder stops the deploy
#    (build-and-deploy.yml) starting Postiz on a missing or half-loaded database. It stays if this
#    script fails or is interrupted.
say "stopping Postiz, Temporal and Redis"
touch restore-failed
docker compose stop app temporal redis

stay_stopped() {
  # Started against an empty database, Postiz would let anyone sign up and own the workspace, so
  # it stays stopped until a restore succeeds, and deploys refuse to start it.
  say "$1, so Postiz is left stopped, and deploys will refuse to start it." >&2
  say "Fix the cause and run restore.sh again. Don't start Postiz by hand on this data." >&2
  exit 1
}

# 3. Replace each database in the backup: drop it (closing any connections left), create it empty,
#    and load its dump in one transaction. Postiz's schema comes with it; Postiz brings it up to
#    date itself when it starts. This runs against the "postgres" database, since the one being
#    replaced can't be dropped while connected to it.
say "replacing the databases"
in_db sh -c '
  set -eu
  for dump in "$RESTORE_DIR"/databases/*.dump; do
    db=$(basename "$dump" .dump)
    echo "restore.sh: loading $db"
    dropdb -U "$POSTGRES_USER" --maintenance-db=postgres --force --if-exists "$db"
    createdb -U "$POSTGRES_USER" --maintenance-db=postgres --owner="$POSTGRES_USER" "$db"
    pg_restore -U "$POSTGRES_USER" -d "$db" --no-owner --single-transaction --exit-on-error "$dump"
  done
' < /dev/null || stay_stopped "loading the databases failed"

# 4. Replace the uploads volume's contents, in a throwaway container of the app's image, which
#    mounts the same volumes. traefik.enable=false keeps Traefik from routing visitors to it.
say "replacing the uploads"
in_db cat "$work/uploads.tar" < /dev/null \
  | docker compose run --rm --no-deps -T --label traefik.enable=false --entrypoint sh app -c '
      set -eu
      find /uploads -mindepth 1 -delete
      tar -x -C /uploads
    ' || stay_stopped "putting back the uploads failed"
rm -f restore-failed

# 5. Start everything again, and wait up to 5 minutes for Postiz to answer. It only does once it
#    has reached Postgres and registered its search attributes in Temporal.
say "starting Postiz"
# up, not start: after a rebuild there are no containers yet to start.
docker compose up -d
for _ in $(seq 60); do
  if docker compose exec -T app node -e '
    fetch("http://127.0.0.1:5000/api/monitor/queue/restore")
      .then((res) => process.exit(res.ok ? 0 : 1))
      .catch(() => process.exit(1));
  ' < /dev/null 2> /dev/null; then
    say "done: Postiz is back up on the restored data"
    exit 0
  fi
  sleep 5
done
say "the data was restored, but Postiz hasn't answered in 5 minutes: see docker compose logs app" >&2
exit 1
