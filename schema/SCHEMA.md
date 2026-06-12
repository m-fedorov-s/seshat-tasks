# seshat Task schema (contract)

The authoritative contract for the `Task` wire/storage shape, shared by the Go server and the
Zig client. The machine-checkable version is `task.schema.json`; this file is the prose.

## Task
- `id` (string, immutable, server-assigned ULID)
- `content` (user-editable; the whole block is replaced on update)
- `meta` (server-owned; clients never write it)

## content
| field | type | notes |
|-------|------|-------|
| title | string, non-empty | required |
| description | string | optional, default "" |
| status | enum | `todo` \| `in_progress` \| `done` \| `cancelled` |
| priority | enum | `none` \| `low` \| `medium` \| `high` |
| child_ids | string[] | ORDERED list of child task ids; order is significant |
| tags | string[] | |
| due_at | int(unix s) \| null | |
| scheduled_at | int(unix s) \| null | "start/defer" |

## meta
| field | type | notes |
|-------|------|-------|
| created_at | int(unix s) | immutable |
| updated_at | int(unix s) | bumped on every write |
| completed_at | int(unix s) \| null | set/cleared on status transition into/out of done\|cancelled |
| version | uint | per-task; the `expected_version` token. NOT the global `state_version`/ETag. |

## Forest & invariants
Tasks form a forest. A root is any task not referenced in any other task's `child_ids`.
Invariants: each task is in at most one `child_ids` list; child ids reference existing tasks;
no intra-list duplicates; no cycles.

## Version namespaces
- `state_version` (global, on `State`) = the ETag, bumped once per mutation request.
- `meta.version` (per-task) = the `expected_version` conflict token.

## Forward-compatibility
Unknown JSON fields are tolerated. An unknown enum value maps to a fallback on read
(`status`→`todo`, `priority`→`none`); the server rejects unknown enums on write.
