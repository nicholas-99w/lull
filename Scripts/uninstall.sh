#!/bin/bash
# Removes Lull from this Mac. Installed with the package at
#   /Library/Application Support/Lull/bin/uninstall.sh
# so a Jamf policy can run it ("Files and Processes > Execute Command"):
#   "/Library/Application Support/Lull/bin/uninstall.sh" --purge
#
#   --purge   also delete state (/var/db/lull, incl. override.json) and logs
#
# Remove the Lull configuration profile in Jamf as well, or a reinstall will
# start enforcing again. Exit status: 0 = removed (or wasn't installed).
set -uo pipefail

DAEMON_LABEL="au.com.nickit.lulld"
AGENT_LABEL="au.com.nickit.lull"
PREF_DOMAIN="au.com.nickit.lull"
PKG_ID="au.com.nickit.lull.pkg"
INSTALL_ROOT="/Library/Application Support/Lull"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1
[[ $EUID -eq 0 ]] || { echo "uninstall: run as root" >&2; exit 1; }

# Stop the daemon first: it supervises the agents and would re-bootstrap them.
launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null && echo "stopped lulld"

# Agent in every GUI session (fast user switching), not just the console user.
for uid in $(ps -axo uid=,comm= | awk '$2 ~ /loginwindow$/ {print $1}' | sort -u); do
    [[ "$uid" -eq 0 ]] && continue
    launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null && echo "stopped agent for uid $uid"
done
pkill -x Lull 2>/dev/null

rm -f "/Library/LaunchDaemons/$DAEMON_LABEL.plist" "/Library/LaunchAgents/$AGENT_LABEL.plist"
# This script lives inside INSTALL_ROOT; bash has already read it, so removing is safe.
rm -rf "$INSTALL_ROOT"
[[ -L /usr/local/bin/lullctl ]] && rm -f /usr/local/bin/lullctl
rm -f "/var/root/Library/Preferences/$PREF_DOMAIN.dev.plist"   # Debug dev config, if any
pkgutil --forget "$PKG_ID" >/dev/null 2>&1 && echo "forgot package receipt"

if [[ $PURGE -eq 1 ]]; then
    rm -rf /var/db/lull /var/log/lull
    echo "purged /var/db/lull and /var/log/lull"
else
    rm -f /var/db/lull/DISABLE
    echo "kept /var/db/lull (state) and /var/log/lull (logs); use --purge to remove"
fi
echo "Lull removed."
exit 0
