<p align="center">
  <img src="assets/how-it-works.png" alt="recall — How It Works" width="800">
</p>

<p align="center">
  <a href="https://github.com/flight505/recall"><img src="https://img.shields.io/badge/version-1.2.0-blue.svg" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
  <a href="https://github.com/anthropics/claude-code"><img src="https://img.shields.io/badge/Claude%20Code-Plugin-purple.svg" alt="Claude Code Plugin"></a>
  <a href="https://github.com/flight505/flight505-marketplace"><img src="https://img.shields.io/badge/marketplace-flight505-orange.svg" alt="Marketplace"></a>
</p>

<p align="center">
  <strong>Zero-infrastructure memory for Claude Code</strong><br>
  Captures session knowledge as markdown · Injects relevant context on startup · Survives compaction
</p>

---

## Why recall?

Claude Code sessions are ephemeral. When a session ends or context compacts, everything you discussed — decisions, debugging steps, architectural choices — is gone. The next session starts blank.

**recall** fixes this with 4 lightweight hooks that automatically:

- **Capture** what happened (files changed, decisions made, work completed)
- **Store** it as plain markdown (human-readable, git-friendly, grep-able)
- **Recall** relevant context at the start of every new session
- **Survive** context compaction without losing your working state

**No database. No daemon. No dependencies beyond `bash` + `python3`.**

---

## Installation

### From the marketplace (recommended)

```bash
claude plugin add flight505/recall
```

### From source

```bash
git clone https://github.com/flight505/recall.git
claude plugin add /path/to/recall
```

### Verify installation

```bash
claude plugin list
# Should show: recall v1.2.0
```

After installation, recall works immediately — no configuration needed. End a session, start a new one, and you'll see `[recall]` context injected automatically.

---

## How It Works

recall operates through Claude Code's [hook system](https://code.claude.com/docs/en/hooks), intercepting 4 lifecycle events:

### 1. Session Ends → Capture

When you exit a session, the **Stop hook** (async, 30s) runs in the background:

```
Your session transcript (3.4 MB, ~1200 lines)
         │
         ▼  Anchored Compression (98.8% reduction)
         │  Strip: tool_result content, progress events, system metadata
         │  Filter: system-injected noise (task notifications, skill expansions)
         │  Keep: user text + assistant text + [ToolName: file_path] refs
         │
Compressed narrative (42 KB, ~330 lines)
         │
         ▼  Anchor extraction (parallel)
         │  Git commits, decision lines, edited files, tool names
         │
         ▼  Haiku summarization (single call, ~12K input tokens)
         │
Episodic entry:
  ### 14:30 — Implemented auth middleware with JWT validation
  - Goal: Add authentication to API routes
  - Outcome: JWT middleware, refresh token rotation, 12 tests passing
  - Key files: src/middleware/auth.ts, src/routes/api.ts, tests/auth.test.ts
  - Decisions: JWT over session cookies (stateless, CDN-compatible)
  - Open: Rate limiting not yet implemented
```

### 2. Next Session Starts → Recall

The **SessionStart hook** (sync, 5s) reads your stored memories and injects the most relevant ones:

```
SessionStart fires
         │
         ▼  Read episodic + semantic + working state
         │
         ▼  Priority-based assembly (4K char budget):
         │  1. Working state (only after compaction)
         │  2. Latest episodic entry
         │  3. Architecture semantic file (30-day staleness check)
         │  4. Branch-matching entries (last 7 days)
         │
         ▼  Inject via additionalContext
         │
Claude sees: "[recall] Last session: Implemented auth middleware..."
```

### 3. Context Compacts → Survive

When Claude Code runs out of context and compacts, recall protects your working state:

```
Context approaching limit
         │
         ▼  PreCompact hook (sync, 30s)
         │  Saves current task, progress, active files to working-state.md
         │
         ▼  Claude Code compacts (context is reset)
         │
         ▼  PostCompact hook (sync, 5s)
         │  Logs compaction event + captures Claude's compact_summary
         │
         ▼  SessionStart fires with source=compact
         │  Restores working-state.md into the fresh context
         │
You continue working as if nothing happened
```

---

## Three-Tier Signal Hierarchy

recall uses three sources of truth, prioritized by reliability:

| Tier | Source | Quality | When available |
|:----:|--------|---------|----------------|
| **1** | Claude's session recap | Highest — written with full context | When `~/.claude/CLAUDE.md` has the recap instruction |
| **2** | Git commits + compressed conversation | High — artifacts are ground truth | Whenever commits exist in the session |
| **3** | User messages (noise-filtered) | Context — intent, not outcomes | Always |

**Why git commits matter most:** User messages in coding sessions are often short directives ("yes", "fix it", "do that"). Git commits are the authoritative record of what was actually done. We tested 7 extraction strategies — user-message approaches scored 0-1.5/10, git-commit-based scored 7/10.

### Boost capture quality with CLAUDE.md

Add this to your global `~/.claude/CLAUDE.md` for the highest-quality episodic entries:

```markdown
### Session Close (for recall)

When a session is ending, include a brief session recap:

**Session:** <one-line summary>
**Files:** <key files changed>
**Decisions:** <notable choices, or "None">
**Open:** <unfinished work, or "None">
```

recall's SessionStart hook checks for this instruction and shows a tip if it's missing.

---

## Memory Types

recall maintains three types of memory, each with a different lifecycle:

### Episodic Memory (`episodic/YYYY-MM-DD.md`)

**What:** Daily session logs — timestamped entries of what happened, when, and why.

**Strategy:** Append-only. New entries are added after each session. Never overwritten.

**Format:**
```markdown
# 2026-03-25

### 14:30 — Implemented auth middleware with JWT validation
- **Goal:** Add authentication to API routes
- **Outcome:** JWT middleware, refresh token rotation, 12 tests passing
- **Key files:** src/middleware/auth.ts, src/routes/api.ts
- **Decisions:** JWT over session cookies (stateless, CDN-compatible)
- **Open:** Rate limiting not yet implemented

### 16:45 — Context compacted
- **Event:** compaction
- **Branch:** feat/auth
- **Summary:** Working on JWT auth middleware, 12 tests passing...
- **Note:** Working state was saved before compaction.

### 17:20 — Added rate limiting to auth routes
- **Goal:** Implement rate limiting for API authentication endpoints
- **Outcome:** Token bucket rate limiter, per-IP tracking, Redis-backed
- **Key files:** src/middleware/rate-limit.ts, src/config/limits.ts
- **Decisions:** Token bucket over sliding window (simpler, sufficient)
- **Open:** None
```

### Semantic Memory (`semantic/*.md`) — *coming soon*

**What:** Codebase facts organized by topic — architecture decisions, patterns, conventions.

**Strategy:** Overwrite. Updated when facts change. Includes staleness tracking.

**Status:** The semantic layer is currently populated manually. Automatic **episodic → semantic consolidation** is planned on the `feat/semantic-consolidation` branch — detecting recurring patterns across sessions and promoting them to durable facts.

### Working State (`working-state.md`)

**What:** A snapshot of what you're actively working on, captured before context compaction.

**Strategy:** Overwrite on each compaction. Only injected when `source=compact`.

**Format:**
```markdown
# Working State — 2026-03-25T14:30:00Z

## Current Task
Implementing JWT authentication middleware

## Progress
- Auth middleware created and wired into Express
- Refresh token rotation working
- 12 unit tests passing

## Active Context
- Branch: feat/auth
- Key files: src/middleware/auth.ts, tests/auth.test.ts

## Important Context
- Using RS256 algorithm (not HS256) per security review
- Token expiry: 15min access, 7d refresh
```

---

## On-Demand Search

Query your memory with the `/recall` skill:

```bash
/recall what did I work on yesterday?
/recall what decisions were made about the auth system?
/recall what files did I change on the feature/payments branch?
/recall when did we last discuss the database migration?
```

A subagent searches your episodic and semantic memory files, cross-references by date, branch, and keywords, and returns a synthesized answer (under 500 chars to preserve your context budget).

---

## Where Data Lives

### Storage location

All recall data is stored **outside your project**, in a plugin-managed directory:

```
${CLAUDE_PLUGIN_DATA}/projects/<project-hash>/
├── episodic/
│   ├── 2026-03-25.md          # Today's session logs
│   ├── 2026-03-24.md          # Yesterday's
│   └── ...                     # One file per active day
├── semantic/
│   ├── architecture.md         # Codebase architecture facts
│   ├── conventions.md          # Code style, patterns
│   └── ...                     # Topic-organized facts
├── working-state.md            # Last pre-compaction snapshot
└── meta.json                   # Project name, path, session count
```

**`CLAUDE_PLUGIN_DATA`** is set by Claude Code automatically when a plugin is installed. If unset, recall falls back to `~/.recall`.

### Project identification

Each project gets its own storage directory, identified by a **12-character hash** of the working directory path (SHA-256, truncated). This means:

- Different projects never share memory
- The same project always maps to the same hash, regardless of how you navigate to it
- Multiple Claude Code sessions in the same project share the same memory store

### What recall does NOT touch

- **Never writes to `CLAUDE.md`** — uses transient `additionalContext` only
- **Never writes to `MEMORY.md`** — that's Claude Code's auto-memory space
- **Never modifies your project files** — all storage is external
- **Never sends data anywhere** — all processing is local (haiku call excepted)

---

## Architecture

<p align="center">
  <img src="assets/architecture.png" alt="recall v1.2.0 Architecture" width="800">
</p>

### Anchored Compression Pipeline

The core innovation in recall v1.2.0. Instead of extracting fragments from transcripts, the entire conversation is compressed:

| Stage | What happens | Result |
|-------|-------------|--------|
| **Raw input** | Full session transcript | 3.4 MB, ~1200 lines |
| **Strip** | Remove tool_result content, progress events, system entries | ~80% reduction |
| **Filter** | Remove system-injected noise from user messages | 49 → 18 user lines |
| **Keep** | User text + assistant text + `[ToolName: file_path]` references | 42 KB, ~330 lines |
| **Anchor** | Extract git commits, decision lines, edited files (never compressed away) | Structured data |
| **Enrich** | Add git log from session timeframe | Authoritative record |
| **Summarize** | Single haiku call with anchors + full narrative | Episodic entry |

### Extraction Modes

`extract-last-turn.py` supports three modes:

| Mode | Used by | Purpose |
|------|---------|---------|
| `compress` | stop.sh | Full compressed narrative + anchors for episodic capture |
| `summary` | *(legacy)* | Fragment-based extraction (kept for backward compatibility) |
| `working` | pre-compact.sh | Last 5 user + 3 assistant messages + file paths |

### Injection Budget

SessionStart assembles recalled context within a **4000-character budget** (~1000 tokens, <0.5% of a 200K context window):

| Priority | Source | Condition |
|----------|--------|-----------|
| 1 (highest) | Working state | Only after compaction (`source=compact`) |
| 2 | Latest episodic entry | Always |
| 3 | Architecture semantic | If exists (with 30-day staleness warning) |
| 4 | Branch-matching entries | Last 7 days, matching current git branch |

If a section exceeds the remaining budget, it's truncated. Lower-priority sections are skipped entirely.

---

## Hook Events

| Hook | Event | Sync/Async | Timeout | What it does |
|------|-------|:----------:|:-------:|-------------|
| `session-start.sh` | SessionStart | sync | 5s | Inject recalled memories (4K budget) |
| `stop.sh` | Stop | **async** | 30s | Compress transcript + haiku summary |
| `pre-compact.sh` | PreCompact | sync | 30s | Save working state snapshot |
| `post-compact.sh` | PostCompact | sync | 5s | Log event + capture `compact_summary` |

**Why Stop is async:** The session capture runs in the background so it never blocks you from exiting. Tradeoff: if your machine shuts down immediately, the capture may not complete.

**Why PreCompact is sync:** The working state must be saved *before* compaction destroys the context. It blocks compaction until done (up to 30s).

---

## recall vs Claude Code Auto-Dream

Claude Code recently introduced **auto-dream** — a built-in memory consolidation feature. recall and auto-dream are **complementary, not competing:**

| | Auto-dream (built-in) | recall |
|---|---|---|
| **Purpose** | Consolidate Claude's auto-memory notes | Capture session-level episodic history |
| **Storage** | `~/.claude/projects/<project>/memory/` | `${CLAUDE_PLUGIN_DATA}/projects/<hash>/` |
| **Trigger** | Background, automatic | Session end (Stop hook) |
| **Compaction protection** | No | Yes (PreCompact + PostCompact) |
| **Consolidation** | Yes — reorganizes memory files | Episodic logs (append-only) |
| **What it captures** | Learnings Claude decides to keep | Full session narrative via anchored compression |

Auto-dream consolidates *what Claude remembers*. Recall captures *what happened*. They write to different storage paths and serve different purposes. Both can run simultaneously without conflict.

---

## Project Structure

```
recall/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest (v1.2.0)
├── hooks/
│   ├── hooks.json               # Hook event registration
│   ├── session-start.sh         # Inject recalled memories (214 lines)
│   ├── stop.sh                  # Compress + summarize session (230 lines)
│   ├── pre-compact.sh           # Save working state (121 lines)
│   ├── post-compact.sh          # Log compaction event (51 lines)
│   ├── run-hook.cmd             # Cross-platform bash/batch polyglot
│   └── lib/
│       ├── extract-last-turn.py # Transcript extraction (485 lines, 3 modes)
│       └── common.sh            # Shared utilities (72 lines)
├── skills/
│   └── recall/
│       └── SKILL.md             # On-demand memory search skill
├── assets/
│   ├── how-it-works.png         # Lifecycle diagram (conceptual)
│   └── architecture.png         # Technical architecture (detailed)
├── CLAUDE.md                    # Developer instructions
├── README.md                    # This file
└── LICENSE                      # MIT
```

**Total implementation:** ~1,231 lines of shell + Python.

---

## Configuration

**No configuration needed.** recall uses `${CLAUDE_PLUGIN_DATA}` (set automatically by Claude Code) for storage, falling back to `~/.recall` if unset.

### Optional: CLAUDE.md session recap

Adding the [session recap instruction](#boost-capture-quality-with-claudemd) to `~/.claude/CLAUDE.md` significantly improves capture quality. recall's SessionStart hook detects whether this instruction is present and shows a tip if it's missing.

### Optional: Semantic memory files

You can manually create `semantic/*.md` files in your project's recall storage directory to provide persistent codebase facts:

```bash
# Find your project's storage directory
python3 -c "import hashlib; print(hashlib.sha256(b'$(pwd)').hexdigest()[:12])"
# Then create: ${CLAUDE_PLUGIN_DATA}/projects/<hash>/semantic/architecture.md
```

---

## Requirements

- **Claude Code** v2.1.76+ (for `compact_summary` in PostCompact)
- **bash** (v4+ recommended)
- **python3** (3.8+)
- **git** (for commit-based anchoring)
- **claude CLI** (for haiku summarization via `claude -p`)

No additional packages, no pip install, no node_modules.

---

## Known Limitations

- **Async capture risk**: The Stop hook is async — if your machine shuts down immediately after exiting, the episodic entry may not be captured.
- **Cross-project sessions**: If you work across multiple repos in a single session, the episodic entry may contain work from other projects. Git log anchoring is scoped to the current repo, but the compressed conversation includes everything.
- **AI text in diagrams**: The architecture diagrams use AI-generated text which may have minor character substitutions in labels.
- **Semantic layer is manual**: Automatic episodic → semantic consolidation is planned but not yet implemented.

---

## Roadmap

- [ ] **Episodic → semantic consolidation** — automatically promote recurring patterns from session logs into durable semantic facts (`feat/semantic-consolidation` branch)
- [ ] **Cross-project session detection** — filter compressed conversation by project directory to prevent content pollution
- [ ] **MCP server transport** — expose recall's flat-file storage via MCP for cross-tool compatibility
- [ ] **Configurable budget** — allow users to adjust the 4K injection budget

---

## Contributing

recall is part of the [flight505 marketplace](https://github.com/flight505/flight505-marketplace). To contribute:

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Run validation: `../../scripts/validate-plugin-manifests.sh` from the marketplace root
5. Submit a PR

---

## License

[MIT](LICENSE)

---

<p align="center">
  <strong>Maintained by <a href="https://github.com/flight505">Jesper Vang</a></strong><br>
  <a href="https://github.com/flight505/recall">GitHub</a> · <a href="https://github.com/flight505/flight505-marketplace">Marketplace</a>
</p>
