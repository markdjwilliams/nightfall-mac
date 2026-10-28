#!/bin/bash
# Exercise model callbacks with injected responses; never connect to the service.
set -euo pipefail
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/nightfall-model-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT
mkdir -p "$project_dir/.build/model-tests-module-cache"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$project_dir/.build/model-tests-module-cache" \
    -framework AppKit -framework SwiftUI -framework CoreGraphics -framework SystemConfiguration -framework IOKit \
    "$project_dir"/Sources/NightfallCore/*.swift \
    "$project_dir/Sources/Nightfall/IPC.swift" "$project_dir/Sources/Nightfall/Daemon.swift" \
    "$project_dir/Sources/Nightfall/AppModel.swift" "$project_dir/Tests/AppModelTests.swift" \
    -o "$temporary/model-tests"
"$temporary/model-tests"
