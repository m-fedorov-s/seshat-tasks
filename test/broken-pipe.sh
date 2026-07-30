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
    if (i == 0) {
      # This one task carries a real due_at (2026-08-02T22:00:00Z = 1785708000) and a
      # "tzcheck" tag, so it doubles as coverage for the client config -> CLI ->
      # formatter offset seam: 22:00 UTC is late enough in the day that the +03:00
      # offset configured in client.json below rolls it to the next local date
      # (2026-08-03) — see the local-timezone assertion after the broken-pipe check.
      printf "    \"%s\": {\"id\": \"%s\", \"content\": {\"title\": \"integration fixture task %d, deliberately long so the rendered output overflows the pipe buffer\", \"description\": \"\", \"status\": \"todo\", \"priority\": \"none\", \"child_ids\": [], \"tags\": [\"tzcheck\"], \"due_at\": 1785708000, \"scheduled_at\": null}, \"meta\": {\"created_at\": 1750000000, \"updated_at\": 1750000000, \"completed_at\": null, \"version\": 1}}", id, id, i
    } else {
      printf "    \"%s\": {\"id\": \"%s\", \"content\": {\"title\": \"integration fixture task %d, deliberately long so the rendered output overflows the pipe buffer\", \"description\": \"\", \"status\": \"todo\", \"priority\": \"none\", \"child_ids\": [], \"tags\": [], \"due_at\": null, \"scheduled_at\": null}, \"meta\": {\"created_at\": 1750000000, \"updated_at\": 1750000000, \"completed_at\": null, \"version\": 1}}", id, id, i
    }
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
{"url": "http://127.0.0.1:$port", "secret": "$secret", "utc_offset": "+03:00"}
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

# Guard against the fixture silently shrinking below the pipe buffer over time (e.g. a
# future edit trims the task count). If the unpiped output doesn't comfortably exceed the
# ~64 KiB pipe buffer, `head -1` below would never see EPIPE and this test would pass for
# the wrong reason — testing nothing. Require > 2x the buffer as a safety margin.
min_bytes=131072
actual_bytes=$(SESHAT_CONFIG="$tmp/client.json" COLUMNS=120 "$root/client/zig/zig-out/bin/seshat" show | wc -c)
if [ "$actual_bytes" -le "$min_bytes" ]; then
  echo "FAIL: unpiped 'show' output is only $actual_bytes bytes (need > $min_bytes)."
  echo "      The fixture is too small to reliably exceed the pipe buffer, which makes"
  echo "      the EPIPE assertion below vacuous — it would pass without exercising the"
  echo "      broken-pipe path at all. Raise the task count or title length in the fixture."
  exit 1
fi
echo "unpiped show output: $actual_bytes bytes (> $min_bytes, non-vacuous)"

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

# Coverage for the client config -> CLI -> formatter offset seam (client.json's
# utc_offset above): the fixture task's due_at is 2026-08-02T22:00:00Z, which the
# configured +03:00 offset rolls to 2026-08-03 local. If any of the main.zig call
# sites that thread client.config.offset_minutes into RenderOptions were dropped,
# this would render the UTC date (2026-08-02) instead.
detailed_out=$(SESHAT_CONFIG="$tmp/client.json" COLUMNS=120 \
  "$root/client/zig/zig-out/bin/seshat" show --detailed --filter tag:tzcheck)
if [[ "$detailed_out" != *"due 2026-08-03"* ]]; then
  echo "FAIL: expected 'due 2026-08-03' (local, +03:00) in --detailed output, got:"
  echo "$detailed_out"
  exit 1
fi
if [[ "$detailed_out" == *"due 2026-08-02"* ]]; then
  echo "FAIL: --detailed rendered the UTC date (2026-08-02) instead of the local (+03:00) date:"
  echo "$detailed_out"
  exit 1
fi
echo "PASS: --detailed renders due_at in the configured local (+03:00) offset"
