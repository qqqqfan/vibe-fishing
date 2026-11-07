#!/usr/bin/env python3
"""Test real outline geometry without creating windows or accessing other apps."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
build = root / ".build/attention-outline-tests"
build.mkdir(parents=True, exist_ok=True)
run = Path(tempfile.mkdtemp(prefix="run-", dir=build))
cache = build / "module-cache"
cache.mkdir(exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR="/Library/Developer/CommandLineTools")
executable = run / "attention-outline-tests"
subprocess.run([
    "/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(cache),
    str(root / "Sources/MoyuRelay/AttentionOutlineGeometry.swift"),
    str(root / "Tests/AttentionOutlineHarness/AttentionOutlineTests.swift"),
    "-o", str(executable),
], cwd=root, env=env, check=True)
subprocess.run([str(executable)], cwd=root, env=env, check=True)
