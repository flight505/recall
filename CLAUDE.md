# recall

**Version 1.0.0** | Zero-infrastructure memory plugin for Claude Code

---

## What recall Does

Captures session knowledge as markdown and injects relevant context on startup. No database, no daemon, no dependencies beyond bash + python3.

**Memory lifecycle:** Session ends -> Stop hook summarizes with haiku -> appends to episodic log -> next session starts -> SessionStart hook injects relevant memories.

**Compaction protection:** PreCompact saves working state -> PostCompact logs the event -> SessionStart (source=compact) restores working state.

---

## Storage

All data lives at `${CLAUDE_PLUGIN_DATA}/projects/<project-hash>/`:

| Path | Purpose | Update strategy |
|------|---------|----------------|
| `episodic/YYYY-MM-DD.md` | Daily session logs | Append-only |
| `semantic/*.md` | Codebase facts by topic | Overwrite |
| `working-state.md` | Pre-compaction snapshot | Overwrite |
| `meta.json` | Project metadata | Overwrite |

Project hash is first 12 chars of SHA-256 of the working directory path.

---

## Hook Events

| Hook | Event | Sync | Timeout | Purpose |
|------|-------|------|---------|---------|
| session-start.sh | SessionStart | sync | 5s | Inject recalled memories |
| stop.sh | Stop | async | 30s | Capture session summary |
| pre-compact.sh | PreCompact | sync | 30s | Save working state |
| post-compact.sh | PostCompact | sync | 5s | Log compaction event |

---

## Skills

- **recall** (`context: fork`) — On-demand memory search via `/recall <question>`

---

## Design Rules

- Never writes to CLAUDE.md or MEMORY.md — uses transient `additionalContext` only
- All JSON parsing via python3 (avoids jq corruption bug)
- `env -u CLAUDECODE` before `claude -p` calls (avoids headless session bug)
- Recursion guards on stop.sh and pre-compact.sh
- Budget cap: 2000 chars injected at session start

---

## Gotchas

- `hooks/hooks.json` is auto-discovered — never add `"hooks"` to plugin.json
- Stop hook is async — may not complete if machine shuts down immediately
- Working state only injected when source=compact (not on normal startup)
- Minimum 10 transcript lines required before stop.sh captures

---

**Maintained by:** Jesper Vang (@flight505)
**Repository:** https://github.com/flight505/recall
**License:** MIT
