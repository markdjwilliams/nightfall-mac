#!/bin/bash
# Pure probe-normalization fixtures; these do not access live display/input APIs.
set -euo pipefail
project_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/nightfall-system-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$project_dir/.build/module-cache" \
    -framework SystemConfiguration -framework IOKit -framework CoreGraphics \
    "$project_dir"/Sources/NightfallCore/*.swift \
    "$project_dir/Sources/Nightfall/IPC.swift" "$project_dir/Sources/Nightfall/Daemon.swift" \
    "$project_dir/Tests/SystemPresenceTests.swift" -o "$test_dir/system-tests"
"$test_dir/system-tests"
