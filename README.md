# recall

Zero-infrastructure memory for Claude Code. Captures session knowledge as markdown, injects relevant context on startup, survives compaction.

![How recall works](assets/how-it-works.png)

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

1. **Session ends** — The Stop hook extracts file paths, tool names, mid-session messages, and error counts from the transcript, then sends them to Haiku for a structured summary. The summary is appended to today's episodic log.

2. **Next session starts** — The SessionStart hook reads recent episodic entries, semantic facts, and branch-matching history, then injects the most relevant context (up to 4K chars) via `additionalContext`.

3. **Context compacts** — PreCompact saves a working-state snapshot before context is lost. PostCompact logs the event and captures Claude's compaction summary. SessionStart restores working state when `source=compact`.

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

## Architecture

![recall architecture](assets/architecture.png)

### Extraction Pipeline (v1.1.0)

The Stop hook extracts rich data from the transcript JSONL before summarization:

| Field | Source | Purpose |
|-------|--------|---------|
| `file_paths` | tool_use blocks (file_path, path, filePath keys + command regex) | Accurate "Key files" in episodic entries |
| `tool_names` | tool_use block names (Read, Edit, Bash, etc.) | Session activity profile |
| `middle_sample` | 3 evenly-spaced user messages from the session middle | Session arc visibility for Haiku |
| `error_count` | tool_result blocks with `is_error: true` | Error awareness |
| `first_user` / `last_user` / `last_assistant` | First/last conversation turns | Session bookends |

### Injection Budget

SessionStart injects up to **4000 characters** (~1000 tokens, <0.5% of a 200K context window) with this priority:

1. Working state (only after compaction)
2. Latest episodic entry
3. Architecture semantic file (with 30-day staleness warning)
4. Branch-matching episodic entries (last 7 days)

## Storage

All data lives at `${CLAUDE_PLUGIN_DATA}/projects/<project-hash>/` where the hash is the first 12 chars of SHA-256 of your working directory. Files are plain markdown — human-readable, git-friendly, grep-able.

## Hook Events

| Hook | Event | Sync/Async | Timeout | What it does |
|------|-------|-----------|---------|-------------|
| `session-start.sh` | SessionStart | sync | 5s | Inject recalled memories (4K budget) |
| `stop.sh` | Stop | async | 30s | Extract + summarize session |
| `pre-compact.sh` | PreCompact | sync | 30s | Save working state |
| `post-compact.sh` | PostCompact | sync | 5s | Log event + capture compact_summary |

## Configuration

No configuration needed. recall uses `${CLAUDE_PLUGIN_DATA}` (set by Claude Code) for storage, falling back to `~/.recall` if unset.

## License

MIT
