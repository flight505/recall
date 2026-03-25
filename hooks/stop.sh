#!/usr/bin/env bash
# Stop hook — capture session summary to episodic memory
# Runs async (never blocks user exit)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Recursion guard ---
# Prevents infinite loop: stop.sh calls claude -p, which itself triggers Stop
if [ "${RECALL_STOP_HOOK_ACTIVE:-}" = "1" ]; then
    exit 0
fi
export RECALL_STOP_HOOK_ACTIVE=1

# --- Read hook input from stdin ---
hook_input=""
if [ ! -t 0 ]; then
    hook_input="$(cat)"
fi

# --- Extract transcript path ---
transcript_path=""
if [ -n "$hook_input" ]; then
    transcript_path="$(json_field "$hook_input" "transcript_path")"
fi

# If no transcript, try the session_id to find it
if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    session_id=""
    if [ -n "$hook_input" ]; then
        session_id="$(json_field "$hook_input" "session_id")"
    fi
    if [ -n "$session_id" ]; then
        candidate="${HOME}/.claude/projects/$(project_hash)/sessions/${session_id}.jsonl"
        if [ -f "$candidate" ]; then
            transcript_path="$candidate"
        fi
    fi
fi

# No transcript found — nothing to capture
if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    exit 0
fi

# --- Minimum session check ---
line_count="$(wc -l < "$transcript_path" | tr -d ' ')"
if [ "$line_count" -lt 10 ]; then
    exit 0
fi

# --- Check for session recap in last_assistant_message (from CLAUDE.md instruction) ---
last_assistant_msg=""
if [ -n "$hook_input" ]; then
    last_assistant_msg="$(json_field "$hook_input" "last_assistant_message")"
fi

# If Claude included a session recap block, we can use it directly
session_recap=""
if [ -n "$last_assistant_msg" ]; then
    session_recap="$(python3 -c "
import sys
text = sys.argv[1]
# Look for the structured recap block
lines = text.split('\n')
in_recap = False
recap = []
for line in lines:
    if '**Session:**' in line:
        in_recap = True
    if in_recap:
        recap.append(line.strip())
        if '**Open:**' in line:
            break
if recap:
    print('\n'.join(recap))
" "$last_assistant_msg" 2>/dev/null || echo "")"
fi

# --- Extract compressed session data ---
# Uses anchored compression: strips mechanical overhead (tool results, progress,
# system entries) while preserving the full conversational narrative + anchors
compress_json="$(python3 "${SCRIPT_DIR}/lib/extract-last-turn.py" compress < "$transcript_path")"

compressed_conversation="$(json_field "$compress_json" "compressed_conversation")"
first_user="$(json_field "$compress_json" "first_user")"
last_user="$(json_field "$compress_json" "last_user")"
tool_count="$(json_field "$compress_json" "tool_count")"
tool_names="$(json_field "$compress_json" "tool_names")"
error_count="$(json_field "$compress_json" "error_count")"
git_commits="$(json_field "$compress_json" "git_commits")"
decision_lines="$(json_field "$compress_json" "decision_lines")"
edited_files="$(json_field "$compress_json" "edited_files")"

# Skip if no meaningful content
if [ -z "$first_user" ] && [ -z "$git_commits" ] && [ "$tool_count" -lt 5 ] 2>/dev/null; then
    exit 0
fi

# --- Get context signals ---
branch="$(git branch --show-current 2>/dev/null || echo "unknown")"
cwd="$(pwd)"
project_name="$(basename "$cwd")"

# --- Get git log for this session (actual commits are authoritative) ---
git_log="$(git log --oneline --since='12 hours ago' --no-merges 2>/dev/null | head -10 || echo "")"

# Truncate inputs
first_user_t="$(truncate_to "$first_user" 300)"
last_user_t="$(truncate_to "$last_user" 300)"
git_commits_t="$(truncate_to "$git_commits" 500)"
decision_lines_t="$(truncate_to "$decision_lines" 400)"
edited_files_t="$(truncate_to "$edited_files" 200)"
session_recap_t="$(truncate_to "$session_recap" 300)"
# Compressed conversation: 40K chars ≈ 10K tokens, well within haiku's 200K limit
compressed_t="$(truncate_to "$compressed_conversation" 40000)"

# --- Summarize with haiku ---
# Three-tier signal priority:
# 1. Claude's session recap (if present in last_assistant_message)
# 2. Git commits + compressed conversation (full session narrative)
# 3. User messages (intent context)
recap_section=""
if [ -n "$session_recap_t" ]; then
    recap_section="
Claude's own session recap (HIGHEST PRIORITY — use this as the primary source):
${session_recap_t}
"
fi

prompt="Summarize this Claude Code session in a compact markdown block. Use EXACTLY this format:

### HH:MM — <one-line summary>
- **Goal:** <what the user wanted>
- **Outcome:** <what was achieved>
- **Key files:** <comma-separated list of important files>
- **Decisions:** <any notable choices made>
- **Open:** <unfinished work or next steps, or 'None'>
${recap_section}
Git commits made this session (AUTHORITATIVE — base your summary on these):
${git_log}

Commit messages from transcript:
${git_commits_t}

Key decisions/milestones:
${decision_lines_t}

Files edited: ${edited_files_t}

User intent:
First: ${first_user_t}
Last: ${last_user_t}

Full compressed conversation (the complete session narrative):
${compressed_t}

Context:
- Project: ${project_name}
- Branch: ${branch}
- Tools used: ${tool_count} (${tool_names})
- Errors: ${error_count}

Rules:
- Output ONLY the markdown block, nothing else
- Use the current time for HH:MM
- Keep each bullet to one line
- If a session recap is provided, it is the most accurate source — prioritize it
- The git commits are the ground truth of what was done — use them for Outcome
- The compressed conversation gives you the full session flow — use it for Goal and Decisions
- For Key files, use the files from commits and edits, not guesses
- If no decisions were made, write 'None'
- If nothing is open, write 'None'"

# Ensure project dirs exist
ensure_project_dirs

# Call claude -p with CLAUDECODE unset to prevent headless bug
summary="$(env -u CLAUDECODE claude -p --model haiku --no-session-persistence <<< "$prompt" 2>/dev/null || echo "")"

# Skip if summarization failed
if [ -z "$summary" ]; then
    exit 0
fi

# --- Append to episodic log ---
proj_dir="$(get_project_dir)"
today="$(date +%Y-%m-%d)"
episodic_file="${proj_dir}/episodic/${today}.md"

# Create or append
if [ ! -f "$episodic_file" ]; then
    printf '# %s\n\n' "$today" > "$episodic_file"
fi

{
    printf '%s\n\n' "$summary"
} >> "$episodic_file"

# --- Update meta.json ---
meta_file="${proj_dir}/meta.json"
python3 -c "
import json, os, sys
from datetime import datetime

meta_path = sys.argv[1]
project_name = sys.argv[2]
cwd = sys.argv[3]

meta = {}
if os.path.exists(meta_path):
    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except Exception:
        pass

meta['project_name'] = project_name
meta['project_path'] = cwd
meta['last_session'] = datetime.now().isoformat()
meta['session_count'] = meta.get('session_count', 0) + 1

with open(meta_path, 'w') as f:
    json.dump(meta, f, indent=2)
" "$meta_file" "$project_name" "$cwd"

exit 0
