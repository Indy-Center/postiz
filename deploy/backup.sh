#!/usr/bin/env bash
# Postiz's backup recipe (docker-infrastructure's README, "What an app ships"). The backup runner
# calls it from ~/apps/postiz/ with one argument, an empty folder, and it writes one file there:
#
#   postiz.tar
#     databases/<name>.dump   every database on the Postgres server, each from pg_dump in its
#                             custom format: postiz (accounts, channels, posts, media) and
#                             Temporal's temporal and temporal_visibility (the workflows that
#                             publish scheduled posts). Not the empty postgres database, and no
#                             roles: the postgres image makes the postiz role from .env.
#     uploads.tar             the uploads volume: the media attached to posts.
#
# Postiz keeps running throughout. Redis is left out: it's a cache and queue Postiz refills. So is
# the config volume: Postiz v2.25.0 writes nothing to it (the round trip test checks that).
# Encrypting, uploading and pruning are the runner's job, not this script's.
#
#   bash backup.sh <empty folder>
set -euo pipefail
# The archive holds password hashes and the channels' tokens: only its owner may read it.
umask 077

out="${1:?usage: bash backup.sh <empty folder>}"
[ -d "$out" ] || { echo "backup.sh: $out is not a folder" >&2; exit 1; }
# Made absolute before the cd below, so a folder given relative to where it was called still works.
out="$(cd "$out" && pwd)"

# Run from this script's folder, so `docker compose` finds this app's compose file.
cd "$(dirname "$0")"

# Runs inside the running db container, which has pg_dump, psql and tar, so the host needs only
# Docker. It reads the uploads as a tar on stdin, and writes the finished archive to stdout;
# messages go to stderr.
archive_in_db=$(
  cat << 'SH'
set -eu
# A private working folder inside the container, removed however this ends.
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
mkdir "$dir/databases"

# postiz first, then Temporal's: a post made in between then has a workflow but no post, which
# fails harmlessly when it runs, rather than a post with no workflow, which never publishes.
dbs=$(psql -X -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -c "
  SELECT datname FROM pg_database
  WHERE NOT datistemplate AND datname <> 'postgres'
  ORDER BY datname <> '$POSTGRES_DB', datname")
for db in $dbs; do
  pg_dump -U "$POSTGRES_USER" -d "$db" --format=custom --file="$dir/databases/$db.dump"
done
[ -f "$dir/databases/$POSTGRES_DB.dump" ] || { echo "no $POSTGRES_DB database to dump" >&2; exit 1; }

# The uploads, after the dumps, so every file the postiz database names is in the archive.
cat > "$dir/uploads.tar"
tar -tf "$dir/uploads.tar" > /dev/null

# The dumps are already compressed, and the uploads are mostly images, so the archive isn't.
tar -C "$dir" -cf - databases uploads.tar
SH
)

# Write to a temporary name and rename once complete, so a failure never leaves a partial archive
# where the runner would take it for a backup, even when the runner stops this script.
trap 'rm -f "$out/postiz.tar.partial"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
docker compose exec -T app tar -C /uploads -cf - . < /dev/null \
  | docker compose exec -T db sh -c "$archive_in_db" > "$out/postiz.tar.partial" \
  || { echo "backup.sh: the backup failed" >&2; exit 1; }
mv "$out/postiz.tar.partial" "$out/postiz.tar"
echo "backup.sh: wrote $out/postiz.tar ($(du -h "$out/postiz.tar" | cut -f1))"
