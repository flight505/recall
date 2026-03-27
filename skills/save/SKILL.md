---
name: save
description: "Save a mid-session recall checkpoint — captures what happened so far to episodic memory without ending the session. Use when the user says 'save recall', 'checkpoint', 'save memory', 'save session state', or before restarting/exiting a long session. Also use when the user worries about losing context in a long-running session."
allowed-tools: [Read, Write, Bash, Glob]
user-invocable: true
---

# recall save — Mid-Session Checkpoint

You are saving a mid-session checkpoint to recall's episodic memory. Since you (Claude) have full context of this session, you write the episodic entry directly — no haiku call needed.

## What to Do

1. **Determine the project's recall storage directory:**

```bash
PROJECT_HASH=$(printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-12)
RECALL_DIR="${CLAUDE_PLUGIN_DATA:-${HOME}/.recall}/projects/${PROJECT_HASH}"
mkdir -p "${RECALL_DIR}/episodic"
```

2. **Get the current git log** for context:

```bash
git log --oneline --since='12 hours ago' --no-merges | head -10
```

3. **Write a structured episodic entry** based on your full session context. Use EXACTLY this format:

```markdown
### HH:MM — <one-line summary of session so far>
- **Goal:** <what the user wanted>
- **Outcome:** <what has been achieved so far>
- **Key files:** <comma-separated list of files changed>
- **Decisions:** <notable choices made, or 'None'>
- **Open:** <work still in progress>
- **Note:** Mid-session checkpoint (session still active)
```

Use the actual current time for HH:MM. Be specific — use real file names, real decisions, real outcomes. The git log is your ground truth for what was committed.

4. **Append the entry** to today's episodic file:

```bash
TODAY=$(date +%Y-%m-%d)
EPISODIC_FILE="${RECALL_DIR}/episodic/${TODAY}.md"

# Create header if file doesn't exist
if [ ! -f "$EPISODIC_FILE" ]; then
    printf '# %s\n\n' "$TODAY" > "$EPISODIC_FILE"
fi

# Append the entry (use cat <<'ENTRY' heredoc)
cat <<'ENTRY' >> "$EPISODIC_FILE"
<your structured entry here>

ENTRY
```

5. **Confirm** to the user what was saved and where.

## Rules

- Write from YOUR context — you have the full session, don't parse transcripts
- Be factual — only include things that actually happened
- Include the "Mid-session checkpoint" note so future sessions know this wasn't a final summary
- Keep the entry concise — under 10 lines
- If no meaningful work has been done yet, say so and skip the save
