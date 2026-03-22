#!/usr/bin/env bash
# PostCompact hook — log compaction event to episodic memory
# Simple, no claude -p call needed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Read hook input from stdin ---
hook_input=""
if [ ! -t 0 ]; then
    hook_input="$(cat)"
fi

# --- Attempt to capture compact_summary if provided ---
compact_summary=""
if [ -n "$hook_input" ]; then
    compact_summary="$(json_field "$hook_input" "compact_summary")"
fi

# Ensure dirs exist
ensure_project_dirs

proj_dir="$(get_project_dir)"
today="$(date +%Y-%m-%d)"
now="$(date +%H:%M)"
episodic_file="${proj_dir}/episodic/${today}.md"

# Create header if file doesn't exist
if [ ! -f "$episodic_file" ]; then
    printf '# %s\n\n' "$today" > "$episodic_file"
fi

# Get branch for context
branch="$(git branch --show-current 2>/dev/null || echo "unknown")"

# Append compaction marker
{
    printf '### %s — Context compacted\n' "$now"
    printf -- '- **Event:** compaction\n'
    printf -- '- **Branch:** %s\n' "$branch"
    if [ -n "$compact_summary" ]; then
        compact_summary_t="$(truncate_to "$compact_summary" 500)"
        printf -- '- **Summary:** %s\n' "$compact_summary_t"
    fi
    printf -- '- **Note:** Working state was saved before compaction. Context continues below.\n\n'
} >> "$episodic_file"

exit 0
