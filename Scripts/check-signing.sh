#!/bin/bash
# Checks that Lull.app, lulld and lullctl are all signed the same way and
# signed properly:
#
#   Scripts/check-signing.sh [PRODUCTS_DIR]     (default: the Release build)
#
# With a Team ID configured (APPLE_TEAM_ID in the environment or
# Config/Signing.local.xcconfig), every product must have a Developer ID
# Application signature from that team, with a secure timestamp, the hardened
# runtime, the expected identifier and no get-task-allow entitlement. Those
# are notarisation's requirements, and this check fails in seconds instead of
# after an upload.
# Without a Team ID, every product must be ad-hoc. Either way, none may have
# the get-task-allow entitlement.
#
# Why mixed signing is refused: the daemon and lock screen require each
# other's Team ID if they have one themselves (CodeSigningRequirement). A
# Developer ID daemon refuses an ad-hoc lock screen, so no lock screen would
# appear.
#
# Prints "developer-id <TEAM>" or "adhoc" on the last line when it passes.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/Scripts/lib/signing-config.sh"
PRODUCTS="${1:-$REPO/build/DerivedData/Build/Products/Release}"
PREFIX="au.com.nickit"
TEAM=$(signing_setting APPLE_TEAM_ID)

fail=0
problem() { echo "check-signing: $*" >&2; fail=1; }

check() {
    local path="$1" ident="$2" info
    [[ -e "$path" ]] || { problem "missing $path"; return; }
    codesign --verify --strict "$path" 2>/dev/null || { problem "$(basename "$path"): signature invalid"; return; }
    info=$(codesign -dvv "$path" 2>&1)
    grep -qx "Identifier=$ident" <<<"$info" || problem "$(basename "$path"): identifier isn't $ident"
    # Never in a Release build, however it's signed (Config/Signing.xcconfig).
    if codesign -d --entitlements - "$path" 2>/dev/null | grep -q "get-task-allow"; then
        problem "$(basename "$path"): has get-task-allow (a Debug build, or CODE_SIGN_INJECT_BASE_ENTITLEMENTS isn't NO)"
    fi
    if [[ -z "$TEAM" ]]; then
        grep -qx "Signature=adhoc" <<<"$info" \
            || problem "$(basename "$path"): signed with an identity, but no APPLE_TEAM_ID is configured"
        return
    fi
    grep -qx "TeamIdentifier=$TEAM" <<<"$info" || problem "$(basename "$path"): Team ID isn't $TEAM"
    grep -q "^Authority=Developer ID Application: " <<<"$info" || problem "$(basename "$path"): not signed with Developer ID Application"
    # A secure timestamp shows as "Timestamp=", a local clock as "Signed Time=".
    grep -q "^Timestamp=" <<<"$info" || problem "$(basename "$path"): no secure timestamp"
    grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime" <<<"$info" || problem "$(basename "$path"): hardened runtime not enabled"
}

check "$PRODUCTS/Lull.app" "$PREFIX.lull"
check "$PRODUCTS/lulld" "$PREFIX.lulld"
check "$PRODUCTS/lullctl" "$PREFIX.lullctl"

[[ $fail -eq 0 ]] || { echo "check-signing: FAILED for $PRODUCTS" >&2; exit 1; }
if [[ -n "$TEAM" ]]; then echo "developer-id $TEAM"; else echo "adhoc"; fi
