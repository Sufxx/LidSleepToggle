#!/usr/bin/env python3
"""Exit 0 if Claude Code is actively working, 1 if idle. Prints a short reason.

Signals (OR):
  1. Any ~/.claude/projects/**/*.jsonl written within WINDOW seconds. Claude Code
     appends to the session transcript on every message/tool step, so recent writes
     mean it's actively working. This also bridges gaps between cron-triggered asks.
  2. The `claude` CLI process tree is burning CPU above CPU_THRESH percent. Covers a
     long single tool call (e.g. a build) that runs quietly with no transcript writes.

Usage: claude-active.py [WINDOW_SECONDS=300] [CPU_THRESH=40]
"""
import os
import sys
import time
import subprocess

WINDOW = int(sys.argv[1]) if len(sys.argv) > 1 else 300
CPU_THRESH = float(sys.argv[2]) if len(sys.argv) > 2 else 40.0
ROOT = os.path.expanduser("~/.claude/projects")


def newest_transcript_mtime():
    """Newest mtime across ALL sessions' transcripts (any session = counts)."""
    newest = 0.0
    for dirpath, _dirs, files in os.walk(ROOT):
        for f in files:
            if not f.endswith(".jsonl"):
                continue
            try:
                m = os.path.getmtime(os.path.join(dirpath, f))
            except OSError:
                continue
            if m > newest:
                newest = m
    return newest


def claude_tree_cpu():
    """Sum %CPU across the claude CLI process tree (incl. its Bash-tool
    descendants like npm/tsc/cargo), so a long quiet build keeps it awake."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-Ao", "pid=,ppid=,%cpu=,command="],
            capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return 0.0
    cpu, children, cmd = {}, {}, {}
    for line in out.splitlines():
        p = line.split(None, 3)
        if len(p) < 4:
            continue
        try:
            pid_, ppid_, cpu_ = int(p[0]), int(p[1]), float(p[2])
        except ValueError:
            continue
        cpu[pid_] = cpu_
        cmd[pid_] = p[3]
        children.setdefault(ppid_, []).append(pid_)

    def is_claude_cli(c: str) -> bool:
        c = c.lower()
        if "claude" not in c:
            return False
        return not any(x in c for x in
                       ("claude-active", "meeting-transcriber", "transcriberd",
                        "mcp", "lidsleeptoggle"))

    def tree(pid, seen):
        if pid in seen:
            return 0.0
        seen.add(pid)
        tot = cpu.get(pid, 0.0)
        for ch in children.get(pid, []):
            tot += tree(ch, seen)
        return tot

    seen = set()
    return sum(tree(pid, seen) for pid, c in cmd.items() if is_claude_cli(c))


# Report raw signals so the caller can size a dynamic idle window; still exit
# 0/1 against WINDOW for standalone use.
newest = newest_transcript_mtime()
age = int(time.time() - newest) if newest else -1
cpu_pct = int(claude_tree_cpu())
active = (0 <= age < WINDOW) or (cpu_pct >= CPU_THRESH)
print("age=%d cpu=%d %s" % (age, cpu_pct, "active" if active else "idle"))
sys.exit(0 if active else 1)
