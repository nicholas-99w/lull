#!/bin/bash
# Installs a Lull build on a TEST MAC for development without building a
# package. For anything closer to production use Scripts/make-pkg.sh.
#
#   sudo Scripts/dev-install.sh --i-am-on-a-test-mac [--products DIR] [--dev-config PLIST]
#        [--portal-url URL --enrolment-secret SECRET]
#
# --portal-url (Debug builds only) points lulld at a test portal, http allowed,
# e.g. http://192.0.2.10:8080 (a lull-portal test server); --enrolment-secret writes
# the portal's enrolment secret to /var/db/lull/portal-enroll.json (0600).
#
# DEV SAFETY (Docs/DEVELOPMENT.md): this makes the Mac lock during downtime. Never run it
# on a daily-driver Mac. Before running: enable Remote Login (SSH) and keep a
# second machine ready. Recovery during a lock:
#   sudo touch /var/db/lull/DISABLE              (Debug builds: lock screen quits)
#   sudo ./dev-uninstall.sh                      (any build: removes Lull)
# Booting out only the daemon does NOT end a lock: the lock screen stays up
# until the window ends if the daemon disappears (never trap, never trivial).
set -euo pipefail

DAEMON_LABEL="au.com.nickit.lulld"
AGENT_LABEL="au.com.nickit.lull"
PREF_DOMAIN="au.com.nickit.lull"
INSTALL_ROOT="/Library/Application Support/Lull"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PRODUCTS="$REPO/build/DerivedData/Build/Products/Debug"
DEV_CONFIG=""
PORTAL_URL=""
ENROLMENT_SECRET=""
CONFIRMED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --i-am-on-a-test-mac) CONFIRMED=1 ;;
        --products) PRODUCTS="$2"; shift ;;
        --dev-config) DEV_CONFIG="$2"; shift ;;
        --portal-url) PORTAL_URL="$2"; shift ;;
        --enrolment-secret) ENROLMENT_SECRET="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

die() { echo "dev-install: $*" >&2; exit 1; }
[[ $CONFIRMED -eq 1 ]] || die "refusing to run without --i-am-on-a-test-mac (this software locks the screen)"
[[ $EUID -eq 0 ]] || die "run with sudo"
for f in lulld lullctl Lull.app; do [[ -e "$PRODUCTS/$f" ]] || die "missing $PRODUCTS/$f (build first, or pass --products)"; done
TEMPLATES="$REPO/Resources"
[[ -f "$TEMPLATES/LaunchDaemon.plist.template" ]] || TEMPLATES="$HERE"   # dev bundle layout
[[ -f "$TEMPLATES/LaunchDaemon.plist.template" ]] || die "plist templates not found"

if ! systemsetup -getremotelogin 2>/dev/null | grep -qi ": On"; then
    echo "WARNING: Remote Login (SSH) appears to be OFF. You may not be able to recover a locked Mac remotely." >&2
    read -r -p "Continue anyway? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
fi

# Before touching the existing install, so a bad secret can't leave Lull stopped.
if [[ -n "$ENROLMENT_SECRET" ]]; then
    ENROL="$HERE/portal-enrol.sh"
    [[ -f "$ENROL" ]] || ENROL="$REPO/Scripts/jamf/portal-enrol.sh"
    echo "==> Writing the portal enrolment secret"
    /bin/bash "$ENROL" - - - "$ENROLMENT_SECRET" || die "enrolment secret not written; nothing else changed"
fi

DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="/Library/LaunchAgents/$AGENT_LABEL.plist"
CONSOLE_UID=$(stat -f %u /dev/console)

echo "==> Stopping any existing Lull"
if [[ "$CONSOLE_UID" -ne 0 ]]; then launchctl bootout "gui/$CONSOLE_UID/$AGENT_LABEL" 2>/dev/null || true; fi
launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true

echo "==> Installing to $INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/Branding" /var/log/lull /usr/local/bin
rm -rf "$INSTALL_ROOT/Lull.app"
ditto "$PRODUCTS/Lull.app" "$INSTALL_ROOT/Lull.app"
install -m 755 "$PRODUCTS/lulld" "$INSTALL_ROOT/bin/lulld"
install -m 755 "$PRODUCTS/lullctl" "$INSTALL_ROOT/bin/lullctl"
UNINSTALL="$HERE/uninstall.sh"
[[ -f "$UNINSTALL" ]] && install -m 755 "$UNINSTALL" "$INSTALL_ROOT/bin/uninstall.sh"
# Only where a non-root user can't swap it (see pkg-scripts/postinstall).
if [[ "$(stat -f '%u' /usr/local/bin)" == "0" && -z "$(find /usr/local/bin -maxdepth 0 -perm +022)" ]]; then
    ln -sf "$INSTALL_ROOT/bin/lullctl" /usr/local/bin/lullctl
fi
xattr -dr com.apple.quarantine "$INSTALL_ROOT" 2>/dev/null || true
chown -R root:wheel "$INSTALL_ROOT"
chmod 755 "$INSTALL_ROOT" "$INSTALL_ROOT/bin" "$INSTALL_ROOT/Branding" /var/log/lull

render() {
    sed -e "s|@DAEMON_LABEL@|$DAEMON_LABEL|g" -e "s|@AGENT_LABEL@|$AGENT_LABEL|g" -e "s|@INSTALL_ROOT@|$INSTALL_ROOT|g" "$1" > "$2"
    chown root:wheel "$2"
    chmod 644 "$2"
    plutil -lint "$2" >/dev/null
}
render "$TEMPLATES/LaunchDaemon.plist.template" "$DAEMON_PLIST"
render "$TEMPLATES/LaunchAgent.plist.template" "$AGENT_PLIST"

if [[ -n "$PORTAL_URL" ]]; then
    # A Release lulld rejects this flag (usage error, then launchd retries), so check first.
    "$INSTALL_ROOT/bin/lulld" --version | grep -q DEBUG || die "--portal-url needs a Debug build"
    echo "==> lulld will use the test portal $PORTAL_URL"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments: string --portal-url" -c "Add :ProgramArguments: string $PORTAL_URL" "$DAEMON_PLIST"
    plutil -lint "$DAEMON_PLIST" >/dev/null
    curl -fsS -m 5 "${PORTAL_URL%/}/healthz" >/dev/null 2>&1 \
        || echo "WARNING: ${PORTAL_URL%/}/healthz not reachable from this Mac (firewall? wrong IP?). lulld will keep retrying." >&2
fi

if [[ -n "$DEV_CONFIG" ]]; then
    echo "==> Installing Debug dev config (ignored by Release builds)"
    mkdir -p /var/root/Library/Preferences
    install -m 644 -o root -g wheel "$DEV_CONFIG" "/var/root/Library/Preferences/$PREF_DOMAIN.dev.plist"
fi

echo "==> Starting lulld"
launchctl bootstrap system "$DAEMON_PLIST"
if [[ "$CONSOLE_UID" -ne 0 ]]; then
    echo "==> Starting the agent for the logged-in user (uid $CONSOLE_UID)"
    launchctl bootstrap "gui/$CONSOLE_UID" "$AGENT_PLIST" || echo "   (agent will start at next login)"
fi

sleep 2
echo
"$INSTALL_ROOT/bin/lullctl" status || true
cat <<MSG

Installed. Logs: /var/log/lull/lulld.log  |  log stream --predicate 'subsystem == "au.com.nickit.lull"'
Recovery (from SSH): sudo touch /var/db/lull/DISABLE (Debug)  |  sudo $REPO/Scripts/dev-uninstall.sh
MSG
