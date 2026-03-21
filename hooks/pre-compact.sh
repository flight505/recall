#!/usr/bin/env bash
# PreCompact hook — save working state before context compaction
# Runs sync (must complete before compaction proceeds)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Recursion guard ---
if [ "${RECALL_PRECOMPACT_ACTIVE:-}" = "1" ]; then
    exit 0
fi
export RECALL_PRECOMPACT_ACTIVE=1

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

# No transcript — nothing to save
if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    exit 0
fi

# --- Extract working state data ---
working_json="$(python3 "${SCRIPT_DIR}/lib/extract-last-turn.py" working < "$transcript_path")"

# Parse extracted data
user_msgs="$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for msg in data.get('user_msgs', []):
    # Truncate each message
    m = msg[:300]
    print(m)
" "$working_json")"

assistant_msgs="$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for msg in data.get('assistant_msgs', []):
    m = msg[:500]
    print(m)
" "$working_json")"

file_paths="$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for p in data.get('file_paths', []):
    print(p)
" "$working_json")"

# Skip if nothing meaningful
if [ -z "$user_msgs" ] && [ -z "$assistant_msgs" ]; then
    exit 0
fi

# --- Get context signals ---
branch="$(git branch --show-current 2>/dev/null || echo "unknown")"
cwd="$(pwd)"
project_name="$(basename "$cwd")"

# --- Summarize working state with haiku ---
prompt="Extract the current working state from this conversation context. Output EXACTLY this format:

# Working State
**Updated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Branch:** ${branch}

## Current Task
<what the user is currently working on>

## Progress
<bullet points of what has been done so far>

## Active Context
<files and areas of code currently being worked on>

## Important Context
<any decisions, constraints, or context that would be lost on compaction>

Recent user messages:
${user_msgs}

Recent assistant responses:
${assistant_msgs}

Files touched:
${file_paths}

Rules:
- Output ONLY the markdown, nothing else
- Be specific about file names and line numbers
- Focus on WHAT and WHY, not HOW
- If something is unknown, omit the section rather than guessing"

# Ensure dirs exist
ensure_project_dirs

# Call claude -p with CLAUDECODE unset
working_state="$(env -u CLAUDECODE claude -p --model haiku --no-session-persistence <<< "$prompt" 2>/dev/null || echo "")"

# Skip if summarization failed
if [ -z "$working_state" ]; then
    exit 0
fi

# --- Write working state (overwrite) ---
proj_dir="$(get_project_dir)"
printf '%s\n' "$working_state" > "${proj_dir}/working-state.md"

exit 0
