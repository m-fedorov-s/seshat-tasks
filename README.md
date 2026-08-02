# seshat

A personal task manager. A small Go server owns the data; a Zig client reads and edits it, from
the command line or a full-screen TUI.

Tasks form a **forest** — any task can have subtasks — and the client's job is to make sure
nothing important is buried in it.

```
▾ ▸ ○ Ship the release                                    (+4 · ⚠2)      #7f3a
    ├─ ● Cut the changelog                    ⚠ 2 days overdue          #b104
    └─ ○ Tag and push                                 due in 3 days     #22e9
  ○ Renew the domain                                       overdue      #c8d1
```

## Why it looks like this

The ledger ranks by **subtree urgency**, not a task's own. A calm-looking parent holding an
overdue high-priority child outranks a mildly urgent leaf, and **auto-expands** so the child is
on screen without a keypress. Parents whose children need nothing stay folded behind a `(+n · ⚠m)`
badge. Nothing is ever silently hidden: tasks unreachable from any root — a cycle, say — are
surfaced under their own header rather than vanishing.

Editing is **navigation, not hotkeys**. `⏎` descends: list → field → editor. `Esc` climbs back.
You pick a status from a list instead of remembering which key sets it.

## Quick start

**1. Build both halves.**

```sh
cd server && go build -o seshat . && cd ..
cd client/zig && zig build && cd ../..     # needs Zig 0.16
```

**2. Configure the server** (`config.yaml`, gitignored — it holds your secret):

```yaml
secret: <a long random string>
bind: 127.0.0.1        # default; only change if you know you want to
port: 8799
data_file: ~/.local/share/seshat/tasks.json
```

**3. Configure the client** (`~/.config/seshat/config.json`, or point `SESHAT_CONFIG` at one):

```json
{
  "url": "http://localhost:8799",
  "secret": "<the same string>",
  "utc_offset": "+02:00"
}
```

`utc_offset` is applied when **parsing and rendering** dates only — everything is stored in UTC.
It defaults to `+00:00`, and a malformed value is a startup error rather than a silent fallback.

**4. Run it.**

```sh
./server/seshat -config config.yaml &
seshat add "Try seshat" --priority high --due +2d
seshat tui
```

To poke at it without touching real data, `make dev-server` and `make dev-seed` spin up a
throwaway server on port 8799 with a realistic dataset — see [`dev/README.md`](dev/README.md).

## The TUI

`seshat tui` takes `--sort`, `--filter` and `--open`, parsed exactly as `show` does.

| Mode | Keys |
| --- | --- |
| list | `j`/`k` move · `l`/`h` expand/collapse · `Ctrl-D`/`Ctrl-U` page · `g`/`G` first/last · `Space` cycle status · `a` add · `x` delete · `/` filter · `Tab` detail pane · `R` refresh · `⏎` descend · `q` quit |
| field | `↑`/`↓` pick a field · `⏎` edit · `Esc` back to the list |
| editing | `⏎` save · `Esc` cancel · arrows choose in a picker |
| prompts | `⏎` apply · `Esc` cancel · normal line editing |

Arrow keys work everywhere the letter keys do. The footer always shows the keys for where you are.

Four editors sit behind `⏎`: a line editor for the title, a picker for status and priority, a
date editor (`2026-08-14`, `+3d`, `+2w`, `none`), and **`$EDITOR`** for the description — the TUI
suspends, hands over the terminal, and takes the result back. `$VISUAL` then `$EDITOR` then the
first of `vi`/`vim`/`nvim`/`nano` actually on your `PATH`. Quitting without saving cancels.

Edits commit **one field at a time** with optimistic concurrency, and nothing is shown until the
server confirms it. If a write fails or conflicts, your text stays in the editor — a dropped
connection never costs a retype. Refresh is manual (`R`); there is no polling yet.

## The CLI

```sh
seshat show                          # the forest, urgency-ranked
seshat show --open --sort due        # only todo/in_progress
seshat show --filter tag:work --filter overdue     # repeatable, AND-combined
seshat show --detailed               # git-log-style blocks
seshat show --json                   # machine-readable

seshat add "Write the docs" --priority high --due 2026-08-14 --tags work,writing
seshat update a1b2 --status in_progress --dry-run
seshat done a1b2
seshat delete a1b2
```

Every command that takes an id accepts a **tail** of it, or the `#handle` shown in the output —
whatever is unambiguous. Filters match **subtrees**: `--filter tag:ops` keeps a root whose child
is tagged `ops`, rather than erasing it.

`seshat --version` reports a build-time `git describe`. Piping into something that closes early
(`seshat show | head`) exits 0, as Unix expects.

## Layout

| | |
| --- | --- |
| `server/` | Go HTTP server. In-memory, persisted to an atomic-rewrite JSON file. Auth is a shared secret in the `Authorization` header. Per-task versions give optimistic concurrency. |
| `schema/` | The `Task` contract shared by both halves — JSON Schema, prose, and golden fixtures. |
| `client/zig/` | The client (Zig 0.16). CLI plus TUI; see [`client/zig/CLAUDE.md`](client/zig/CLAUDE.md). |
| `test/` | Integration tests that need a real server and client. |
| `dev/` | A throwaway local environment. |

The client is split so the interesting parts are testable without a terminal: ranking, folding,
filtering, row layout, key dispatch and all the editors are I/O-free modules with unit tests,
while the libvaxis shell only paints what they decide.

## Tests

```sh
make server-test              # Go server
make schema-test              # the shared Task contract, both halves
make client-integration-test  # a real server and client through a pipe
cd client/zig && zig build test
```

All four must pass before a commit. Note that `zig build test` does **not** typecheck the CLI
entry point — run `zig build` as well.

## Status

The server, the CLI and the TUI work. Not built yet: client-side caching and offline use, shell
completions, multi-user, end-to-end encryption, and background refresh. Hierarchy is read-only
in the TUI — you can see and edit a forest, but not restructure one.
