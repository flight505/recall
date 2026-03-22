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

# --- Extract summary data ---
summary_json="$(python3 "${SCRIPT_DIR}/lib/extract-last-turn.py" summary < "$transcript_path")"

first_user="$(json_field "$summary_json" "first_user")"
last_user="$(json_field "$summary_json" "last_user")"
last_assistant="$(json_field "$summary_json" "last_assistant")"
tool_count="$(json_field "$summary_json" "tool_count")"
tool_names="$(json_field "$summary_json" "tool_names")"
file_paths="$(json_field "$summary_json" "file_paths")"
middle_sample="$(json_field "$summary_json" "middle_sample")"
error_count="$(json_field "$summary_json" "error_count")"

# Skip if no meaningful content
if [ -z "$first_user" ] && [ -z "$last_assistant" ]; then
    exit 0
fi

# --- Get context signals ---
branch="$(git branch --show-current 2>/dev/null || echo "unknown")"
cwd="$(pwd)"
project_name="$(basename "$cwd")"

# Truncate inputs to keep the haiku prompt reasonable
first_user_t="$(truncate_to "$first_user" 500)"
last_user_t="$(truncate_to "$last_user" 500)"
last_assistant_t="$(truncate_to "$last_assistant" 1000)"
tool_names_t="$(truncate_to "$tool_names" 100)"
file_paths_t="$(truncate_to "$file_paths" 300)"
middle_sample_t="$(truncate_to "$middle_sample" 500)"

# --- Summarize with haiku ---
prompt="Summarize this Claude Code session in a compact markdown block. Use EXACTLY this format:

### HH:MM — <one-line summary>
- **Goal:** <what the user wanted>
- **Outcome:** <what was achieved>
- **Key files:** <comma-separated list of important files, use the files touched list below>
- **Decisions:** <any notable choices made>
- **Open:** <unfinished work or next steps, or 'None'>

Context:
- Project: ${project_name}
- Branch: ${branch}
- Tools used: ${tool_count} (${tool_names_t})
- Files touched: ${file_paths_t}
- Errors: ${error_count}

First user message:
${first_user_t}

Mid-session context:
${middle_sample_t}

Last user message:
${last_user_t}

Last assistant response:
${last_assistant_t}

Rules:
- Output ONLY the markdown block, nothing else
- Use the current time for HH:MM
- Keep each bullet to one line
- For Key files, prefer the actual file paths from 'Files touched' over guessing
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
