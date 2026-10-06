# Running seshat with Docker

Two images, `ghcr.io/m-fedorov-s/seshat` (the server) and `ghcr.io/m-fedorov-s/seshat-bot` (the
optional Telegram bot), and one `compose.yaml`. The server runs as a non-root user on a read-only
filesystem with no capabilities, keeps its data in a named volume, takes its admin token from a
file, and is published on loopback only: a reverse proxy in front of it terminates TLS.

Every command here works as written in bash, zsh and fish (3.4 or later).

> **Before the first release** the images are not on GHCR and `compose.yaml` is not on `main`.
> Until then, work from a checkout: build the images with `make docker-build`, copy
> `docker/compose.yaml` into `~/seshat` instead of running the `curl` below, and change its two
> `image:` lines to `seshat:dev` and `seshat-bot:dev`.

## Prerequisites

- Docker, as the usual root daemon, with the compose plugin: `docker compose version` must
  succeed. It is a separate package on several distros.
- `openssl` and `curl`.
- Network access to Docker Hub: the helper commands below pull `alpine` and run it as root on
  `secrets/` and on the data volume.
- For clients on other machines, a reverse proxy with a TLS certificate
  ([below](#reverse-proxy)).

## Set up

```sh
mkdir -p ~/seshat && cd ~/seshat
curl -fsSLO https://raw.githubusercontent.com/m-fedorov-s/seshat-tasks/main/docker/compose.yaml
```

Every command below is run from this directory.

### 1. The admin token

```sh
umask 077
mkdir -p secrets ~/.config/seshat
openssl rand -hex 32 > secrets/admin_token \
    && printf 'Authorization: %s\n' "$(cat secrets/admin_token)" > ~/.config/seshat/admin.hdr \
    && docker run --rm -v "$PWD/secrets":/s alpine \
        sh -c 'chown 65532:65532 /s/admin_token && chmod 400 /s/admin_token' \
    || echo "STOP: the token is not set up; do not go on"
```

The server runs as UID 65532, and compose hands a secret file to the container with the host
file's own owner and mode, so `secrets/admin_token` has to belong to 65532. The last command
does that from a throwaway container, because the Docker daemon is already root;
`sudo chown 65532:65532 secrets/admin_token && sudo chmod 400 secrets/admin_token` does the same.

**After it only root can read that file.** `~/.config/seshat/admin.hdr` is your copy, written
first, in the form `curl -H @file` takes: that keeps the token out of the process list, where
`-H "Authorization: …"` would put it. The commands are one chain, so a failure stops everything
after it. Running the block a second time changes nothing: the token file is no longer yours to
overwrite, so it prints `Permission denied` and the STOP line. (As root it writes a new token
instead; restart the server afterwards.) `umask 077` keeps both files private from the moment
they exist, and lasts until you close this shell.

To start over, `rm -f secrets/admin_token`, run the block again, and restart the server if it is
running. If you lose `admin.hdr`, root can still read the token:
`docker run --rm -v "$PWD/secrets":/s:ro alpine cat /s/admin_token`.

### 2. Start it

```sh
docker compose up -d
docker compose logs seshat
```

**Always read the logs after the first `up -d`.** A server that refuses to start still shows as
`Started`. A good start looks like this, after the timestamps:

```text
no config file at /home/nonroot/config.yaml; using environment and defaults
config bind=0.0.0.0 (SESHAT_BIND)
config port=8799 (SESHAT_PORT)
config data_file=/var/lib/seshat/seshat.db (SESHAT_DATA_FILE)
config rate_limit=10 (default)
admin token from SESHAT_ADMIN_TOKEN_FILE (/run/secrets/seshat_admin_token)
seshat server listening on 0.0.0.0:8799, users=0, version=v0.1.0
```

`0.0.0.0` is inside the container; the host publishes the port on `127.0.0.1` only.

### 3. Create the first user

```sh
curl -sS -X POST -H @"$HOME/.config/seshat/admin.hdr" http://127.0.0.1:8799/api/admin/users/add
```

The answer is `{"id":"…","token":"…"}`. The token is shown once: the server keeps only a hash,
there is no recovery, and **a lost token is lost data**. It goes into that user's client config
as `secret`, with `url` set to your proxy's public address (or `http://127.0.0.1:8799` on this
machine). The root [`README.md`](../README.md) covers the client and the rest of the admin API.

### 4. The Telegram bot (optional)

Create `secrets/bot.json`:

```json
{
  "bot_token": "<from @BotFather>",
  "server_url": "http://seshat:8799",
  "utc_offset": "+02:00",
  "users": { "<your telegram id>": "<the token from step 3>" }
}
```

`http://seshat:8799` is the server's name on the stack's own network. **This file holds every bot
user's seshat token in cleartext**, which makes it the most sensitive file here. Give it to the
container's user the same way, then start the stack with the `bot` profile:

```sh
docker run --rm -v "$PWD/secrets":/s alpine \
    sh -c 'chown 65532:65532 /s/bot.json && chmod 400 /s/bot.json'
docker compose --profile bot up -d
docker compose logs seshat-bot
```

A good start ends with `seshat bot started, server=http://seshat:8799, users=1`. Every later
compose command that should include the bot needs `--profile bot` as well. To change `bot.json`
afterwards, edit it as root, or `rm -f` it, create it again and repeat the chown; then
`docker compose --profile bot restart seshat-bot`.
[`client/bot/README.md`](../client/bot/README.md) covers the bot itself.

## Configuration

The image fixes what ties it to `compose.yaml`: the server listens on `0.0.0.0:8799` inside the
container and keeps its data in `/var/lib/seshat/seshat.db`. Leave those alone. To publish on
another host port, change the left number in `ports:` (`"127.0.0.1:9000:8799"`). The one setting
is the rate limit: uncomment `SESHAT_RATE_LIMIT` under `environment:`.

There is no config file in the container. Every setting is an environment variable, and the
startup log names the source of each value.

## Upgrade and rollback

```sh
docker compose pull
docker compose up -d
```

With the bot, give both commands `--profile bot`; without it only the server is upgraded.

To roll back, or to make upgrades deliberate, pin a version in `compose.yaml`
(`image: ghcr.io/m-fedorov-s/seshat:0.1.0`; image tags carry no `v`) and run
`docker compose up -d` again. The previous image stays on disk until you prune it.

## Backup and restore

The server holds an exclusive lock on its data file, and a copy taken while it runs is not a
consistent snapshot, so stop it first. Stopping is safe at any moment: every change is on disk
before the server acknowledges it.

```sh
docker compose stop seshat \
    && docker run --rm -v seshat-data:/data:ro -v "$PWD":/backup alpine sh -c \
        'umask 077 && tar czf "/backup/seshat-$1.tgz" -C /data . && chown "$2" "/backup/seshat-$1.tgz"' \
        _ "$(date -u +%FT%H%M%SZ)" "$(id -u):$(id -g)"
docker compose start seshat
```

The archive is every user's tasks: the `umask` keeps it at mode `600` and the `chown` hands it to
you. The helper runs as root because nothing else can read a volume owned by 65532. A running bot
answers with errors while the server is down.

To restore, into a stopped server (`seshat-2026-10-05T101500Z.tgz` stands for your archive):

```sh
docker compose stop seshat \
    && docker run --rm -v seshat-data:/data -v "$PWD":/backup alpine sh -c \
        'tar tzf "/backup/$1" >/dev/null && rm -rf /data/* && tar xzf "/backup/$1" -C /data' \
        _ seshat-2026-10-05T101500Z.tgz
docker compose start seshat
```

Nothing is deleted unless the server stopped and the archive can be read. On a new host, do
*Set up* through step 2 first, so the volume is the stack's own.

**`docker compose down -v` deletes the volume and every user's tasks, with no confirmation.**
Plain `down` keeps it; the volume's fixed name does not protect it. A server you stopped stays
stopped across a reboot, so after an interrupted backup run `docker compose start seshat`.

## Moving an existing server into the stack

Do *Set up* and step 1 as above: the admin token is not in the data file, so the new one simply
replaces the old. Then, with the old server stopped:

```sh
docker compose create seshat \
    && docker compose stop seshat \
    && docker run --rm -v seshat-data:/data -v /path/to/the/old/directory:/src:ro alpine sh -c \
        'cp /src/seshat.db /data/ && chown 65532:65532 /data/seshat.db && chmod 600 /data/seshat.db'
docker compose up -d
```

`create` makes the volume, already owned by 65532, without starting the server; `stop` is for a
stack you had already started, because the copy replaces whatever the volume holds and must not
land under a running server. The `users=` count in the log should be the one you had, and every
user's token keeps working.

## Reverse proxy

A Caddy site that serves the API over HTTPS and refuses the admin API from outside:

```caddyfile
tasks.example.com {
	@admin path /api/admin/*
	handle @admin {
		respond 403
	}
	reverse_proxy 127.0.0.1:8799
}
```

The two layers do not depend on each other. Caddy matches on the decoded, cleaned path, so
`/api/%61dmin/…` is refused too; and seshat matches the path exactly as sent, so an encoded
admin path that somehow reached it would fall to the user branch and get a 403. Admin calls go
to `127.0.0.1:8799` on the host, as in step 3.

If Caddy runs in Docker, attach it to this stack's network (`seshat_default`) and proxy to
`http://seshat:8799`.

## Troubleshooting

`docker compose logs seshat` is where every answer is. At startup the server logs each setting
with its source, where the admin token came from, and the address it listens on.

- The server repeats this, while `up -d` said `Started` and `docker compose ps` shows it
  restarting:
  `admin_token_file from SESHAT_ADMIN_TOKEN_FILE: permission denied (path not shown: it may be a misplaced token)`.
  The container's user cannot read `secrets/admin_token`: the chown at the end of step 1 did
  not happen. Fix the owner (the `sudo chown` form in step 1 works on an existing file), then
  `docker compose restart seshat`.
- `seshat-bot` repeats `error call getMe, …` (`unauthorized` or `not found`): the `bot_token`
  in `secrets/bot.json` is wrong. If it repeats
  `open /run/secrets/seshat_bot_config: permission denied`, the chown in step 4 did not happen.
- **`403` on everything**, a plain `curl http://127.0.0.1:8799/` included, is the correct answer
  to a missing or wrong token. The server is up.
- **`exec: "sh": executable file not found`.** The images contain no shell. To look inside the
  volume: `docker run --rm -v seshat-data:/data alpine ls -l /data`.
- **`permission denied` on the data file.** The named volume was replaced with a bind mount,
  which keeps the host directory's owner. Use the named volume.

## Building the images

From a checkout, `make docker-build` builds `seshat:dev` and `seshat-bot:dev`, and
`make docker-smoke` builds throwaway copies and tests them in a container. Both need buildx
(`docker buildx version` must succeed); the smoke test also needs the compose plugin. Run both
before tagging a release: CI builds no images, and the release workflow publishes whatever
builds.

## Appendix: podman Quadlet

Podman's secrets carry an owner and a mode, so the chown of step 1 is not needed.
`~/.config/containers/systemd/seshat.container`:

```ini
[Unit]
Description=seshat server

[Container]
Image=ghcr.io/m-fedorov-s/seshat:latest
PublishPort=127.0.0.1:8799:8799
Volume=seshat-data:/var/lib/seshat
Secret=seshat_admin_token,type=mount,target=/run/secrets/admin_token,uid=65532,gid=65532,mode=0400
Environment=SESHAT_ADMIN_TOKEN_FILE=/run/secrets/admin_token
DropCapability=ALL
NoNewPrivileges=true

[Service]
Restart=always

[Install]
WantedBy=default.target
```

```sh
umask 077
mkdir -p ~/.config/seshat
openssl rand -hex 32 > admin_token \
    && podman secret create seshat_admin_token admin_token \
    && printf 'Authorization: %s\n' "$(cat admin_token)" > ~/.config/seshat/admin.hdr \
    || echo "STOP: the token is not set up; do not go on"
rm -f admin_token
systemctl --user daemon-reload
systemctl --user start seshat
```

A user unit stops when you log out and does not start at boot unless lingering is on
(`loginctl enable-linger`). Do not add `ReadOnly=true`: with a mounted secret the container then
fails to start, because the mount point cannot be created on a read-only root. Checked with
podman 6.1 and runc: the unit passes Quadlet's dry run and the equivalent `podman run` starts
and serves. The systemd side was not run.
