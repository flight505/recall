#!/usr/bin/env python3
"""Extract conversation data from Claude Code JSONL transcript.

Three modes:
  summary  — For stop.sh: first/last user msg, middle samples, last assistant response,
              tool count/names, file paths, error count
  working  — For pre-compact.sh: last 5 user msgs, last 3 assistant msgs, file paths
  compress — For stop-compressed.sh: full conversation compressed by stripping
              mechanical overhead (tool_result content, progress, system entries).
              Gives haiku the full session narrative instead of fragments.

Streams JSONL line-by-line — never loads full file into memory.
Reads from stdin.
"""

import json
import os
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


def extract_git_commits(content):
    """Extract git commit messages from Bash tool_use blocks."""
    commits = []
    if not isinstance(content, list):
        return commits
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        inp = block.get("input", {})
        if not isinstance(inp, dict):
            continue
        cmd = inp.get("command", "")
        if not isinstance(cmd, str):
            continue
        if "git commit" in cmd:
            # Extract from heredoc: -m "$(cat <<'EOF'\n...\nEOF\n)"
            m = re.search(r"cat <<['\"]?EOF['\"]?\n(.*?)\nEOF", cmd, re.DOTALL)
            if m:
                commits.append(m.group(1).strip()[:200])
            else:
                # Simple -m "message"
                m = re.search(r'-m\s+["\']([^"\']+)["\']', cmd)
                if m:
                    commits.append(m.group(1).strip()[:200])
        elif "git push" in cmd:
            commits.append("[pushed to remote]")
    return commits


def extract_decision_lines(text):
    """Extract lines containing decision/milestone language from assistant text."""
    DECISION_RE = re.compile(
        r'## Decision:|'
        r'\*\*Chose:\*\*|'
        r'\*\*Intervention:\*\*|'
        r'feat:|fix:|docs:|refactor:|'
        r'v\d+\.\d+\.\d+|'
        r'committed|pushed to|SCORE:|'
        r'highest.impact|the real bottleneck|root cause',
        re.IGNORECASE
    )
    lines = []
    for line in text.split("\n"):
        line = line.strip()
        if line and DECISION_RE.search(line):
            lines.append(line[:150])
    return lines


def extract_edited_files(content):
    """Extract basenames of files modified by Edit/Write tools."""
    edits = []
    if not isinstance(content, list):
        return edits
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        name = block.get("name", "")
        if name in ("Edit", "Write"):
            inp = block.get("input", {})
            if isinstance(inp, dict):
                fp = inp.get("file_path", "")
                if fp:
                    edits.append(os.path.basename(fp))
    return edits


def mode_summary(lines):
    """Summary mode: git commits + tool actions as primary signal, user messages as secondary."""
    first_user = None
    last_user = None
    all_user_msgs = []
    tool_count = 0
    tool_names = set()
    file_paths = set()
    error_count = 0
    git_commits = []
    decision_lines = []
    edited_files = []

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
                if not is_noise(clean):
                    if first_user is None:
                        first_user = clean
                    last_user = clean
                    all_user_msgs.append(clean)
            # Count error results
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        if block.get("is_error"):
                            error_count += 1

        elif role == "assistant":
            text = extract_text(content)
            # Extract decision lines from assistant text
            if text.strip():
                decision_lines.extend(extract_decision_lines(text))
            # Count tool uses, collect names, file paths, commits, edits
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_count += 1
                        tool_names.add(block.get("name", "unknown"))
                git_commits.extend(extract_git_commits(content))
                edited_files.extend(extract_edited_files(content))
            file_paths.update(extract_file_paths(content))

    # Deduplicate
    unique_edits = sorted(set(edited_files))

    # Deduplicate decision lines, keep order, max 5
    seen = set()
    unique_decisions = []
    for dl in decision_lines:
        if dl not in seen:
            seen.add(dl)
            unique_decisions.append(dl)
        if len(unique_decisions) >= 5:
            break

    # Build user intent sample: up to 3 from middle, keyword-weighted
    INTENT_RE = re.compile(
        r'\b(want|need|fix|add|change|create|update|implement|'
        r'plan|research|assess|improve|commit|push|review|test|'
        r'recommend|should|lets|let\'s)\b',
        re.IGNORECASE
    )
    user_intent = ""
    if len(all_user_msgs) > 2:
        middles = all_user_msgs[1:-1]
        scored = [(len(INTENT_RE.findall(m)) + min(len(m) // 100, 3), m) for m in middles]
        scored.sort(reverse=True)
        samples = [m for _, m in scored[:3]]
        user_intent = " | ".join(s[:200] for s in samples)
    elif len(all_user_msgs) == 2:
        user_intent = all_user_msgs[1][:200]

    result = {
        "first_user": first_user or "",
        "last_user": last_user or "",
        "tool_count": tool_count,
        "tool_names": ", ".join(sorted(tool_names)),
        "file_paths": ", ".join(sorted(file_paths)[:20]),
        "error_count": error_count,
        # New primary signals
        "git_commits": " || ".join(git_commits[:10]),
        "decision_lines": " || ".join(unique_decisions),
        "edited_files": ", ".join(unique_edits[:15]),
        # User intent (secondary, keyword-weighted)
        "user_intent": user_intent,
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


def mode_compress(lines):
    """Compress mode: strip mechanical overhead, keep full session narrative.

    Skips progress, system, queue-operation, file-history-snapshot entries.
    Skips user entries that are just tool_result echoes.
    Keeps user text (truncated to 500 chars) and assistant text + tool names.
    Also extracts anchors (git commits, decisions, edited files, etc).
    """
    compressed = []
    first_user = None
    last_user = None
    tool_count = 0
    tool_names = set()
    file_paths = set()
    error_count = 0
    git_commits = []
    decision_lines = []
    edited_files = []

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Skip non-conversation entry types at top level
        entry_type = entry.get("type", "")
        if entry_type in ("progress", "system", "queue-operation",
                          "file-history-snapshot"):
            continue

        # Resolve role and content (top-level or nested message format)
        role = entry.get("role", "")
        content = entry.get("content", "")
        if not role and "message" in entry:
            msg = entry["message"]
            if isinstance(msg, dict):
                role = msg.get("role", "")
                content = msg.get("content", "")

        if role not in ("user", "assistant"):
            continue

        if role == "user":
            # Skip user entries that are just tool_result echoes
            if isinstance(content, list):
                has_tool_result = any(
                    isinstance(b, dict) and b.get("type") == "tool_result"
                    for b in content
                )
                if has_tool_result:
                    # Still count errors from tool results
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_result":
                            if block.get("is_error"):
                                error_count += 1
                    continue

            text = extract_text(content)
            clean = text.strip()
            if not clean:
                continue

            # Skip system-injected noise from the compressed narrative
            if is_noise(clean):
                continue

            # Track first/last user messages
            if first_user is None:
                first_user = clean
            last_user = clean

            # Output user line (truncate to 500 chars)
            compressed.append("USER: " + clean[:500])

        elif role == "assistant":
            text = extract_text(content)

            # Extract anchors from assistant content
            if text.strip():
                decision_lines.extend(extract_decision_lines(text))

            if isinstance(content, list):
                # Build assistant line: text + tool references
                parts = []
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type", "")
                    if btype == "text":
                        t = block.get("text", "").strip()
                        if t:
                            parts.append(t[:300])
                    elif btype == "tool_use":
                        tool_count += 1
                        name = block.get("name", "unknown")
                        tool_names.add(name)
                        inp = block.get("input", {})
                        # Extract file path for compact tool reference
                        fp = ""
                        if isinstance(inp, dict):
                            for key in ("file_path", "path", "filePath"):
                                val = inp.get(key)
                                if val and isinstance(val, str):
                                    fp = val
                                    break
                            if not fp:
                                cmd = inp.get("command", "")
                                if isinstance(cmd, str) and len(cmd) < 120:
                                    fp = cmd
                        if fp:
                            parts.append("[%s: %s]" % (name, fp))
                        else:
                            parts.append("[%s]" % name)

                # Collect git commits, edited files, file paths
                git_commits.extend(extract_git_commits(content))
                edited_files.extend(extract_edited_files(content))
                file_paths.update(extract_file_paths(content))

                combined = " ".join(parts)
                if combined.strip():
                    compressed.append("ASSISTANT: " + combined[:600])
            else:
                # Content is a plain string
                if text.strip():
                    compressed.append("ASSISTANT: " + text.strip()[:600])

    # Deduplicate anchors
    unique_edits = sorted(set(edited_files))

    seen = set()
    unique_decisions = []
    for dl in decision_lines:
        if dl not in seen:
            seen.add(dl)
            unique_decisions.append(dl)
        if len(unique_decisions) >= 5:
            break

    result = {
        "compressed_conversation": "\n".join(compressed),
        "git_commits": " || ".join(git_commits[:10]),
        "file_paths": ", ".join(sorted(file_paths)[:20]),
        "decision_lines": " || ".join(unique_decisions),
        "edited_files": ", ".join(unique_edits[:15]),
        "first_user": first_user or "",
        "last_user": last_user or "",
        "tool_count": tool_count,
        "tool_names": ", ".join(sorted(tool_names)),
        "error_count": error_count,
    }
    json.dump(result, sys.stdout)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("summary", "working", "compress"):
        print("Usage: extract-last-turn.py <summary|working|compress>", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]
    lines = sys.stdin

    if mode == "summary":
        mode_summary(lines)
    elif mode == "compress":
        mode_compress(lines)
    else:
        mode_working(lines)


if __name__ == "__main__":
    main()
