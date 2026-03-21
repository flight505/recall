#!/usr/bin/env python3
"""Extract conversation data from Claude Code JSONL transcript.

Two modes:
  summary  — For stop.sh: first/last user msg + last assistant response + tool count
  working  — For pre-compact.sh: last 5 user msgs, last 3 assistant msgs, file paths

Streams JSONL line-by-line — never loads full file into memory.
Reads from stdin.
"""

import json
import sys
import re


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
    """Summary mode: first user msg, last user msg, last assistant response, tool count."""
    first_user = None
    last_user = None
    last_assistant = None
    tool_count = 0

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
                if first_user is None:
                    first_user = text.strip()
                last_user = text.strip()

        elif role == "assistant":
            text = extract_text(content)
            if text.strip():
                last_assistant = text.strip()
            # Count tool uses
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_count += 1

    result = {
        "first_user": first_user or "",
        "last_user": last_user or "",
        "last_assistant": last_assistant or "",
        "tool_count": tool_count,
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
