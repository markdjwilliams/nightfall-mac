#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

[[ "$EUID" -eq 0 ]] || { printf 'Nightfall removal requires administrator authorization.\n' >&2; exit 1; }
[[ "$#" -eq 0 ]] || { printf 'Usage: uninstall.sh\n' >&2; exit 1; }

while IFS= read -r uid; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    if /bin/launchctl print "gui/$uid" >/dev/null 2>&1; then
        /bin/launchctl bootout "gui/$uid/com.nightfall.mac.agent" >/dev/null 2>&1 || true
    fi
done < <(/usr/bin/dscl . -list /Users UniqueID | /usr/bin/awk '$2 >= 500 {print $2}' | /usr/bin/sort -n -u)
/bin/launchctl bootout system/com.nightfall.mac.daemon >/dev/null 2>&1 || true
/bin/rm -f /Library/LaunchAgents/com.nightfall.mac.agent.plist \
    /Library/LaunchDaemons/com.nightfall.mac.daemon.plist \
    /Library/PrivilegedHelperTools/com.nightfall.mac.daemon \
    /var/run/com.nightfall.mac.sock
/bin/rm -rf '/Library/Application Support/Nightfall' /Applications/Nightfall.app
printf 'Nightfall, its system services, and its saved schedule have been removed.\n'
