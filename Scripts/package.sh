#!/bin/bash
# Build and validate a downloadable app without installing or starting it.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
build_dir="$project_dir/build"
app_dir="$build_dir/Nightfall.app"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/nightfall-package.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/bin/bash -n "$script_dir/package.sh"
"$script_dir/build.sh"
"$script_dir/check.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid app version: %s\n' "$version" >&2; exit 1; }
architectures="$(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/Nightfall")"
[[ "$architectures" =~ ^(arm64|x86_64)(\ (arm64|x86_64))*$ ]] || { printf 'Unsupported architectures: %s\n' "$architectures" >&2; exit 1; }
[[ "$architectures" == "$(/usr/bin/lipo -archs "$app_dir/Contents/Library/LaunchServices/com.nightfall.mac.daemon")" ]]
archive_name="Nightfall-$version-${architectures// /-}.zip"
archive="$build_dir/$archive_name"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
/usr/bin/ditto -x -k "$archive" "$temporary"
extracted_app="$temporary/Nightfall.app"
[[ -d "$extracted_app" ]]
/usr/bin/codesign --verify --deep --strict "$extracted_app"
/usr/bin/install -m 755 "$extracted_app/Contents/Library/LaunchServices/com.nightfall.mac.daemon" "$temporary/daemon"
/usr/bin/codesign --verify --strict --test-requirement='=identifier "com.nightfall.mac.daemon"' "$temporary/daemon"
/usr/bin/cmp "$project_dir/LICENSE" "$extracted_app/Contents/Resources/LICENSE"
/usr/bin/cmp "$project_dir/NOTICE.md" "$extracted_app/Contents/Resources/NOTICE.md"
[[ "$(/usr/bin/stat -f '%OLp' "$extracted_app/Contents/Resources/install.sh")" == 755 ]]
[[ "$(/usr/bin/stat -f '%OLp' "$extracted_app/Contents/Resources/uninstall.sh")" == 755 ]]
[[ "$(/usr/bin/stat -f '%OLp' "$extracted_app/Contents/MacOS/Nightfall")" == 755 ]]

# Use only the archive's basename so verification works on another Mac.
(
    cd "$build_dir"
    /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
    /usr/bin/shasum -a 256 -c "$archive_name.sha256"
)
printf '\nPackaged and verified:\n%s\n%s.sha256\n' "$archive" "$archive"
