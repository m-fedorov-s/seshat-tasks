#!/usr/bin/env bash
# Regression test: piping client output to a consumer that closes early (`| head`)
# must exit 0 with no stack trace. Unix convention treats EPIPE as a clean stop.
# Blocks Stage 3 (the prompt hook captures output through a pipe).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
port=8811
secret=integrationsecret
tmp=$(mktemp -d)
pid=""
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# A data file big enough that the client's output cannot fit in the pipe buffer.
awk 'BEGIN {
  printf "{\n  \"data_format_version\": 1,\n  \"state_version\": 1,\n  \"tasks\": {\n"
  for (i = 0; i < 2000; i++) {
    id = sprintf("01ABCDEFGHJKMNPQRSTV%06d", i)
    if (i > 0) printf ",\n"
    printf "    \"%s\": {\"id\": \"%s\", \"content\": {\"title\": \"integration fixture task %d, deliberately long so the rendered output overflows the pipe buffer\", \"description\": \"\", \"status\": \"todo\", \"priority\": \"none\", \"child_ids\": [], \"tags\": [], \"due_at\": null, \"scheduled_at\": null}, \"meta\": {\"created_at\": 1750000000, \"updated_at\": 1750000000, \"completed_at\": null, \"version\": 1}}", id, id, i
  }
  printf "\n  }\n}\n"
}' > "$tmp/data.json"

cat > "$tmp/server.yaml" <<EOF
secret: $secret
bind: 127.0.0.1
port: $port
data_file: $tmp/data.json
EOF
# Otherwise warnIfPermissive fires on every run and clutters server.log.
chmod 600 "$tmp/server.yaml"

cat > "$tmp/client.json" <<EOF
{"url": "http://127.0.0.1:$port", "secret": "$secret"}
EOF

echo "building server + client..."
(cd "$root/server" && go build -o "$tmp/seshat-server" .)
(cd "$root/client/zig" && zig build)

"$tmp/seshat-server" -config "$tmp/server.yaml" >"$tmp/server.log" 2>&1 &
pid=$!

ready=0
for _ in $(seq 1 50); do
  if curl -sf -H "Authorization: $secret" "http://127.0.0.1:$port/api/tasks/get" -o /dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  if grep -q "address already in use" "$tmp/server.log"; then
    echo "FAIL: port $port is already in use — stop whatever is bound to it and re-run"
  else
    echo "FAIL: server did not become ready"
  fi
  cat "$tmp/server.log"
  exit 1
fi

# The pipeline itself is expected to "fail" under pipefail, so disable errexit and
# read the client's own status out of PIPESTATUS.
set +e
SESHAT_CONFIG="$tmp/client.json" COLUMNS=120 \
  "$root/client/zig/zig-out/bin/seshat" show 2>"$tmp/client.err" | head -1 >/dev/null
code=${PIPESTATUS[0]}
set -e

if [ "$code" -ne 0 ]; then
  echo "FAIL: 'seshat show | head -1' exited $code, expected 0"
  cat "$tmp/client.err"
  exit 1
fi
if [ -s "$tmp/client.err" ]; then
  echo "FAIL: expected empty stderr, got:"
  cat "$tmp/client.err"
  exit 1
fi

echo "PASS: broken pipe exits 0 with no stack trace"
