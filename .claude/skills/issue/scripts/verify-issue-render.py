#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

repo_root = Path(__file__).resolve().parents[4]
target = repo_root / "agents/shared/issue-tools/verify-issue-render.py"
os.execv(sys.executable, [sys.executable, str(target), *sys.argv[1:]])
