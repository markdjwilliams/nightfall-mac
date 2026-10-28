#!/bin/bash
# Requires administrator authorization. Remove fixed Nightfall paths, including
# shared schedule state, only after launchd confirms the root service is absent.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

fail() { printf 'Nightfall removal: %s\n' "$*" >&2; exit 1; }

valid_uid() {
    [[ "$1" =~ ^[0-9]{3,10}$ ]] && (( 10#$1 >= 500 && 10#$1 <= 4294967294 ))
}

# A missing job (or a user signing out) is acceptable; other inspection/stop
# failures abort before deleting files. Check absence again after bootout.
stop_service() {
    local target="$1" result
    if /bin/launchctl print "$target" >/dev/null 2>&1; then
        if /bin/launchctl bootout "$target" >/dev/null 2>&1; then :
        else
            result=$?
            [[ "$result" -eq 113 || ( "$target" == gui/* && "$result" -eq 112 ) ]] || fail "Could not stop $target. Nothing has been deleted."
        fi
        if /bin/launchctl print "$target" >/dev/null 2>&1; then
            fail "Service is still registered: $target. Nothing has been deleted."
        else
            result=$?
        fi
    else
        result=$?
    fi
    # Missing service = 113; a GUI domain that logged out in the meantime = 112.
    [[ "$result" -eq 113 || ( "$target" == gui/* && "$result" -eq 112 ) ]] || fail "Could not verify that $target is stopped (error $result). Nothing has been deleted."
}

main() {
    [[ "$EUID" -eq 0 ]] || fail 'Administrator authorization is required.'
    local caller_uid='' uid result caller_loaded=0 users process_users
    local gui_uids=()
    if [[ "$#" -eq 0 ]]; then
        if valid_uid "${SUDO_UID:-}"; then caller_uid="$((10#$SUDO_UID))"; fi
    elif [[ "$#" -eq 2 && "$1" == '--caller-uid' ]] && valid_uid "$2"; then
        caller_uid="$((10#$2))"
    else
        fail 'Usage: uninstall.sh [--caller-uid UID]'
    fi

    # Process UIDs include network accounts missing from the local directory;
    # launchd then distinguishes graphical logins from background/SSH sessions.
    users="$(/usr/bin/dscl . -list /Users UniqueID | /usr/bin/awk '$2 >= 500 {print $2}' | /usr/bin/sort -n -u)" || fail 'Could not list signed-in users.'
    process_users="$(/bin/ps -axo uid= | /usr/bin/awk '$1 >= 500 {print $1}')" || fail 'Could not list user processes.'
    users="$(printf '%s\n%s\n' "$users" "$process_users" | /usr/bin/sort -n -u)"
    while IFS= read -r uid; do
        valid_uid "$uid" || continue
        if /bin/launchctl print "gui/$uid" >/dev/null 2>&1; then
            gui_uids+=("$uid")
        else
            result=$?
            [[ "$result" -eq 112 ]] || fail "Could not inspect the login session for user $uid (error $result)."
        fi
    done <<< "$users"

    # Inspect the caller separately so its agent can remain until cleanup ends.
    if [[ -n "$caller_uid" ]]; then
        if /bin/launchctl print "gui/$caller_uid/com.nightfall.mac.agent" >/dev/null 2>&1; then
            caller_loaded=1
        else
            result=$?
            [[ "$result" -eq 112 || "$result" -eq 113 ]] || fail "Could not inspect Nightfall's menu bar app (error $result)."
        fi
    fi

    # Stop and verify the root service before deleting its state or socket.
    stop_service 'system/com.nightfall.mac.daemon'
    for uid in ${gui_uids[@]+"${gui_uids[@]}"}; do
        [[ "$uid" == "$caller_uid" ]] && continue
        stop_service "gui/$uid/com.nightfall.mac.agent"
    done

    # Deletion targets are fixed; no caller-supplied path is passed to rm.
    /bin/rm -f /Library/LaunchAgents/com.nightfall.mac.agent.plist \
        /Library/LaunchDaemons/com.nightfall.mac.daemon.plist \
        /Library/PrivilegedHelperTools/com.nightfall.mac.daemon \
        /var/run/com.nightfall.mac.sock
    /bin/rm -rf '/Library/Application Support/Nightfall' /Applications/Nightfall.app

    # bootout may also terminate this script. All persistent cleanup is complete
    # before stopping the caller's agent, the final necessary operation.
    if [[ "$caller_loaded" -eq 1 ]]; then
        if /bin/launchctl bootout "gui/$caller_uid/com.nightfall.mac.agent" >/dev/null 2>&1; then :
        else
            result=$?
            [[ "$result" -eq 112 || "$result" -eq 113 ]] || fail 'Files were removed, but the current menu bar app could not be stopped. Sign out to close it.'
        fi
    fi
    printf 'Nightfall, its system services, and its saved schedule have been removed.\n'
}

# Define the entire procedure before it deletes its own bundle, so completion
# does not depend on reading further commands from this script's file.
main "$@"
