#!/usr/bin/env bash
# Shared utilities for recall hooks
# Zero dependencies beyond bash + python3

# project_hash — SHA-256 of cwd truncated to 12 chars
project_hash() {
    printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-12
}

# get_project_dir — full path to this project's recall storage
# Uses CLAUDE_PLUGIN_DATA if set, otherwise falls back to ~/.recall
get_project_dir() {
    local base="${CLAUDE_PLUGIN_DATA:-${HOME}/.recall}"
    local hash
    hash="$(project_hash)"
    printf '%s' "${base}/projects/${hash}"
}

# ensure_project_dirs — create storage directories if they don't exist
ensure_project_dirs() {
    local proj_dir
    proj_dir="$(get_project_dir)"
    mkdir -p "${proj_dir}/episodic" "${proj_dir}/semantic"
}

# escape_json — escape a string for safe embedding in JSON
escape_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# json_field — extract a field from JSON using python3 (NOT jq — avoids corruption bug)
# Usage: json_field '{"key":"val"}' 'key'
# Supports nested access: json_field "$json" 'a.b.c'
json_field() {
    local json="$1"
    local field="$2"
    python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    keys = sys.argv[2].split('.')
    val = data
    for k in keys:
        if isinstance(val, dict):
            val = val.get(k, '')
        else:
            val = ''
            break
    if val is None:
        val = ''
    print(val, end='')
except Exception:
    print('', end='')
" "$json" "$field"
}

# truncate_to — truncate string to N characters, append ... if truncated
truncate_to() {
    local text="$1"
    local max="$2"
    if [ "${#text}" -le "$max" ]; then
        printf '%s' "$text"
    else
        printf '%s...' "${text:0:$((max - 3))}"
    fi
}
