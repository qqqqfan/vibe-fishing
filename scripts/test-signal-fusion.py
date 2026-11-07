#!/usr/bin/env python3
"""Run the checked-in playback-signal XCTest scenarios with the CLT runner."""

import importlib.util
from pathlib import Path
import subprocess
import sys


script = Path(__file__).resolve()
sys.dont_write_bytecode = True
runner_path = script.with_name("test-core.py")
spec = importlib.util.spec_from_file_location("relay_test_runner", runner_path)
if spec is None or spec.loader is None:
    raise SystemExit("Cannot load the core test runner")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.TEST_SOURCE = runner.ROOT / "Tests/RelayCoreTests/PlaybackSignalFusionTests.swift"
runner.BUILD = runner.ROOT / ".build/signal-fusion-tests"

if __name__ == "__main__":
    try:
        raise SystemExit(runner.main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Playback signal tests failed: {error}", file=sys.stderr)
        raise SystemExit(1)
