#!/usr/bin/env bash
# Build and run the seshat dev server in the foreground (Ctrl-C to stop).
# Data is stored in dev/seshat-dev.db (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
(cd server && go build -o seshat .)
# The committed copy is mode 0644 (git can't carry 0600); tighten it before the server's
# own permission warning fires on it. See test/broken-pipe.sh for the same fix.
chmod 600 dev/server.yaml
echo "Starting seshat dev server on http://localhost:8799 (admin token in dev/server.yaml)"
exec ./server/seshat -config dev/server.yaml
