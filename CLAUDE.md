# recall

**Version 1.2.0** | Zero-infrastructure memory plugin for Claude Code

---

## What recall Does

Captures session knowledge as markdown and injects relevant context on startup. No database, no daemon, no dependencies beyond bash + python3.

**Memory lifecycle:** Session ends -> Stop hook compresses transcript (98.8% reduction) -> haiku summarizes with git commits as ground truth -> appends to episodic log -> next session starts -> SessionStart hook injects relevant memories (4K budget).

**Compaction protection:** PreCompact saves working state -> PostCompact logs event + captures compact_summary -> SessionStart (source=compact) restores working state.

---

## Anchored Compression (v1.2.0)

The Stop hook uses **anchored compression** to give haiku the full session narrative:

1. **Compress** — strip mechanical overhead (tool_result content, progress entries, system events, file-history-snapshot). Typical 3.4MB transcript compresses to ~42KB (98.8%).
2. **Filter** — remove system-injected noise from user messages (task notifications, command expansions, skill catalogs). Real user intent is preserved.
3. **Anchor** — extract git commits, decision lines, edited files, file paths as structured data that must survive summarization.
4. **Summarize** — feed anchors + compressed conversation + git log to haiku in a single call.

**Three-tier signal priority:**

| Tier | Source | When available | Quality |
|------|--------|----------------|---------|
| 1 | Claude's session recap | When CLAUDE.md instruction present | Highest |
| 2 | Git commits + compressed conversation | Always (if commits exist) | High |
| 3 | User messages (noise-filtered) | Always | Context only |

**Extraction modes** (`extract-last-turn.py`):

| Mode | Used by | Purpose |
|------|---------|---------|
| `compress` | stop.sh | Full compressed narrative + anchors for episodic capture |
| `summary` | (legacy) | Fragment-based extraction (kept for backward compat) |
| `working` | pre-compact.sh | Last 5 user + 3 assistant msgs + file paths for working state |

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
| session-start.sh | SessionStart | sync | 5s | Inject recalled memories (4K budget) |
| stop.sh | Stop | async | 30s | Compress + summarize session |
| pre-compact.sh | PreCompact | sync | 30s | Save working state |
| post-compact.sh | PostCompact | sync | 5s | Log event + capture compact_summary |

---

## Skills

- **recall** (`context: fork`) — On-demand memory search via `/recall <question>`

---

## CLAUDE.md Integration

For best results, add a "Session Close (for recall)" section to the global `~/.claude/CLAUDE.md`. When Claude includes a structured recap in its final response, recall captures it as the highest-priority signal. SessionStart checks for this instruction and suggests adding it if missing.

---

## Design Rules

- Never writes to CLAUDE.md or MEMORY.md — uses transient `additionalContext` only
- All JSON parsing via python3 (avoids jq corruption bug)
- `env -u CLAUDECODE` before `claude -p` calls (avoids headless session bug)
- Recursion guards on stop.sh and pre-compact.sh
- Budget cap: 4000 chars injected at session start
- Noise filter strips system-injected content from user messages

---

## Gotchas

- `hooks/hooks.json` is auto-discovered — never add `"hooks"` to plugin.json
- Stop hook is async — may not complete if machine shuts down immediately
- Working state only injected when source=compact (not on normal startup)
- Minimum 10 transcript lines required before stop.sh captures
- `compact_summary` field in PostCompact requires Claude Code 2.1.76+

---

**Maintained by:** Jesper Vang (@flight505)
**Repository:** https://github.com/flight505/recall
**License:** MIT
