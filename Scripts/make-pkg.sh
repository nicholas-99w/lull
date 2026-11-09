#!/bin/bash
# Builds the Lull installer package from already-built products.
#
#   Scripts/make-pkg.sh [--config Release|Debug] [--products DIR] [--out DIR] [--notarize]
#
# Release (default) is what you deploy with a Jamf policy. A Debug package
# contains the DEV SAFETY escape hatches and is named *-DEBUG.pkg; use it only
# on test Macs.
#
# Signing: the package is unsigned by default, which is fine for Jamf
# *policies*. Set INSTALLER_IDENTITY="Developer ID Installer: Name (TEAMID)", in
# the environment or Config/Signing.local.xcconfig, to sign it with productsign.
# A signed package needs Developer ID signed binaries (Scripts/check-signing.sh):
# notarisation would reject anything else. --notarize then has Scripts/notarize.sh
# notarise and staple a signed package; an unsigned one is skipped.
set -euo pipefail

DAEMON_LABEL="au.com.nickit.lulld"
AGENT_LABEL="au.com.nickit.lull"
PKG_ID="au.com.nickit.lull.pkg"
INSTALL_ROOT="/Library/Application Support/Lull"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/Scripts/lib/signing-config.sh"
CONFIG=Release
PRODUCTS=""
OUT="$REPO/build/pkg"
NOTARIZE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="$2"; shift ;;
        --products) PRODUCTS="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --notarize) NOTARIZE=1 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done
PRODUCTS="${PRODUCTS:-$REPO/build/DerivedData/Build/Products/$CONFIG}"
die() { echo "make-pkg: $*" >&2; exit 1; }
for f in Lull.app lulld lullctl; do [[ -e "$PRODUCTS/$f" ]] || die "missing $PRODUCTS/$f (run 'make release' or 'make build')"; done

if [[ "$CONFIG" == "Release" ]]; then
    # Never ship a Release package that contains Debug escape hatches.
    "$REPO/Scripts/check-release-hatches.sh" "$PRODUCTS" || die "Release products contain Debug escape hatches"
    SIGNING=$("$REPO/Scripts/check-signing.sh" "$PRODUCTS" | tail -1) || die "Release products aren't signed consistently"
    SUFFIX=""
    INSTALLER_IDENTITY=$(signing_setting INSTALLER_IDENTITY)
    if [[ -n "$INSTALLER_IDENTITY" && "$SIGNING" == adhoc ]]; then
        die "INSTALLER_IDENTITY is set but the binaries are ad-hoc signed; set APPLE_TEAM_ID and SIGNING_IDENTITY and rebuild"
    fi
    if [[ -z "$INSTALLER_IDENTITY" && "$SIGNING" != adhoc ]]; then
        echo "note: binaries are Developer ID signed but INSTALLER_IDENTITY is empty, so the package will be unsigned" >&2
    fi
else
    echo "WARNING: building a DEBUG package (escape hatches included). Test Macs only." >&2
    SUFFIX="-DEBUG"
    # Debug binaries are ad-hoc and carry get-task-allow, so the package is
    # never signed or notarised.
    INSTALLER_IDENTITY=""
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PRODUCTS/Lull.app/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PRODUCTS/Lull.app/Contents/Info.plist")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"

echo "==> Staging $VERSION ($BUILD) $CONFIG"
mkdir -p "$ROOT$INSTALL_ROOT/bin" "$ROOT$INSTALL_ROOT/Branding" "$ROOT/Library/LaunchDaemons" "$ROOT/Library/LaunchAgents"
ditto "$PRODUCTS/Lull.app" "$ROOT$INSTALL_ROOT/Lull.app"
install -m 755 "$PRODUCTS/lulld" "$ROOT$INSTALL_ROOT/bin/lulld"
install -m 755 "$PRODUCTS/lullctl" "$ROOT$INSTALL_ROOT/bin/lullctl"
install -m 755 "$REPO/Scripts/uninstall.sh" "$ROOT$INSTALL_ROOT/bin/uninstall.sh"
render() {
    sed -e "s|@DAEMON_LABEL@|$DAEMON_LABEL|g" -e "s|@AGENT_LABEL@|$AGENT_LABEL|g" -e "s|@INSTALL_ROOT@|$INSTALL_ROOT|g" "$1" > "$2"
    chmod 644 "$2"
    plutil -lint "$2" >/dev/null
}
render "$REPO/Resources/LaunchDaemon.plist.template" "$ROOT/Library/LaunchDaemons/$DAEMON_LABEL.plist"
render "$REPO/Resources/LaunchAgent.plist.template" "$ROOT/Library/LaunchAgents/$AGENT_LABEL.plist"
# Drop extended attributes (e.g. quarantine on downloaded products) so they
# aren't carried into the payload. com.apple.provenance can't be removed and
# shows up as ._ AppleDouble entries in the payload listing; Installer applies
# those as xattrs, not files, and it isn't quarantine, so it's harmless.
# Signatures are embedded in the binaries, not stored in xattrs.
xattr -cr "$ROOT" 2>/dev/null || true
# Signatures must survive staging, or the XPC cdhash pin would fail.
codesign --verify --strict "$ROOT$INSTALL_ROOT/Lull.app" || die "Lull.app signature invalid after staging"
codesign --verify --strict "$ROOT$INSTALL_ROOT/bin/lulld" || die "lulld signature invalid after staging"

# Component plist: never relocate Lull.app. By default Installer updates an
# app with the same bundle id wherever it finds one (e.g. a stray copy in
# ~/Downloads) instead of installing to INSTALL_ROOT.
pkgbuild --analyze --root "$ROOT" "$WORK/component.plist" >/dev/null
i=0
while /usr/libexec/PlistBuddy -c "Print :$i" "$WORK/component.plist" >/dev/null 2>&1; do
    /usr/libexec/PlistBuddy -c "Delete :$i:BundleIsRelocatable" "$WORK/component.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" "$WORK/component.plist"
    # Always install our build, even over a "newer" stray copy (e.g. a rollback).
    /usr/libexec/PlistBuddy -c "Set :$i:BundleIsVersionChecked false" "$WORK/component.plist"
    i=$((i + 1))
done

mkdir -p "$OUT"
PKG="$OUT/Lull-$VERSION-$BUILD$SUFFIX.pkg"
UNSIGNED="$WORK/unsigned.pkg"
echo "==> Building package"
pkgbuild --root "$ROOT" --component-plist "$WORK/component.plist" --scripts "$REPO/Scripts/pkg-scripts" \
    --identifier "$PKG_ID" --version "$VERSION.$BUILD" --install-location / --ownership recommended \
    "$UNSIGNED" >/dev/null

rm -f "$PKG"
if [[ -n "$INSTALLER_IDENTITY" ]]; then
    echo "==> Signing with '$INSTALLER_IDENTITY'"
    # A secure timestamp is required for notarisation.
    productsign --sign "$INSTALLER_IDENTITY" --timestamp "$UNSIGNED" "$PKG"
    # pkgutil exits 0 even for some untrusted signatures, so check its status text.
    pkgutil --check-signature "$PKG" | grep -q "Status: signed by a developer certificate issued by Apple for distribution" \
        || { pkgutil --check-signature "$PKG" >&2 || true; die "package signature isn't trusted"; }
else
    cp "$UNSIGNED" "$PKG"
    echo "note: package is unsigned (fine for Jamf policies; set INSTALLER_IDENTITY to sign)"
fi

echo "==> Contents"
pkgutil --payload-files "$PKG" | grep -E "Lull.app$|bin/|LaunchDaemons/|LaunchAgents/" | sed 's/^/   /'
echo "wrote $PKG"

if [[ $NOTARIZE -eq 1 ]]; then
    if [[ -n "$INSTALLER_IDENTITY" ]]; then
        "$REPO/Scripts/notarize.sh" "$PKG"
    else
        echo "note: package is unsigned, so it isn't notarised"
    fi
fi
