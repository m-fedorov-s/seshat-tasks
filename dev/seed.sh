#!/usr/bin/env bash
# Seed a realistic task dataset into the running dev server via the API.
# Requires: a running dev server (dev/run-server.sh) and `jq`.
# Usage: dev/seed.sh        (override URL/SECRET via env if needed)
set -euo pipefail
URL=${SESHAT_URL:-http://localhost:8799}
SECRET=${SESHAT_SECRET:-devsecret}

command -v jq >/dev/null || { echo "this script needs 'jq'"; exit 1; }

now=$(date +%s); day=86400
overdue=$((now - 3*day)); soon=$((now + 2*day)); later=$((now + 6*day)); tomorrow=$((now + day))

# add <content-json> [parent-id-json] -> prints the new task id
add() {
  local content="$1" parent="${2:-null}"
  curl -fsS -H "Authorization: $SECRET" -H "Content-Type: application/json" \
    -d "{\"content\":${content},\"parent_id\":${parent}}" \
    "$URL/api/tasks/add" | jq -r '.task.id'
}

echo "Seeding $URL ..."

work=$(add '{"title":"Work","status":"in_progress","priority":"high","tags":["work"],"description":"Main work project for Q3"}')
add "{\"title\":\"Write Q3 report\",\"status\":\"in_progress\",\"priority\":\"high\",\"tags\":[\"work\",\"reports\"],\"due_at\":$soon,\"description\":\"Cover all KPIs and team metrics\"}" "\"$work\"" >/dev/null
add "{\"title\":\"Review PRs from Alice\",\"status\":\"todo\",\"priority\":\"medium\",\"tags\":[\"work\",\"review\"],\"due_at\":$later}" "\"$work\"" >/dev/null
add '{"title":"Sync with manager","status":"done","priority":"low","tags":["work"]}' "\"$work\"" >/dev/null

personal=$(add '{"title":"Personal","status":"todo","priority":"medium","tags":["home"]}')
add "{\"title\":\"Buy birthday gift for Sam\",\"status\":\"todo\",\"priority\":\"medium\",\"tags\":[\"home\",\"shopping\"],\"due_at\":$later,\"scheduled_at\":$tomorrow,\"description\":\"He likes hiking gear\"}" "\"$personal\"" >/dev/null

add "{\"title\":\"Submit tax extension\",\"status\":\"todo\",\"priority\":\"high\",\"tags\":[\"finance\",\"urgent\"],\"due_at\":$overdue,\"description\":\"Need to file by the deadline!\"}" >/dev/null
add '{"title":"Set up home lab NAS","status":"in_progress","priority":"medium","tags":["home","tech"],"description":"Install TrueNAS on the old Dell"}' >/dev/null
add "{\"title\":\"Read \\\"Deep Work\\\" book\",\"status\":\"todo\",\"priority\":\"low\",\"tags\":[\"reading\"],\"scheduled_at\":$((now + 5*day))}" >/dev/null

echo "Done. Try: dev/seshat.sh show   |   dev/seshat.sh show --detailed"
