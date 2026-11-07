#!/usr/bin/env python3
"""Run window-layout geometry assertions against real product source.

Requires macOS Command Line Tools only. The harness calls the pure geometry
methods of WindowDock; it never creates a window, instantiates WindowDock,
queries AX, posts input, or requests permissions. Native AX code is linked only
so the original source compiles without maintaining a copied implementation.

Usage: python3 scripts/test-window-layout.py
All compiler outputs and caches stay in .build/window-layout-tests.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build/window-layout-tests"
DEVELOPER_DIRECTORY = Path("/Library/Developer/CommandLineTools")


def main() -> int:
    if sys.platform != "darwin" or not (DEVELOPER_DIRECTORY / "usr/bin/swiftc").is_file():
        raise ValueError("macOS Command Line Tools are required")
    core_sources = sorted((ROOT / "Sources/RelayCore").glob("*.swift"))
    if not core_sources:
        raise ValueError("No RelayCore source files found")
    harness = ROOT / "Tests/WindowLayoutHarness/WindowLayoutTests.swift"
    if not harness.is_file():
        raise ValueError("Window layout test harness is missing")
    BUILD.mkdir(parents=True, exist_ok=True)
    # Independent runs must not overwrite a static library while another run
    # links it (e.g. two collaborators validating the same checkout).
    run = Path(tempfile.mkdtemp(prefix="run-", dir=BUILD))
    cache = BUILD / "module-cache"
    cache.mkdir(exist_ok=True)
    environment = os.environ.copy()
    environment.update(DEVELOPER_DIR=str(DEVELOPER_DIRECTORY), CLANG_MODULE_CACHE_PATH=str(cache))
    compiler = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(cache)]
    library = run / "libRelayCore.a"
    print("Compiling real window-layout source; only pure geometry will execute.", flush=True)
    subprocess.run([
        *compiler, "-emit-library", "-static", "-emit-module", "-module-name", "RelayCore",
        *map(str, core_sources), "-emit-module-path", str(run / "RelayCore.swiftmodule"),
        "-o", str(library),
    ], cwd=ROOT, env=environment, check=True)
    executable = run / "window-layout-tests"
    subprocess.run([
        *compiler, "-I", str(run),
        str(ROOT / "Sources/MoyuRelay/AccessibilityProbe.swift"),
        str(ROOT / "Sources/MoyuRelay/WindowDock.swift"),
        str(harness), str(library), "-o", str(executable),
    ], cwd=ROOT, env=environment, check=True)
    subprocess.run([str(executable)], cwd=ROOT, env=environment, check=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Window layout tests failed: {error}", file=sys.stderr)
        raise SystemExit(1)
