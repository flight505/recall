# recall

Zero-infrastructure memory for Claude Code. Captures session knowledge as markdown, injects relevant context on startup, survives compaction.

![recall architecture](assets/architecture.png)

## Why recall?

Claude Code sessions are ephemeral. When a session ends or context compacts, everything you discussed is gone. `recall` fixes this with 4 lightweight hooks that capture and restore knowledge automatically.

**No database. No daemon. No dependencies beyond bash + python3.**

## Installation

```bash
claude plugin add /path/to/recall
# or from marketplace:
claude plugin add flight505/recall
```

## How It Works

```
Session ends
    |
    v
[Stop hook] --- claude -p --model haiku ---> summarize session
    |                                              |
    v                                              v
episodic/2026-03-21.md  <----  "### 14:30 — Added auth middleware"

Next session starts
    |
    v
[SessionStart hook] --- read episodic + semantic ---> inject additionalContext
    |
    v
Claude sees: "[recall] Last session: Added auth middleware..."

Context compacts
    |
    v
[PreCompact] --- save working state ---> working-state.md
[PostCompact] --- log event ---> episodic/
[SessionStart source=compact] --- restore working state ---> additionalContext
```

## Memory Types

| Type | Location | Strategy | Purpose |
|------|----------|----------|---------|
| Episodic | `episodic/YYYY-MM-DD.md` | Append-only | Session logs — what happened, when |
| Semantic | `semantic/*.md` | Overwrite | Codebase facts — architecture, patterns |
| Working State | `working-state.md` | Overwrite | Pre-compaction snapshot — survives context loss |

## On-Demand Retrieval

Ask about past sessions using the recall skill:

```
/recall what did I work on yesterday?
/recall what decisions were made about the auth system?
/recall what files did I change on the feature/payments branch?
```

A subagent searches your memory files and returns a synthesized answer.

## Storage

All data lives at `${CLAUDE_PLUGIN_DATA}/projects/<project-hash>/` where the hash is derived from your working directory. Files are plain markdown — human-readable, git-friendly, grep-able.

## Comparison with claude-mem

| | claude-mem | recall |
|---|-----------|--------|
| **Dependencies** | Bun, Node, uv, ChromaDB, SQLite, daemon | bash + python3 |
| **Capture overhead** | Every tool call | Once at session end (async) |
| **RAM usage** | 65GB+ (orphaned processes) | ~0 (no persistent processes) |
| **Infinite loops** | Known bug in Stop hook | Recursion guard |
| **Injection** | Timeline dump (last N) | Relevance-filtered by branch/files/date |
| **Staleness** | None | Temporal decay + file-existence checks |
| **Compaction** | No protection | PreCompact saves working state |
| **File pollution** | Creates/modifies CLAUDE.md | Uses transient additionalContext only |
| **Windows** | Broken | Cross-platform (run-hook.cmd polyglot) |
| **Human-readable** | No (SQLite/ChromaDB) | Yes (markdown files) |
| **Storage format** | Binary databases | Plain markdown (git-friendly) |

## Hook Events

| Hook | Event | Sync/Async | Timeout | What it does |
|------|-------|-----------|---------|-------------|
| `session-start.sh` | SessionStart | sync | 5s | Inject recalled memories |
| `stop.sh` | Stop | async | 30s | Capture session summary |
| `pre-compact.sh` | PreCompact | sync | 30s | Save working state |
| `post-compact.sh` | PostCompact | sync | 5s | Log compaction event |

## Configuration

No configuration needed. recall uses `${CLAUDE_PLUGIN_DATA}` (set by Claude Code) for storage, falling back to `~/.recall` if unset.

## License

MIT
