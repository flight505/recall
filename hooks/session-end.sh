#!/usr/bin/env bash
# SessionEnd hook — lightweight last-chance capture
# Must complete within 1.5s (default) — no haiku call, no transcript parsing
# Just saves last_assistant_message + git log as a quick checkpoint

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Read hook input from stdin ---
hook_input=""
if [ ! -t 0 ]; then
    hook_input="$(cat)"
fi

# --- Extract last_assistant_message (available in SessionEnd input) ---
last_msg=""
if [ -n "$hook_input" ]; then
    last_msg="$(json_field "$hook_input" "last_assistant_message")"
fi

# Skip if no message (trivial session)
if [ -z "$last_msg" ]; then
    exit 0
fi

# --- Check if Stop hook already captured this session ---
# If an episodic entry was written in the last 60 seconds, skip
# (Stop hook likely already ran successfully)
ensure_project_dirs
proj_dir="$(get_project_dir)"
today="$(date +%Y-%m-%d)"
episodic_file="${proj_dir}/episodic/${today}.md"

if [ -f "$episodic_file" ]; then
    # Check if file was modified in the last 60 seconds
    if python3 -c "
import os, sys, time
mtime = os.path.getmtime(sys.argv[1])
if time.time() - mtime < 60:
    sys.exit(0)  # Recently modified — Stop hook likely ran
sys.exit(1)
" "$episodic_file" 2>/dev/null; then
        exit 0  # Stop hook already captured
    fi
fi

# --- Quick capture: extract session recap if present ---
session_recap=""
if [ -n "$last_msg" ]; then
    session_recap="$(python3 -c "
import sys
text = sys.argv[1]
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
" "$last_msg" 2>/dev/null || echo "")"
fi

# --- Build quick episodic entry ---
now="$(date +%H:%M)"
branch="$(git branch --show-current 2>/dev/null || echo "unknown")"
git_log="$(git log --oneline --since='12 hours ago' --no-merges 2>/dev/null | head -5 || echo "")"

# Create header if file doesn't exist
if [ ! -f "$episodic_file" ]; then
    printf '# %s\n\n' "$today" > "$episodic_file"
fi

{
    if [ -n "$session_recap" ]; then
        # Use Claude's own recap (highest quality)
        printf '### %s — Session ended\n' "$now"
        printf '%s\n' "$session_recap"
        printf -- '- **Branch:** %s\n' "$branch"
        printf -- '- **Note:** Captured from session recap at exit\n\n'
    elif [ -n "$git_log" ]; then
        # Fall back to git log summary
        printf '### %s — Session ended\n' "$now"
        printf -- '- **Branch:** %s\n' "$branch"
        printf -- '- **Commits:**\n'
        while IFS= read -r line; do
            printf '  - %s\n' "$line"
        done <<< "$git_log"
        printf -- '- **Note:** Quick capture at exit (Stop hook may not have completed)\n\n'
    fi
} >> "$episodic_file"

exit 0
