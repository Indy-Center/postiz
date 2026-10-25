#!/usr/bin/env bash
# Proves deploy/backup.sh and deploy/restore.sh round-trip a real Postiz: start the stack, give it
# an account, an uploaded image and a scheduled post, back up, wipe every volume, restore, and check
# all three are back, with the post's Temporal workflow still waiting to publish it. CI runs it on
# every pull request.
#
# It throws the stack's data away, so it runs as its own compose project, postiz-round-trip, unless
# COMPOSE_PROJECT_NAME says otherwise (CI points it at the stack it has just started). Never run it
# on the VPS.
#
#   bash tests/backup-round-trip.sh
# Needs Docker, and the traefik-shared network (docker network create traefik-shared).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo/deploy"

export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-postiz-round-trip}
# Throwaway values; on the VPS they come from .env.
export JWT_SECRET=${JWT_SECRET:-round-trip-not-a-secret}
export POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postiz}

work=$(mktemp -d)
cleanup() {
  docker compose down --volumes --remove-orphans > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# Prints Postiz's recent logs, then the reason, so the reason is the last line.
fail() {
  docker compose logs --tail 30 app >&2 || true
  echo "FAIL: $*" >&2
  exit 1
}

# Sends one request to Postiz from inside its own container (no ports are published), through the
# nginx on 5000 that Traefik reaches, and prints the response body. Fails on a non-2xx answer.
# A sign-in or sign-up prints the auth cookie's value instead.
# Usage: api METHOD PATH [JSON BODY] [AUTH]
api() {
  docker compose exec -T app node -e '
    const [method, path, body, auth] = process.argv.slice(1);
    const headers = { "content-type": "application/json" };
    if (auth) headers.auth = auth;
    fetch(`http://127.0.0.1:5000${path}`, { method, headers, body: body || undefined })
      .then(async (res) => {
        const text = await res.text();
        if (!res.ok) { console.error(method, path, res.status, text); process.exit(1); }
        const cookie = res.headers.getSetCookie().find((c) => c.startsWith("auth="));
        console.log(cookie ? cookie.split(";")[0].slice(5) : text);
      })
      .catch((err) => { console.error(err); process.exit(1); });
  ' "$@" < /dev/null
}

# Uploads a small PNG to Postiz's media library and prints the response. Usage: upload AUTH
upload() {
  docker compose exec -T app node -e '
    const png = Buffer.from(process.argv[2], "base64");
    const form = new FormData();
    form.append("file", new Blob([png], { type: "image/png" }), "round-trip.png");
    fetch("http://127.0.0.1:5000/api/media/upload-simple", { method: "POST", headers: { auth: process.argv[1] }, body: form })
      .then(async (res) => {
        const text = await res.text();
        if (!res.ok) { console.error("upload", res.status, text); process.exit(1); }
        console.log(text);
      })
      .catch((err) => { console.error(err); process.exit(1); });
  ' "$1" "$png" < /dev/null
}

# Prints the file at an uploads URL path, as Postiz serves it, base64-encoded. Usage: fetch_upload PATH
fetch_upload() {
  docker compose exec -T app node -e '
    fetch(`http://127.0.0.1:5000${process.argv[1]}`)
      .then(async (res) => {
        if (!res.ok) { console.error("GET", process.argv[1], res.status); process.exit(1); }
        console.log(Buffer.from(await res.arrayBuffer()).toString("base64"));
      })
      .catch((err) => { console.error(err); process.exit(1); });
  ' "$1" < /dev/null
}

# Waits up to five minutes for Postiz's backend to answer.
wait_for_app() {
  for _ in $(seq 60); do
    api GET /api/monitor/queue/round-trip > /dev/null 2>&1 && return 0
    sleep 5
  done
  fail "Postiz never answered /api/monitor/queue/round-trip"
}

# Prints the status of a Temporal workflow, such as WORKFLOW_EXECUTION_STATUS_RUNNING.
workflow_status() {
  docker compose exec -T temporal temporal workflow describe --address temporal:7233 \
    --workflow-id "$1" --output json < /dev/null | jq -r .workflowExecutionInfo.status
}

email=round-trip@example.com
password=round-trip-password
content="Made by the round trip"
# A 1×1 PNG.
png=iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==

echo "--- Start the stack, unless it's already running with no data (as in CI)"
docker compose up -d --quiet-pull
wait_for_app

echo "--- Give it data: an account, an uploaded image, a channel and a post scheduled on it"
auth=$(api POST /api/auth/register \
  "{\"email\":\"$email\",\"password\":\"$password\",\"company\":\"Round trip\",\"provider\":\"LOCAL\"}") \
  || fail "signing up failed"
[ -n "$auth" ] || fail "signing up gave no auth cookie"
image_path=$(upload "$auth" | jq -r .path)
image_path=/${image_path#*://*/}
[ "$(fetch_upload "$image_path")" = "$png" ] || fail "Postiz doesn't serve the image it just took"
# A real channel needs a network's OAuth app, so the test adds a Discord one straight to the
# database. Postiz only checks the channel exists, and the post publishes long after the test ends.
docker compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U postiz -d postiz -c '
  INSERT INTO "Integration" (id, "internalId", "organizationId", name, "providerIdentifier", type, token)
  SELECT '\''round-trip-channel'\'', '\''round-trip'\'', id, '\''Round trip'\'', '\''discord'\'', '\''social'\'', '\''not-a-token'\''
  FROM "Organization"' < /dev/null
post_id=$(api POST /api/posts "{
  \"type\": \"schedule\", \"shortLink\": false, \"date\": \"2099-01-01T12:00:00\", \"tags\": [],
  \"posts\": [{
    \"integration\": {\"id\": \"round-trip-channel\"},
    \"value\": [{\"content\": \"$content\", \"image\": []}],
    \"settings\": {\"__type\": \"discord\", \"channel\": \"1\"}
  }]
}" "$auth" | jq -r '.[0].postId')
[ -n "$post_id" ] && [ "$post_id" != null ] || fail "creating the post gave no post id"
# Postiz starts the post's workflow without waiting for it, so give it a moment.
for _ in $(seq 10); do
  [ "$(workflow_status "post_$post_id" 2> /dev/null)" = WORKFLOW_EXECUTION_STATUS_RUNNING ] && break
  sleep 2
done
[ "$(workflow_status "post_$post_id")" = WORKFLOW_EXECUTION_STATUS_RUNNING ] \
  || fail "the post's Temporal workflow isn't running"

echo "--- Back up, with Postiz running"
mkdir "$work/out"
# Called from elsewhere with a relative folder, as a person might.
(cd "$work" && bash "$repo/deploy/backup.sh" out) || fail "backup.sh exited non-zero"
files=("$work/out"/*)
[ "${#files[@]}" -eq 1 ] && [ -f "${files[0]}" ] || fail "backup.sh must write exactly one file, wrote: $(ls -A "$work/out")"
backup=${files[0]}
# The runner (and the deploy user) must be able to read and delete what the recipe wrote.
[ -O "$backup" ] || fail "the backup is not owned by the user who ran backup.sh"
# It holds password hashes and the channels' tokens, so nobody else may read it.
[ "$(stat -c %a "$backup")" = 600 ] || fail "the backup's mode is $(stat -c %a "$backup"), not 600"

# Postiz's compose file mounts a config volume, but v2.25.0 writes nothing there, so the recipe
# leaves it out. If an upgrade starts keeping something in it, this fails, and the recipe must
# back it up.
config=$(docker compose exec -T app ls -A /config < /dev/null)
[ -z "$config" ] || fail "Postiz now keeps files in /config, which backup.sh doesn't back up: $config"

echo "--- A file that isn't a backup, or a backup without Postiz's database, is refused"
echo "not a backup" > "$work/not-a-backup.tar"
mkdir "$work/partial"
tar -xf "$backup" -C "$work/partial"
rm "$work/partial/databases/postiz.dump"
tar -cf "$work/no-postiz-database.tar" -C "$work/partial" .
for bad in not-a-backup no-postiz-database; do
  if bash restore.sh "$work/$bad.tar"; then fail "restore.sh accepted $bad.tar"; fi
  [ -n "$(docker compose ps -q --status running app)" ] || fail "refusing $bad.tar stopped Postiz"
  [ ! -e restore-failed ] || fail "refusing $bad.tar left the restore-failed marker"
done
api POST /api/auth/login "{\"email\":\"$email\",\"password\":\"$password\",\"provider\":\"LOCAL\"}" > /dev/null \
  || fail "a refused restore changed the database"

echo "--- Restore over the running stack: uploads made since the backup go, lost ones come back"
docker compose exec -T app sh -c "rm '/uploads${image_path#/uploads}' && touch /uploads/after-the-backup.png" < /dev/null
bash restore.sh "$backup" || fail "restore.sh over the running stack exited non-zero"
[ "$(fetch_upload "$image_path")" = "$png" ] || fail "restoring over the running stack didn't bring the image back"
docker compose exec -T app test ! -e /uploads/after-the-backup.png < /dev/null \
  || fail "restoring over the running stack kept a file uploaded after the backup"
[ "$(workflow_status "post_$post_id")" = WORKFLOW_EXECUTION_STATUS_RUNNING ] \
  || fail "restoring over the running stack lost the post's workflow"

echo "--- Wipe the stack and its volumes, as on a rebuilt server"
docker compose down --volumes
left=$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")
[ -z "$left" ] || fail "the volumes were not removed: $left"

echo "--- Restore"
bash restore.sh "$backup" || fail "restore.sh exited non-zero"
[ ! -e restore-failed ] || fail "restore.sh succeeded but left its restore-failed marker"

# restore.sh only returns once Postiz answers, so no waiting here.
echo "--- Check the data came back"
auth=$(api POST /api/auth/login "{\"email\":\"$email\",\"password\":\"$password\",\"provider\":\"LOCAL\"}") \
  || fail "the account can't sign in"
api GET "/api/posts/$post_id" '' "$auth" | jq -e --arg content "$content" \
  '.posts[0].content == $content and .posts[0].state == "QUEUE"' > /dev/null \
  || fail "the scheduled post didn't come back"
[ "$(workflow_status "post_$post_id")" = WORKFLOW_EXECUTION_STATUS_RUNNING ] \
  || fail "the post's Temporal workflow didn't come back"
[ "$(fetch_upload "$image_path")" = "$png" ] || fail "the uploaded image didn't come back"

echo "PASS: account, scheduled post, its workflow and the uploaded image survived backup and restore"
