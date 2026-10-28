#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
build_dir="$project_dir/build"
app_dir="$build_dir/Nightfall.app"
architecture="${NIGHTFALL_ARCH:-$(/usr/bin/uname -m)}"

case "$architecture" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;; esac
mkdir -p "$build_dir/tools" "$build_dir/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$build_dir/ModuleCache"
export SWIFT_MODULECACHE_PATH="$build_dir/ModuleCache"

# This directory contains generated files only.
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"

sources=("$project_dir"/Sources/NightfallCore/*.swift "$project_dir"/Sources/Nightfall/*.swift)
/usr/bin/xcrun swiftc -swift-version 5 -O -whole-module-optimization \
    -target "$architecture-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework SystemConfiguration -framework IOKit \
    "${sources[@]}" -o "$app_dir/Contents/MacOS/Nightfall"

/usr/bin/xcrun swiftc -swift-version 5 -O -framework AppKit \
    "$project_dir/Resources/GenerateIcon.swift" -o "$build_dir/tools/generate-icon"
"$build_dir/tools/generate-icon" "$build_dir/Nightfall.iconset" "$build_dir/Nightfall-fallback.icns"
if ! /usr/bin/iconutil -c icns "$build_dir/Nightfall.iconset" -o "$app_dir/Contents/Resources/Nightfall.icns" 2>/dev/null; then
    cp "$build_dir/Nightfall-fallback.icns" "$app_dir/Contents/Resources/Nightfall.icns"
fi

/usr/bin/install -m 755 "$script_dir/install.sh" "$app_dir/Contents/Resources/install.sh"
/usr/bin/install -m 755 "$script_dir/uninstall.sh" "$app_dir/Contents/Resources/uninstall.sh"
/usr/bin/codesign --force --sign - --timestamp=none "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
printf '\nBuilt and verified: %s\n' "$app_dir"
