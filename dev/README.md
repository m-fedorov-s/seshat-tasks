# Local dev environment

Throwaway configs + scripts to run the seshat **server + client** locally and eyeball the
`show` rendering. The dev secret is `devsecret` and the server listens on `localhost:8799`.
(The generated data file `dev/seshat-dev.db` is gitignored.)

## One-time prerequisites
- Go (for the server), Zig 0.16 (for the client), and `jq` (for the seed script).
- `curl`, `awk`, and `seq` — needed by `test/broken-pipe.sh` (`make client-integration-test`).

## Quick start

```sh
# 1. Start the server (foreground; Ctrl-C to stop). Builds it first.
dev/run-server.sh

# 2. In another terminal: seed a realistic dataset (roots, subtasks, tags,
#    due/scheduled dates, an overdue task, a done subtask, descriptions).
dev/seed.sh

# 3. Run the client against the dev server (builds it first):
dev/seshat.sh show
dev/seshat.sh show --detailed
dev/seshat.sh show --flat --sort urgency
dev/seshat.sh show --filter tag:work
dev/seshat.sh show --open
dev/seshat.sh show --json | jq .
dev/seshat.sh done <id-prefix>     # mutate, then re-run show
```

## Seeing color
The client only emits ANSI color when stdout is a TTY (so pipes/`--json` stay clean). Running
`dev/seshat.sh show` directly in your terminal shows color. To capture colored output to a file
for inspection, force a pty:

```sh
script -qec "dev/seshat.sh show --detailed" /dev/null > out.txt
cat -v out.txt   # reveal the raw ANSI escape bytes
```

## Files
- `server.yaml` — dev server config (secret/port/data_file/bind/rate_limit; `bind` defaults to
  `127.0.0.1`, `rate_limit` defaults to 10 req/s with burst 2x).
- `client.json` — dev client config (`SESHAT_CONFIG` points here).
- `run-server.sh` — build + run the server.
- `seed.sh` — POST a realistic dataset to the running server.
- `seshat.sh` — build + run the client against the dev server.
- `../test/broken-pipe.sh` — integration test: piped output must exit 0 (`make client-integration-test`).

## Reset
Stop the server, `rm dev/seshat-dev.db`, start it again and re-seed. Do not delete
`dev/seshat-dev-data.json` — that is the pre-Stage-2 dataset, and it can be loaded into a
running dev server with `go run ./test/seed -token devsecret dev/seshat-dev-data.json`.

Also available as `make dev-server` and `make dev-seed`.
