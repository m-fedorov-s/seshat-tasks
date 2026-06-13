#!/usr/bin/env bash
# Build and run the seshat dev server in the foreground (Ctrl-C to stop).
# Data is stored in dev/seshat-dev-data.json (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
(cd server && go build -o seshat .)
echo "Starting seshat dev server on http://localhost:8799 (secret: devsecret)"
exec ./server/seshat -config dev/server.yaml
