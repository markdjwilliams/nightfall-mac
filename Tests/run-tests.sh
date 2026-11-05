#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nightfall-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$PROJECT_DIR/.build/module-cache" "$PROJECT_DIR"/Sources/NightfallCore/*.swift "$PROJECT_DIR/Tests/EngineTests.swift" -o "$TEST_DIR/engine-tests"
"$TEST_DIR/engine-tests"
