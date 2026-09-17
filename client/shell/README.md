# Shell integration

`fish/` is a fisher-layout plugin: completions, a `conf.d` hook that prints a short block of your
most urgent open tasks above the prompt when you come back to a terminal you have not touched for
a while, and a `seshat-prompt` function to control it. `bash/` and `zsh/` are static completions
only. All five files are compiled into the client and printed by `seshat completions <shell>` and
`seshat init fish`, which is how the installer writes them.

Needs **fish ≥ 3.6.0** (`path mtime --relative`).

## The prompt block

```
○ Renew the domain #c8d1
◐ Cut the changelog #b104
… and 7 more
```

It is the output of `seshat show --open --flat --no-color --limit 5`, cached in
`$XDG_CACHE_HOME/seshat/prompt` (default `~/.cache/seshat/prompt`, directory mode 0700) and
refreshed by a detached background job at most once a minute. The prompt itself never waits on the
network; at most once a TTL it forks a detached worker that does.

The block prints on a prompt when **all** of these hold: it is not paused, `seshat` is on `$PATH`,
no fish prompt has been drawn anywhere for `seshat_prompt_idle_minutes`, and the cache exists and
is non-empty. In practice:

| situation | prints? |
|---|---|
| first prompt after a night or a long meeting | yes |
| the next command ten seconds later | no |
| a new tab while another tab was active seconds ago | no — "idle" is global across terminals |
| first fish ever after installing | no — the cache is cold; it fills in the background |
| `Ctrl-L`, resize, `Ctrl-C` on a non-empty line | no — the prompt event does not re-fire |
| server unreachable for a week | yes, with week-old content; `seshat-prompt status` says how old |
| client installed but not configured | never — the refresh fails silently and nothing is printed |
| `seshat-prompt now` | on the next prompt of the shell you ran it in (the idle stamp is shared, and the first prompt drawn anywhere re-creates it) |

Nothing is printed when the cache is empty or missing; a failed refresh keeps the last good block.
`seshat-prompt status` is where to look when the block is quiet.

### `seshat-prompt`

| command | effect |
|---|---|
| `seshat-prompt pause` | silence the block, in every fish, across restarts (a universal variable) |
| `seshat-prompt resume` | undo that; the very next prompt prints |
| `seshat-prompt now` | refresh synchronously and show the block on the next prompt; silent even if the refresh fails — `status`'s `last try:` line is where to look |
| `seshat-prompt status` | paused/active, idle threshold, cache path, content age, last attempt, row count |

```
$ seshat-prompt status
state:      active
idle:       15 min
cache:      /home/you/.cache/seshat/prompt
content:    42 s old
last try:   42 s ago
rows:       3
```

### Knobs

Set these with `set -g` in `config.fish` (`set -U` also works):

| variable | default | meaning |
|---|---|---|
| `seshat_prompt_idle_minutes` | 15 | quiet time before the block prints; read on every prompt |
| `seshat_prompt_ttl` | 60 | seconds between refresh attempts |
| `seshat_prompt_limit` | 5 | rows in the block, and how many ids `done <TAB>` can offer |

### Refresh after a mutation

A `fish_postexec` handler force-refreshes after `seshat add|update|delete|done|tui`. The match is
a heuristic on the command line as typed; misses cost one stale block for at most a minute.

| command line | refresh? |
|---|---|
| `seshat done a1b2`, `  seshat done a1b2`, `seshat tui`, `seshat add --title x`, `seshat done a1; and ls` | yes |
| `seshat show`, `ls`, `echo seshat done a1` | no (correct) |
| `command seshat done a1`, `/usr/bin/seshat done a1`, `sudo seshat done a1`, `ls; and seshat done a1`, a wrapper function | **no** |

Abbreviations expand before the event fires, so they are covered; functions and aliases are not.

## Completions

fish: every subcommand, flag and enum value, `--filter` values (`overdue`, `status:…` with
already-chosen statuses removed), and task ids for `update`/`delete`/`done`. Two limitations:
id completion offers only the tasks in the prompt block (raise `seshat_prompt_limit` to widen it),
and `--filter tag:` completes nothing.

bash: needs the `bash-completion` package (Linux; macOS users install it from Homebrew or use
fish/zsh). zsh: the installer writes `_seshat` to
`${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions/` and that directory has to be on `fpath`
before `compinit` runs — add to `~/.zshrc` (before `source $ZSH/oh-my-zsh.sh`, if you use it):

```zsh
fpath=(${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions $fpath)
```

then `rm -f ~/.zcompdump* && exec zsh`.

## Installing

Pick **one** channel per machine:

- **Installer** (lands with Stage 3 (d); until then, use fisher). `install.sh` writes the fish
  files (only if `${XDG_CONFIG_HOME:-~/.config}/fish` exists), the bash file (only if the
  bash-completion user directory exists) and the zsh file. `install.sh --no-shell` skips all of
  them.
- **fisher** (the dev loop). `install.sh --no-shell`, then
  `fisher install ~/src/seshat/client/shell/fish`; `fisher update` re-copies the working tree.
  fisher refuses to overwrite files the installer wrote, so when switching, first
  `rm "${XDG_CONFIG_HOME:-$HOME/.config}"/fish/{completions,conf.d}/seshat.fish`.

Stale `~/.cache/seshat/*` files from the retired fish client are inert and can be deleted; the
directory is re-created on the next refresh.

### Uninstall

```
~/.local/bin/seshat
${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/seshat.fish
${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/seshat.fish
${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/seshat
${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions/_seshat
${XDG_CACHE_HOME:-~/.cache}/seshat/
```

plus `set -e seshat_prompt_paused` in fish (no `-U`).

## Tests

`make shell-test` runs `test/shell/run.sh`: the real files under `fish --no-config -i` with a fake
`seshat` and a sandboxed `$HOME`, plus the bash and zsh completion functions driven for real. It
is a local pre-commit target and needs fish, bash ≥ 5 and GNU coreutils; zsh and bash-completion
are optional. CI does not run it.
