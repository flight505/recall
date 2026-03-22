#!/usr/bin/env python3
"""Extract conversation data from Claude Code JSONL transcript.

Two modes:
  summary  — For stop.sh: first/last user msg, middle samples, last assistant response,
              tool count/names, file paths, error count
  working  — For pre-compact.sh: last 5 user msgs, last 3 assistant msgs, file paths

Streams JSONL line-by-line — never loads full file into memory.
Reads from stdin.
"""

import json
import sys
import re

# Prefixes that indicate system-injected content, not real user intent
NOISE_PREFIXES = (
    "<command-message>",
    "<command-name>",
    "<task-notification>",
    "<system-reminder>",
    "<local-command",
    "<command-args>",
    "Base directory for this skill:",
    "# ",  # Skill expansions start with markdown headers
)


def is_noise(text):
    """Check if a user message is system-injected noise rather than real user input."""
    stripped = text.strip()
    if not stripped:
        return True
    # Check for known system prefixes
    for prefix in NOISE_PREFIXES:
        if stripped.startswith(prefix):
            return True
    # Tool results are not user intent
    if stripped.startswith("<tool_result") or stripped.startswith("<function_results"):
        return True
    # Very short messages that are just command invocations
    if len(stripped) < 5 and stripped.startswith("/"):
        return True
    return False


def extract_text(content):
    """Extract text from message content (string or list of blocks)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text":
                    parts.append(block.get("text", ""))
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)
    return ""


def extract_file_paths(content):
    """Extract file paths from tool_use blocks in message content."""
    paths = set()
    if not isinstance(content, list):
        return paths
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_use":
            inp = block.get("input", {})
            if isinstance(inp, dict):
                for key in ("file_path", "path", "filePath"):
                    val = inp.get(key)
                    if val and isinstance(val, str):
                        paths.add(val)
                # Also check command for file references
                cmd = inp.get("command", "")
                if isinstance(cmd, str):
                    # Match common file path patterns
                    for match in re.findall(r'(?:^|\s)(/[^\s;|&]+)', cmd):
                        if '.' in match.split('/')[-1]:
                            paths.add(match)
    return paths


def mode_summary(lines):
    """Summary mode: rich extraction for episodic capture."""
    first_user = None
    last_user = None
    last_assistant = None
    all_user_msgs = []
    tool_count = 0
    tool_names = set()
    file_paths = set()
    error_count = 0

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Handle both top-level role and nested message.role formats
        role = entry.get("role", "")
        content = entry.get("content", "")
        if not role and "message" in entry:
            msg = entry["message"]
            if isinstance(msg, dict):
                role = msg.get("role", "")
                content = msg.get("content", "")

        # Skip non-conversation entries (progress, system, queue-operation, etc.)
        if role not in ("user", "assistant"):
            continue

        if role == "user":
            text = extract_text(content)
            if text.strip():
                clean = text.strip()
                # For first/last user, skip noise to find real user intent
                if not is_noise(clean):
                    if first_user is None:
                        first_user = clean
                    last_user = clean
                    all_user_msgs.append(clean)
            # Count error results from tool_result blocks
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        if block.get("is_error"):
                            error_count += 1

        elif role == "assistant":
            text = extract_text(content)
            if text.strip():
                last_assistant = text.strip()
            # Count tool uses, collect names and file paths
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_count += 1
                        tool_names.add(block.get("name", "unknown"))
            file_paths.update(extract_file_paths(content))

    # Build middle sample: up to 3 evenly-spaced user messages from the middle
    middle_sample = ""
    if len(all_user_msgs) > 2:
        middles = all_user_msgs[1:-1]
        step = max(1, len(middles) // 3)
        samples = middles[::step][:3]
        middle_sample = " | ".join(s[:200] for s in samples)

    result = {
        "first_user": first_user or "",
        "last_user": last_user or "",
        "last_assistant": last_assistant or "",
        "tool_count": tool_count,
        "tool_names": ", ".join(sorted(tool_names)),
        "file_paths": ", ".join(sorted(file_paths)[:20]),
        "middle_sample": middle_sample,
        "error_count": error_count,
    }
    json.dump(result, sys.stdout)


def mode_working(lines):
    """Working mode: last 5 user msgs, last 3 assistant msgs, file paths."""
    user_msgs = []
    assistant_msgs = []
    file_paths = set()

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        role = entry.get("role", "")
        content = entry.get("content", "")

        if role == "user":
            text = extract_text(content)
            if text.strip():
                user_msgs.append(text.strip())

        elif role == "assistant":
            text = extract_text(content)
            if text.strip():
                assistant_msgs.append(text.strip())
            file_paths.update(extract_file_paths(content))

    result = {
        "user_msgs": user_msgs[-5:],
        "assistant_msgs": assistant_msgs[-3:],
        "file_paths": sorted(file_paths),
    }
    json.dump(result, sys.stdout)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("summary", "working"):
        print("Usage: extract-last-turn.py <summary|working>", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]
    lines = sys.stdin

    if mode == "summary":
        mode_summary(lines)
    else:
        mode_working(lines)


if __name__ == "__main__":
    main()
