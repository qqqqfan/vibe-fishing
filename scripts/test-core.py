#!/usr/bin/env python3
"""Run the checked-in RelayCore tests with Command Line Tools alone.

The macOS Command Line Tools do not ship XCTest. This runner reads the real
XCTest source, removes only its XCTest imports/base class, and supplies the
small assertion surface used by that source. It does not maintain a second
copy of the test scenarios. Compiler output and module caches stay in .build.

Usage: python3 scripts/test-core.py
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
TEST_SOURCE = ROOT / "Tests/RelayCoreTests/RelayStateMachineTests.swift"
BUILD = ROOT / ".build/core-tests"
MODULE_CACHE = ROOT / ".build/module-cache"
DEVELOPER_DIRECTORY = Path("/Library/Developer/CommandLineTools")


ASSERTIONS = r'''
import Foundation

private var assertionCount = 0

func XCTAssertEqual<T: Equatable>(
    _ lhs: @autoclosure () throws -> T,
    _ rhs: @autoclosure () throws -> T,
    file: StaticString = #file, line: UInt = #line
) {
    do {
        let actual = try lhs()
        let expected = try rhs()
        precondition(actual == expected, "Expected \(actual) == \(expected)", file: file, line: line)
        assertionCount += 1
    } catch {
        fatalError("Unexpected error: \(error)", file: file, line: line)
    }
}

func XCTAssertTrue(
    _ value: @autoclosure () -> Bool,
    file: StaticString = #file, line: UInt = #line
) {
    precondition(value(), "Expected true", file: file, line: line)
    assertionCount += 1
}

func XCTAssertFalse(
    _ value: @autoclosure () -> Bool,
    file: StaticString = #file, line: UInt = #line
) {
    precondition(!value(), "Expected false", file: file, line: line)
    assertionCount += 1
}

func XCTAssertNil<T>(
    _ value: @autoclosure () -> T?,
    file: StaticString = #file, line: UInt = #line
) {
    precondition(value() == nil, "Expected nil", file: file, line: line)
    assertionCount += 1
}

func XCTUnwrap<T>(
    _ value: @autoclosure () throws -> T?,
    file: StaticString = #file, line: UInt = #line
) throws -> T {
    guard let actual = try value() else {
        fatalError("Expected nonnil", file: file, line: line)
    }
    assertionCount += 1
    return actual
}
'''


def prepare_runner(source: str) -> tuple[str, int]:
    """Keep test bodies verbatim; fail instead of silently skipping new tests."""
    class_pattern = r"(?m)^final class (\w+): XCTestCase \{"
    classes = re.findall(class_pattern, source)
    if len(classes) != 1:
        raise ValueError("Expected exactly one final XCTestCase class in the test source")

    test_names = re.findall(r"\bfunc\s+(test\w+)\s*\(", source)
    test_signatures = re.findall(
        r"(?m)^\s+func (test\w+)\(\)( throws)? \{", source
    )
    if not test_signatures or [name for name, _ in test_signatures] != test_names:
        raise ValueError(
            "Unsupported test signature: this runner supports synchronous, "
            "zero-argument test methods with optional throws"
        )
    if len(set(test_names)) != len(test_names):
        raise ValueError("Test method names must be unique")

    # Replace imports with blank lines so diagnostics retain original lines.
    transformed = re.sub(r"(?m)^import XCTest[ \t]*$", "", source)
    transformed = re.sub(r"(?m)^@testable import RelayCore[ \t]*$", "", transformed)
    transformed = re.sub(class_pattern, r"final class \1 {", transformed)
    if "import XCTest" in transformed or "XCTestCase" in transformed:
        raise ValueError("Unexpected XCTest declaration remains in the test source")

    runner = (
        ASSERTIONS
        + f"\n#sourceLocation(file: {json.dumps(str(TEST_SOURCE), ensure_ascii=False)}, line: 1)\n"
        + transformed
        + "\n#sourceLocation()\n"
        + f"let suite = {classes[0]}()\n"
    )
    for name, throwing in test_signatures:
        runner += f"{'try ' if throwing else ''}suite.{name}()\n"
        runner += f'print("PASS {name}")\n'
    runner += (
        f'print("{len(test_signatures)} scenarios passed; '
        '\\(assertionCount) assertions")\n'
    )
    return runner, len(test_signatures)


def main() -> int:
    if sys.platform != "darwin":
        print("This runner requires macOS Command Line Tools.", file=sys.stderr)
        return 1
    if not (DEVELOPER_DIRECTORY / "usr/bin/swiftc").is_file():
        print("Swift Command Line Tools were not found in /Library/Developer/CommandLineTools.", file=sys.stderr)
        return 1

    sources = sorted((ROOT / "Sources/RelayCore").rglob("*.swift"))
    if not sources:
        raise ValueError("No RelayCore Swift source files found")
    runner, count = prepare_runner(TEST_SOURCE.read_text(encoding="utf-8"))
    BUILD.mkdir(parents=True, exist_ok=True)
    MODULE_CACHE.mkdir(parents=True, exist_ok=True)
    runner_path = BUILD / "main.swift"
    runner_path.write_text(runner, encoding="utf-8")
    executable = BUILD / "relay-core-tests"

    environment = os.environ.copy()
    environment.update(
        DEVELOPER_DIR=str(DEVELOPER_DIRECTORY),
        CLANG_MODULE_CACHE_PATH=str(MODULE_CACHE),
        SWIFTPM_MODULECACHE_OVERRIDE=str(MODULE_CACHE),
    )
    command = [
        "/usr/bin/xcrun", "swiftc", "-swift-version", "5",
        "-module-cache-path", str(MODULE_CACHE),
        *map(str, sources), str(runner_path), "-o", str(executable),
    ]
    print(f"Compiling {count} scenarios from {TEST_SOURCE.relative_to(ROOT)}", flush=True)
    subprocess.run(command, cwd=ROOT, env=environment, check=True)
    subprocess.run([str(executable)], cwd=ROOT, env=environment, check=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Core tests failed: {error}", file=sys.stderr)
        raise SystemExit(1)
