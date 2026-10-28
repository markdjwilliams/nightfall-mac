#!/bin/bash
# Validate packaging without loading services, changing the system, or sleeping.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/nightfall-check.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

# bash treats additional filenames as arguments to the first script.
for script in "$script_dir"/*.sh; do /bin/bash -n "$script"; done
/usr/bin/plutil -lint "$project_dir/Resources/Info.plist"
/usr/bin/awk -v output="$temporary" '
    /^cat > .*<<.PLIST.$/ { count++; inside = 1; next }
    /^PLIST$/ { inside = 0; next }
    inside { print > (output "/job" count ".plist") }
' "$script_dir/install.sh"
/usr/bin/plutil -lint "$temporary/job1.plist" "$temporary/job2.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$temporary/job1.plist")" == '/Library/PrivilegedHelperTools/com.nightfall.mac.daemon' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LimitLoadToSessionType' "$temporary/job2.plist")" == 'Aqua' ]]
if [[ -d "$project_dir/build/Nightfall.app" ]]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/build/Nightfall.app/Contents/Info.plist")"
    /usr/bin/grep -Fq "static let current = \"$version\"" "$project_dir/Sources/Nightfall/IPC.swift"
    # Cross-built archives cannot execute on the host; test runtime metadata
    # when a native slice is available, without requiring Rosetta.
    case " $(/usr/bin/lipo -archs "$project_dir/build/Nightfall.app/Contents/MacOS/Nightfall") " in
        *" $(/usr/bin/uname -m) "*) [[ "$("$project_dir/build/Nightfall.app/Contents/MacOS/Nightfall" --version)" == "$version" ]] ;;
    esac
    /usr/bin/codesign --verify --deep --strict "$project_dir/build/Nightfall.app"
    /usr/bin/cmp "$project_dir/LICENSE" "$project_dir/build/Nightfall.app/Contents/Resources/LICENSE"
    /usr/bin/cmp "$project_dir/NOTICE.md" "$project_dir/build/Nightfall.app/Contents/Resources/NOTICE.md"
    /usr/bin/install -m 755 "$project_dir/build/Nightfall.app/Contents/Library/LaunchServices/com.nightfall.mac.daemon" "$temporary/daemon"
    /usr/bin/codesign --verify --strict --test-requirement='=identifier "com.nightfall.mac.daemon"' "$temporary/daemon"
    /usr/bin/plutil -lint "$project_dir/build/Nightfall.app/Contents/Info.plist"
fi
printf 'Packaging checks passed. No services or power actions were started.\n'
