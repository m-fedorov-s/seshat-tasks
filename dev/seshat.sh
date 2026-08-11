#!/usr/bin/env bash
# Build (if needed) and run the dev client against the dev server.
# Usage: dev/seshat.sh show --detailed
#        dev/seshat.sh add "Some task" high
#        dev/seshat.sh done <id-prefix>
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
(cd client/zig && zig build >/dev/null)
SESHAT_CONFIG="$PWD/dev/client.json" exec ./client/zig/zig-out/bin/seshat "$@"
