# seshat telegram bot

Capture and browse seshat tasks from Telegram. Long-polling: it opens **no
inbound port** and makes only outbound HTTPS calls to `api.telegram.org`.

## Config

`$SESHAT_BOT_CONFIG`, or `~/.config/seshat/bot.json`. Mode `0600` — it holds the
bot token *and* every user's seshat token.

```json
{
  "bot_token": "123456:ABC-DEF…",
  "server_url": "http://127.0.0.1:8080",
  "utc_offset": "+03:00",
  "users": { "123456789": "<seshat token>" }
}
```

`users` maps a Telegram numeric user id to that user's seshat token — the value
returned by the server's `/api/admin/users/add`. Anyone not in this map gets no
reply at all. Find your id by messaging `@userinfobot`.

**Privacy:** the bot holds the token, and the token is the whole account:
whoever runs the bot can read every task, and Telegram stores every message in
cleartext. `/start` says so. The only privacy from the bot operator is a
separate account used from the CLI only.

## BotFather settings

- **Disable group joins** (`/setjoingroups` → Disable).
- Leave privacy mode on.

These are defence in depth: the code refuses any chat that is not `private`,
which is the authoritative check because it is in version control.

## systemd

```ini
[Unit]
Description=seshat telegram bot
After=network-online.target seshat-server.service

[Service]
ExecStart=/usr/local/bin/seshat-bot
Environment=SESHAT_BOT_CONFIG=/etc/seshat/bot.json
Restart=on-failure
RestartSec=5s
User=seshat

[Install]
WantedBy=multi-user.target
```

## Usage

- Any message becomes a task. First line is the title; anything after the first
  newline is the description.
- `/list` — open tasks, five roots per page.
- `/find <text>` — substring search over open task titles.

Edits are per-field through the card's inline keyboard. Buttons are held in
memory, so **a restart expires every previously rendered button** — the bot says
so and asks you to `/list` again.
