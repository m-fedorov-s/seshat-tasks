#!/usr/bin/env bash
# Pre-release smoke test: builds both images and pokes a server container run with the same
# hardening as compose.yaml. Local only (`make docker-smoke`); CI does not run it.
# Needs a Docker daemon with buildx, plus curl, sed and tar.
# An interrupted run can leave a container or volume named seshat-smoke-<pid>.
set -euo pipefail

cd "$(dirname "$0")/.."
ver=v0.0.0-smoke
name=seshat-smoke-$$     # the server container and its volume
img=seshat:smoke-$$
botimg=seshat-bot:smoke-$$
admin=smoke-admin-token-smoke-admin-token     # >= 32 chars
tmp=$(mktemp -d)
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$name" >/dev/null 2>&1 || true
  docker image rm -f "$img" "$botimg" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
# The docker CLI swallows Ctrl-C and returns normally; without this the script would carry on.
trap 'exit 130' INT TERM
fail() {
  echo "FAIL: $1"
  docker container inspect "$name" >/dev/null 2>&1 && docker logs "$name" 2>&1 | tail -20
  exit 1
}

docker build -q -f docker/Dockerfile.server --build-arg VERSION=$ver -t "$img" . >/dev/null \
  || fail "server image build (make docker-build shows why)"
docker build -q -f docker/Dockerfile.bot --build-arg VERSION=$ver -t "$botimg" . >/dev/null \
  || fail "bot image build (make docker-build shows why)"

user=$(docker inspect --format '{{.Config.User}}' "$img")
[ "$user" = 65532:65532 ] || fail "server image user: want 65532:65532, got $user"

# The only check that -X main.version= in each Dockerfile still names a real variable.
got=$(docker run --rm "$img" -version)
[ "$got" = "seshat-server $ver" ] || fail "server -version: got '$got'"
got=$(docker run --rm "$botimg" -version)
[ "$got" = "seshat-bot $ver" ] || fail "bot -version: got '$got'"

# The bot cannot run without Telegram, but refusing an empty config shows it found its file.
printf '{"bot_token": ""}\n' > "$tmp/bot.json"
chmod 444 "$tmp/bot.json"
got=$(docker run --rm -v "$tmp/bot.json":/run/secrets/seshat_bot_config:ro "$botimg" 2>&1 || true)
case $got in
  *"config /run/secrets/seshat_bot_config: empty bot_token"*) ;;
  *) fail "bot config path: got '$got'" ;;
esac

# World-readable rather than chowned to 65532, so the test needs no sudo; the server warns.
printf '%s\n' "$admin" > "$tmp/admin_token"
chmod 444 "$tmp/admin_token"
docker run -d --name "$name" -p 127.0.0.1::8799 \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  -v "$name":/var/lib/seshat \
  -v "$tmp/admin_token":/run/secrets/seshat_admin_token:ro \
  -e SESHAT_ADMIN_TOKEN_FILE=/run/secrets/seshat_admin_token "$img" >/dev/null
url=http://$(docker port "$name" 8799/tcp) || fail "the server container exited at startup"

# There is no healthcheck to wait on (every unauthenticated response is a 403), so poll.
code=000
for _ in $(seq 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$url/api/tasks/get" || true)
  [ "$code" != 000 ] && break
  sleep 0.2
done
[ "$code" = 403 ] || fail "unauthenticated request: want 403, got $code"

resp=$(printf 'Authorization: %s\n' "$admin" | curl -fsS -X POST -H @- "$url/api/admin/users/add") \
  || fail "admin users/add"
token=$(printf '%s' "$resp" | sed -n 's/.*"token":"\([0-9a-f]\{64\}\)".*/\1/p')
[ -n "$token" ] || fail "admin users/add returned no token: $resp"

code=$(printf 'Authorization: %s\n' "$token" | curl -s -o /dev/null -w '%{http_code}' -H @- "$url/api/tasks/get" || true)
[ "$code" = 200 ] || fail "user token: want 200, got $code"

# The named volume took the image directory's owner and mode on first use.
own=$(docker cp "$name":/var/lib/seshat - | tar -tv | cut -d' ' -f1,2 | tr '\n' ' ')
[ "$own" = "drwx------ 65532/65532 -rw------- 65532/65532 " ] || fail "volume ownership: got '$own'"

echo "PASS: docker smoke"
