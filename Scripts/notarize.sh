#!/bin/bash
# Notarises and staples a Developer ID signed Lull package:
#
#   Scripts/notarize.sh build/pkg/Lull-<version>-<build>.pkg
#
# Needs NOTARY_PROFILE (environment or Config/Signing.local.xcconfig): a
# notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <profile> --apple-id <Apple ID> --team-id <TEAMID>
# so no password appears on the command line or in this repository.
#
# Why notarise packages Jamf installs anyway: Jamf policies don't need it
# (installs from Jamf aren't quarantined). A notarised, stapled package can
# also be opened by double-clicking a download on a test Mac, and Gatekeeper
# can check it offline because the ticket is stapled to it.
#
# This uploads the package to Apple's notary service and waits for the result,
# usually a few minutes. Apple's log is saved next to the package
# (<pkg>.notary-log.json): read it for warnings even when the package is accepted.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/Scripts/lib/signing-config.sh"
die() { echo "notarize: $*" >&2; exit 1; }

PKG="${1:-}"
[[ -n "$PKG" && -f "$PKG" ]] || die "usage: Scripts/notarize.sh <package.pkg>"
PROFILE=$(signing_setting NOTARY_PROFILE)
[[ -n "$PROFILE" ]] || die "NOTARY_PROFILE isn't set (environment or Config/Signing.local.xcconfig)"
pkgutil --check-signature "$PKG" | grep -q "Developer ID Installer: " \
    || die "$PKG isn't signed with a Developer ID Installer certificate"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "==> Submitting $(basename "$PKG") to Apple's notary service (profile '$PROFILE'); this usually takes a few minutes"
# notarytool exits 0 when the submission finishes, even if Apple rejects it,
# so read the status from its output.
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait --output-format plist > "$WORK/result.plist" \
    || { cat "$WORK/result.plist" >&2 2>/dev/null || true; die "submission failed"; }
ID=$(plutil -extract id raw "$WORK/result.plist" 2>/dev/null || true)
STATUS=$(plutil -extract status raw "$WORK/result.plist" 2>/dev/null || true)
[[ -n "$ID" ]] || { cat "$WORK/result.plist" >&2; die "no submission id in notarytool's output"; }

LOG="$PKG.notary-log.json"
xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$LOG" >/dev/null 2>&1 \
    || echo "warning: couldn't fetch the notary log for $ID" >&2
[[ "$STATUS" == "Accepted" ]] || { cat "$LOG" >&2 2>/dev/null || true; die "Apple's status for $ID is '${STATUS:-unknown}' (log: $LOG)"; }
echo "    accepted ($ID)"

echo "==> Stapling the ticket"
xcrun stapler staple "$PKG" >/dev/null
xcrun stapler validate "$PKG" >/dev/null || die "stapled ticket doesn't validate"
# What Gatekeeper decides for a downloaded copy.
spctl --assess --type install -vv "$PKG" 2>&1 | sed 's/^/    /'
spctl --assess --type install "$PKG" 2>/dev/null || die "Gatekeeper rejects $PKG"
echo "notarised and stapled $PKG"
