#!/bin/bash
# Install only Nightfall's own system service and per-user menu bar agent.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

fail() { printf 'Nightfall installation: %s\n' "$*" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || fail 'Administrator authorization is required.'
[[ "$#" -eq 1 ]] || fail 'Usage: install.sh /absolute/path/Nightfall.app'
[[ "$1" == /* ]] || fail 'The source app path must be absolute.'
source_app="$1"
[[ -d "$source_app" && ! -L "$source_app" ]] || fail 'The source app is missing or is a symbolic link.'

app='/Applications/Nightfall.app'
helper='/Library/PrivilegedHelperTools/com.nightfall.mac.daemon'
daemon_plist='/Library/LaunchDaemons/com.nightfall.mac.daemon.plist'
agent_plist='/Library/LaunchAgents/com.nightfall.mac.agent.plist'
state='/Library/Application Support/Nightfall'
daemon_label='com.nightfall.mac.daemon'
agent_label='com.nightfall.mac.agent'
stage=''
changes_started=0
daemon_was_loaded=0
old_app=0
old_helper=0
old_daemon_plist=0
old_agent_plist=0
new_app_installed=0
gui_uids=()
old_agent_uids=()

# Privileged code is kept here rather than in /Applications, whose parent is
# normally group-writable. An administrator could otherwise replace the app
# without authorization and have launchd execute that replacement as root.
for directory in /Library/PrivilegedHelperTools /Library/LaunchDaemons /Library/LaunchAgents; do
    [[ ! -L "$directory" ]] || fail "Refusing symbolic-link directory: $directory"
    if [[ ! -d "$directory" ]]; then /usr/bin/install -d -o root -g wheel -m 755 "$directory"; fi
    [[ "$(/usr/bin/stat -f %u "$directory")" -eq 0 ]] || fail "Directory is not owned by root: $directory"
    mode="$(/usr/bin/stat -f %Lp "$directory")"
    (( (8#$mode & 0022) == 0 )) || fail "Directory permits unprivileged writes: $directory"
done
for destination in "$app" "$helper" "$daemon_plist" "$agent_plist" "$state"; do
    [[ ! -L "$destination" ]] || fail "Refusing symbolic-link destination: $destination"
done
if [[ -e "$state" ]]; then
    [[ -d "$state" && "$(/usr/bin/stat -f %u "$state")" -eq 0 ]] || fail 'Existing Nightfall state is not a root-owned directory.'
    mode="$(/usr/bin/stat -f %Lp "$state")"
    (( (8#$mode & 0022) == 0 )) || fail 'Existing Nightfall state permits unprivileged writes.'
    [[ -z "$(/usr/bin/find "$state" -type l -print -quit)" ]] || fail 'Existing Nightfall state contains symbolic links.'
fi

while IFS= read -r uid; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    if /bin/launchctl print "gui/$uid" >/dev/null 2>&1; then
        gui_uids+=("$uid")
        if /bin/launchctl print "gui/$uid/$agent_label" >/dev/null 2>&1; then old_agent_uids+=("$uid"); fi
    fi
done < <(/usr/bin/dscl . -list /Users UniqueID | /usr/bin/awk '$2 >= 500 {print $2}' | /usr/bin/sort -n -u)
if /bin/launchctl print "system/$daemon_label" >/dev/null 2>&1; then daemon_was_loaded=1; fi

cleanup() {
    result=$?
    recovered=1
    trap - EXIT HUP INT TERM
    if [[ "$result" -ne 0 && "$changes_started" -eq 1 ]]; then
        printf 'Installation did not finish; restoring the previous installation.\n' >&2
        /bin/launchctl bootout "system/$daemon_label" >/dev/null 2>&1 || true
        for uid in ${gui_uids[@]+"${gui_uids[@]}"}; do /bin/launchctl bootout "gui/$uid/$agent_label" >/dev/null 2>&1 || true; done
        if [[ "$new_app_installed" -eq 1 ]]; then /bin/rm -rf "$app"; fi
        /bin/rm -f "$helper" "$daemon_plist" "$agent_plist"
        if [[ "$old_app" -eq 1 ]]; then /bin/mv "$stage/previous.app" "$app" || recovered=0; fi
        if [[ "$old_helper" -eq 1 ]]; then /bin/cp -p "$stage/previous-helper" "$helper" || recovered=0; fi
        if [[ "$old_daemon_plist" -eq 1 ]]; then /bin/cp -p "$stage/previous-daemon.plist" "$daemon_plist" || recovered=0; fi
        if [[ "$old_agent_plist" -eq 1 ]]; then /bin/cp -p "$stage/previous-agent.plist" "$agent_plist" || recovered=0; fi
        if [[ "$daemon_was_loaded" -eq 1 && -f "$daemon_plist" ]]; then /bin/launchctl bootstrap system "$daemon_plist" >/dev/null 2>&1 || true; fi
        for uid in ${old_agent_uids[@]+"${old_agent_uids[@]}"}; do /bin/launchctl bootstrap "gui/$uid" "$agent_plist" >/dev/null 2>&1 || true; done
    fi
    if [[ -n "$stage" && -d "$stage" ]]; then
        if [[ "$recovered" -eq 1 ]]; then /bin/rm -rf "$stage";
        else printf 'Recovery files were retained at: %s\n' "$stage" >&2; fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

stage="$(/usr/bin/mktemp -d '/Library/PrivilegedHelperTools/.nightfall-install.XXXXXX')"
/usr/bin/ditto "$source_app" "$stage/Nightfall.app"
staged_app="$stage/Nightfall.app"
[[ -f "$staged_app/Contents/Info.plist" ]] || fail 'The source is not an application bundle.'
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staged_app/Contents/Info.plist")"
[[ "$bundle_id" == 'com.nightfall.mac' ]] || fail 'The source bundle is not Nightfall.'
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$staged_app/Contents/Info.plist")"
[[ "$bundle_executable" == 'Nightfall' && -f "$staged_app/Contents/MacOS/Nightfall" && -x "$staged_app/Contents/MacOS/Nightfall" ]] || fail 'The Nightfall executable is missing.'
[[ -z "$(/usr/bin/find "$staged_app" -type l -print -quit)" ]] || fail 'The source bundle contains symbolic links.'
/usr/bin/codesign --verify --deep --strict "$staged_app" || fail 'The app signature is invalid. Build the app again.'
/usr/sbin/chown -R root:wheel "$staged_app"
/bin/chmod -R u+rwX,go+rX,go-w "$staged_app"
/bin/chmod -R a-s "$staged_app"
/usr/bin/install -o root -g wheel -m 755 "$staged_app/Contents/MacOS/Nightfall" "$stage/new-helper"

cat > "$stage/new-daemon.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.nightfall.mac.daemon</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/com.nightfall.mac.daemon</string><string>--daemon</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>WorkingDirectory</key><string>/</string>
<key>AssociatedBundleIdentifiers</key><string>com.nightfall.mac</string>
<key>StandardOutPath</key><string>/Library/Application Support/Nightfall/service.log</string>
<key>StandardErrorPath</key><string>/Library/Application Support/Nightfall/service.log</string>
</dict></plist>
PLIST
cat > "$stage/new-agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.nightfall.mac.agent</string>
<key>ProgramArguments</key><array><string>/Applications/Nightfall.app/Contents/MacOS/Nightfall</string><string>--agent</string></array>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Interactive</string>
<key>AssociatedBundleIdentifiers</key><string>com.nightfall.mac</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$stage/new-daemon.plist" "$stage/new-agent.plist" >/dev/null

# Stage backups before stopping either service. State stays in place on upgrades.
if [[ -e "$helper" ]]; then /bin/cp -p "$helper" "$stage/previous-helper"; old_helper=1; fi
if [[ -e "$daemon_plist" ]]; then /bin/cp -p "$daemon_plist" "$stage/previous-daemon.plist"; old_daemon_plist=1; fi
if [[ -e "$agent_plist" ]]; then /bin/cp -p "$agent_plist" "$stage/previous-agent.plist"; old_agent_plist=1; fi
changes_started=1
/bin/launchctl bootout "system/$daemon_label" >/dev/null 2>&1 || true
for uid in ${gui_uids[@]+"${gui_uids[@]}"}; do /bin/launchctl bootout "gui/$uid/$agent_label" >/dev/null 2>&1 || true; done
if [[ -e "$app" ]]; then /bin/mv "$app" "$stage/previous.app"; old_app=1; fi
/bin/mv "$staged_app" "$app"
new_app_installed=1
/usr/bin/install -o root -g wheel -m 755 "$stage/new-helper" "$helper"
/usr/bin/install -o root -g wheel -m 644 "$stage/new-daemon.plist" "$daemon_plist"
/usr/bin/install -o root -g wheel -m 644 "$stage/new-agent.plist" "$agent_plist"
/usr/bin/install -d -o root -g wheel -m 700 "$state"
/bin/launchctl bootstrap system "$daemon_plist"
for uid in ${gui_uids[@]+"${gui_uids[@]}"}; do
    if ! /bin/launchctl bootstrap "gui/$uid" "$agent_plist"; then
        printf 'Nightfall: the menu bar agent could not start for user ID %s; check Login Items or sign in again.\n' "$uid" >&2
    fi
done
changes_started=0
printf 'Nightfall is installed for all users. Existing schedule and cancellations were preserved.\n'
