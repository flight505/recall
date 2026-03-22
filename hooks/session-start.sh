#!/usr/bin/env bash
# SessionStart hook — inject recalled memories into context
# Runs sync with 5s timeout — must be fast

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

BUDGET=4000  # Max chars for injected context

# --- Read hook input from stdin ---
hook_input=""
if [ ! -t 0 ]; then
    hook_input="$(cat)"
fi

# --- Determine source event ---
source_event=""
if [ -n "$hook_input" ]; then
    source_event="$(json_field "$hook_input" "source")"
fi

# --- Gather context signals ---
branch="$(git branch --show-current 2>/dev/null || echo "")"
proj_dir="$(get_project_dir)"

# --- Build context sections with priority ---
# Priority: working-state (if compact) > latest episodic > architecture > branch-matching
sections=()
total_chars=0

add_section() {
    local label="$1"
    local content="$2"
    local char_count="${#content}"

    if [ "$char_count" -eq 0 ]; then
        return
    fi

    local remaining=$((BUDGET - total_chars))
    if [ "$remaining" -le 50 ]; then
        return  # Not enough budget left
    fi

    if [ "$char_count" -gt "$remaining" ]; then
        content="$(truncate_to "$content" "$remaining")"
        char_count="${#content}"
    fi

    sections+=("**${label}:**\n${content}")
    total_chars=$((total_chars + char_count + ${#label} + 10))
}

# 1. Working state (highest priority if resuming from compaction)
if [ "$source_event" = "compact" ] && [ -f "${proj_dir}/working-state.md" ]; then
    working_state="$(cat "${proj_dir}/working-state.md" 2>/dev/null || echo "")"
    if [ -n "$working_state" ]; then
        add_section "Working State (pre-compaction)" "$working_state"
    fi
fi

# 2. Latest episodic entry
latest_episodic=""
if [ -d "${proj_dir}/episodic" ]; then
    # Find most recent episodic file
    latest_file="$(ls -1 "${proj_dir}/episodic/"*.md 2>/dev/null | sort -r | head -1 || echo "")"
    if [ -n "$latest_file" ] && [ -f "$latest_file" ]; then
        # Get the last session entry (last ### block)
        latest_episodic="$(python3 -c "
import sys
content = open(sys.argv[1]).read()
blocks = content.split('### ')
if len(blocks) > 1:
    # Last non-empty block
    for block in reversed(blocks[1:]):
        if block.strip():
            print('### ' + block.strip())
            break
" "$latest_file" 2>/dev/null || echo "")"
    fi
fi
if [ -n "$latest_episodic" ]; then
    add_section "Last Session" "$latest_episodic"
fi

# 3. Architecture (semantic memory)
if [ -f "${proj_dir}/semantic/architecture.md" ]; then
    arch_content="$(cat "${proj_dir}/semantic/architecture.md" 2>/dev/null || echo "")"
    if [ -n "$arch_content" ]; then
        # Check staleness
        last_verified="$(python3 -c "
import sys, re
content = open(sys.argv[1]).read()
m = re.search(r'Last verified:\s*(\d{4}-\d{2}-\d{2})', content)
if m:
    print(m.group(1))
else:
    print('')
" "${proj_dir}/semantic/architecture.md" 2>/dev/null || echo "")"

        stale_warning=""
        if [ -n "$last_verified" ]; then
            days_old="$(python3 -c "
from datetime import datetime, date
import sys
try:
    verified = datetime.strptime(sys.argv[1], '%Y-%m-%d').date()
    delta = (date.today() - verified).days
    print(delta)
except Exception:
    print(0)
" "$last_verified" 2>/dev/null || echo "0")"

            if [ "$days_old" -gt 30 ]; then
                stale_warning=" [STALE — last verified ${last_verified}, ${days_old} days ago]"
            fi
        fi

        add_section "Architecture${stale_warning}" "$arch_content"
    fi
fi

# 4. Branch-matching episodic entries (if we have budget and a branch)
if [ -n "$branch" ] && [ "$total_chars" -lt "$((BUDGET - 100))" ] && [ -d "${proj_dir}/episodic" ]; then
    # Search last 7 days of episodic files for branch mentions
    branch_matches="$(python3 -c "
import os, sys, glob
from datetime import date, timedelta

episodic_dir = sys.argv[1]
branch = sys.argv[2]
cutoff = date.today() - timedelta(days=7)

matches = []
for f in sorted(glob.glob(os.path.join(episodic_dir, '*.md')), reverse=True):
    basename = os.path.basename(f).replace('.md', '')
    try:
        file_date = date.fromisoformat(basename)
        if file_date < cutoff:
            continue
    except ValueError:
        continue

    with open(f) as fh:
        content = fh.read()
    if branch.lower() in content.lower():
        # Extract matching blocks
        for block in content.split('### ')[1:]:
            if branch.lower() in block.lower():
                matches.append('### ' + block.strip())

if matches:
    # Return last 2 matches
    for m in matches[-2:]:
        print(m)
" "${proj_dir}/episodic" "$branch" 2>/dev/null || echo "")"

    if [ -n "$branch_matches" ]; then
        add_section "Branch History (${branch})" "$branch_matches"
    fi
fi

# 5. Previous session entry (if resuming)
if [ "$source_event" = "resume" ] && [ "$total_chars" -lt "$((BUDGET - 100))" ]; then
    if [ -n "$latest_episodic" ]; then
        # Already included as "Last Session" — check for second-to-last
        :
    fi
fi

# --- Build output ---
if [ "${#sections[@]}" -eq 0 ]; then
    # No memories yet — still output a minimal message
    context_text="[recall] No memories stored yet for this project. Memories will be captured when you end sessions."
else
    header="[recall] Recalled context for $(basename "$(pwd)"):"
    body=""
    for section in "${sections[@]}"; do
        if [ -n "$body" ]; then
            body="${body}\n\n"
        fi
        body="${body}${section}"
    done
    context_text="${header}\n\n${body}"
fi

# --- Output JSON ---
escaped="$(escape_json "$(printf '%b' "$context_text")")"

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${escaped}"
  }
}
EOF

exit 0
