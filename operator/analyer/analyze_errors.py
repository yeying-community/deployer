#!/usr/bin/env python3
"""Compatibility entrypoint for the installed yeying-ops Skill."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def workflow_path() -> Path:
    configured = os.environ.get("YEYING_OPS_HOME")
    candidates = []
    if configured:
        candidates.append(Path(configured).expanduser())
    candidates.extend(
        [
            Path("~/.codex/skills/yeying-ops").expanduser(),
            Path("~/.claude/skills/yeying-ops").expanduser(),
        ]
    )
    for root in candidates:
        workflow = root / "scripts" / "ops_workflow.py"
        if workflow.is_file():
            return workflow.resolve()
    searched = ", ".join(str(path) for path in candidates)
    raise RuntimeError(f"installed yeying-ops Skill not found; searched: {searched}")


def main() -> int:
    try:
        workflow = workflow_path()
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    os.execv(sys.executable, [sys.executable, str(workflow), "analyze", *sys.argv[1:]])
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
