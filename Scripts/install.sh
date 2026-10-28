#!/bin/bash
# Requires administrator authorization and an absolute source bundle path.
# Stage and validate the app before replacement; preserve shared schedule state.
# Failed upgrades attempt rollback and retain remaining backups if it fails.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

fail() { printf 'Nightfall installation: %s\n' "$*" >&2; exit 1; }
valid_uid() { [[ "$1" =~ ^[0-9]{3,10}$ ]] && (( 10#$1 >= 500 && 10#$1 <= 4294967294 )); }

# Missing jobs and users who signed out are safe. Other inspection failures must
# not be mistaken for a stopped service while replacing its executable.
# launchctl uses 113 for a missing service and 112 for a missing GUI domain.
stop_service() {
    local target="$1" result
    if /bin/launchctl print "$target" >/dev/null 2>&1; then
        if /bin/launchctl bootout "$target" >/dev/null 2>&1; then :
        else
            result=$?
            [[ "$result" -eq 113 || ( "$target" == gui/* && "$result" -eq 112 ) ]] || return "$result"
        fi
        if /bin/launchctl print "$target" >/dev/null 2>&1; then return 1
        else result=$?; fi
    else result=$?; fi
    [[ "$result" -eq 113 || ( "$target" == gui/* && "$result" -eq 112 ) ]]
}

[[ "$EUID" -eq 0 ]] || fail 'Administrator authorization is required.'
[[ "$#" -eq 1 || ( "$#" -eq 3 && "$2" == '--caller-uid' ) ]] || fail 'Usage: install.sh /absolute/path/Nightfall.app [--caller-uid UID]'
[[ "$1" == /* ]] || fail 'The source app path must be absolute.'
source_app="$1"
# The caller ID only controls restart ordering; it does not confer privileges.
# The invoking app or shell must already have obtained root privileges.
caller_uid=''
if [[ "$#" -eq 3 ]]; then
    valid_uid "$3" || fail 'Invalid caller user ID.'
    caller_uid="$((10#$3))"
elif valid_uid "${SUDO_UID:-}"; then caller_uid="$((10#$SUDO_UID))"; fi
[[ -d "$source_app" && ! -L "$source_app" ]] || fail 'The source app is missing or is a symbolic link.'

app='/Applications/Nightfall.app'
helper='/Library/PrivilegedHelperTools/com.nightfall.mac.daemon'
daemon_plist='/Library/LaunchDaemons/com.nightfall.mac.daemon.plist'
agent_plist='/Library/LaunchAgents/com.nightfall.mac.agent.plist'
state='/Library/Application Support/Nightfall'
daemon_label='com.nightfall.mac.daemon'
agent_label='com.nightfall.mac.agent'
stage=''
# Stopped jobs need recovery even if replacement of installed files never began.
changes_started=0
files_started=0
daemon_was_loaded=0
caller_was_loaded=0
old_app=0
old_helper=0
old_daemon_plist=0
old_agent_plist=0
new_app_installed=0
gui_uids=()
old_agent_uids=()

# /Applications can be writable by the administrator group. Keep launchd's root
# executable and job definitions in directories that disallow group/other writes.
for directory in /Library/PrivilegedHelperTools /Library/LaunchDaemons /Library/LaunchAgents '/Library/Application Support'; do
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

users="$(/usr/bin/dscl . -list /Users UniqueID | /usr/bin/awk '$2 >= 500 {print $2}' | /usr/bin/sort -n -u)" || fail 'Could not list signed-in users.'
# Network accounts can be absent from the local directory. Include users with
# running processes, then ask launchd which ones have a graphical login.
process_users="$(/bin/ps -axo uid= | /usr/bin/awk '$1 >= 500 {print $1}')" || fail 'Could not list user processes.'
users="$(printf '%s\n%s\n%s\n' "$users" "$process_users" "$caller_uid" | /usr/bin/sort -n -u)"
while IFS= read -r uid; do
    valid_uid "$uid" || continue
    if /bin/launchctl print "gui/$uid" >/dev/null 2>&1; then
        gui_uids+=("$uid")
        if /bin/launchctl print "gui/$uid/$agent_label" >/dev/null 2>&1; then
            old_agent_uids+=("$uid")
            if [[ "$uid" == "$caller_uid" ]]; then caller_was_loaded=1; fi
        else
            result=$?
            [[ "$result" -eq 112 || "$result" -eq 113 ]] || fail "Could not inspect Nightfall for user $uid (error $result)."
        fi
    else
        result=$?
        [[ "$result" -eq 112 ]] || fail "Could not inspect the login session for user $uid (error $result)."
    fi
done <<< "$users"
if /bin/launchctl print "system/$daemon_label" >/dev/null 2>&1; then daemon_was_loaded=1
else
    result=$?
    [[ "$result" -eq 113 ]] || fail "Could not inspect Nightfall's system service (error $result)."
fi

# Preserve the triggering exit status. Recover stopped jobs separately from
# replaced files; retain remaining backups when recovery is incomplete.
cleanup() {
    result=$?
    recovered=1
    trap - EXIT HUP INT TERM
    if [[ "$result" -ne 0 && "$changes_started" -eq 1 ]]; then
        printf 'Installation did not finish; restoring the previous installation.\n' >&2
        if [[ "$files_started" -eq 1 ]]; then
            # Never overwrite code beneath a replacement service that could not
            # be stopped. Keep the backups for explicit recovery instead.
            if stop_service "system/$daemon_label"; then
                for uid in ${gui_uids[@]+"${gui_uids[@]}"}; do
                    [[ "$uid" == "$caller_uid" ]] && continue
                    stop_service "gui/$uid/$agent_label" || recovered=0
                done
                if [[ "$new_app_installed" -eq 1 ]]; then /bin/rm -rf "$app" || recovered=0; fi
                /bin/rm -f "$helper" "$daemon_plist" "$agent_plist" || recovered=0
                if [[ "$old_app" -eq 1 ]]; then
                    # mv into an existing directory would nest the backup.
                    if [[ ! -e "$app" && ! -L "$app" ]]; then /bin/mv "$stage/previous.app" "$app" || recovered=0
                    else recovered=0; fi
                fi
                if [[ "$old_helper" -eq 1 ]]; then /bin/cp -p "$stage/previous-helper" "$helper" || recovered=0; fi
                if [[ "$old_daemon_plist" -eq 1 ]]; then /bin/cp -p "$stage/previous-daemon.plist" "$daemon_plist" || recovered=0; fi
                if [[ "$old_agent_plist" -eq 1 ]]; then /bin/cp -p "$stage/previous-agent.plist" "$agent_plist" || recovered=0; fi
            else recovered=0; fi
        fi
        if [[ "$recovered" -eq 1 ]]; then
            if [[ "$daemon_was_loaded" -eq 1 && -f "$daemon_plist" ]]; then
                /bin/launchctl print "system/$daemon_label" >/dev/null 2>&1 || /bin/launchctl bootstrap system "$daemon_plist" >/dev/null 2>&1 || recovered=0
            fi
            for uid in ${old_agent_uids[@]+"${old_agent_uids[@]}"}; do
                /bin/launchctl print "gui/$uid/$agent_label" >/dev/null 2>&1 || /bin/launchctl bootstrap "gui/$uid" "$agent_plist" >/dev/null 2>&1 || recovered=0
            done
        fi
    fi
    if [[ -n "$stage" && -d "$stage" ]]; then
        if [[ "$recovered" -eq 1 ]]; then /bin/rm -rf "$stage";
        else printf 'Recovery files were retained at: %s\n' "$stage" >&2; fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Inspect a protected copy rather than the user-writable source bundle. Ad hoc
# signature checks detect corruption, but do not establish publisher identity.
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
staged_helper="$staged_app/Contents/Library/LaunchServices/com.nightfall.mac.daemon"
[[ -f "$staged_helper" && -x "$staged_helper" ]] || fail 'The Nightfall service executable is missing.'
/usr/bin/codesign --verify --strict --test-requirement='=identifier "com.nightfall.mac.daemon"' "$staged_helper" || fail 'The service signature is invalid. Build the app again.'
/usr/sbin/chown -R root:wheel "$staged_app"
/bin/chmod -R u+rwX,go+rX,go-w "$staged_app"
/bin/chmod -R a-s "$staged_app"
/usr/bin/install -o root -g wheel -m 755 "$staged_helper" "$stage/new-helper"
/usr/bin/codesign --verify --strict "$stage/new-helper" || fail 'The standalone service signature is invalid.'

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

# Back up privileged files before stopping jobs. Move the old app only when
# replacement begins; the shared schedule directory stays in place throughout.
if [[ -e "$helper" ]]; then /bin/cp -p "$helper" "$stage/previous-helper"; old_helper=1; fi
if [[ -e "$daemon_plist" ]]; then /bin/cp -p "$daemon_plist" "$stage/previous-daemon.plist"; old_daemon_plist=1; fi
if [[ -e "$agent_plist" ]]; then /bin/cp -p "$agent_plist" "$stage/previous-agent.plist"; old_agent_plist=1; fi
changes_started=1
stop_service "system/$daemon_label" || fail 'Could not stop the previous system service. Existing installation files were preserved.'
for uid in ${gui_uids[@]+"${gui_uids[@]}"}; do
    [[ "$uid" == "$caller_uid" ]] && continue
    stop_service "gui/$uid/$agent_label" || fail "Could not stop Nightfall for user $uid. Existing installation files were preserved."
done
files_started=1
if [[ -e "$app" ]]; then /bin/mv "$app" "$stage/previous.app"; old_app=1; fi
/bin/mv "$staged_app" "$app"
new_app_installed=1
/usr/bin/install -o root -g wheel -m 755 "$stage/new-helper" "$helper"
/usr/bin/install -o root -g wheel -m 644 "$stage/new-daemon.plist" "$daemon_plist"
/usr/bin/install -o root -g wheel -m 644 "$stage/new-agent.plist" "$agent_plist"
/usr/bin/install -d -o root -g wheel -m 700 "$state"
/bin/launchctl bootstrap system "$daemon_plist"
for uid in ${gui_uids[@]+"${gui_uids[@]}"}; do
    if [[ "$uid" == "$caller_uid" && "$caller_was_loaded" -eq 1 ]]; then continue; fi
    if ! /bin/launchctl bootstrap "gui/$uid" "$agent_plist"; then
        printf 'Nightfall: the menu bar agent could not start for user ID %s; check Login Items or sign in again.\n' "$uid" >&2
    fi
done
changes_started=0
# Restarting the caller can terminate the app and its authorization script.
# Finish all persistent cleanup first, then request restart in one launchd call.
/bin/rm -rf "$stage"
stage=''
printf 'Nightfall is installed for all users. Existing schedule and cancellations were preserved.\n'
if [[ "$caller_was_loaded" -eq 1 ]]; then
    /bin/launchctl kickstart -k "gui/$caller_uid/$agent_label" || fail 'Installed, but the current menu bar app could not restart. Sign out and back in to reload it.'
fi
