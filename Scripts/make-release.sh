#!/bin/bash
# Builds everything for a GitHub Release into build/release/<version>-<build>/:
#   Lull-<version>-<build>.pkg          the installer package (Release build)
#   Lull-<version>-<build>-jamf-kit.zip profiles, Jamf schema, extension
#                                       attributes, uninstaller
#   SHA256SUMS.txt                      checksums for both
#   RELEASE_NOTES.md                    the top section of Docs/CHANGELOG.md
#
#   Scripts/make-release.sh             # runs `make dist` first
#   Scripts/make-release.sh --no-build  # use the existing build/pkg package
#
# Then create a GitHub Release (tag v<version>), paste RELEASE_NOTES.md
# and attach the .pkg, the .zip and SHA256SUMS.txt. With the GitHub CLI:
#   gh release create v<version> build/release/<dir>/{*.pkg,*.zip,SHA256SUMS.txt} \
#       --notes-file build/release/<dir>/RELEASE_NOTES.md
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

die() { echo "make-release: $*" >&2; exit 1; }
NO_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=1 ;;
        *) die "unknown argument '$arg' (usage: Scripts/make-release.sh [--no-build])" ;;
    esac
done

# Version and build come from project.yml, so the CHANGELOG check below can
# fail in seconds, before a multi-minute build.
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
[[ -n "$VERSION" && -n "$BUILD" ]] || die "couldn't read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"

# lulld and lullctl report LullConstants.version (they have no Info.plist), so
# it must match, or Macs report the previous version.
CONST=$(sed -n 's/^ *public static let version = "\(.*\)"$/\1/p' Sources/LullCore/Constants.swift)
[[ "$CONST" == "$VERSION" ]] || die "LullConstants.version is '$CONST' but project.yml says $VERSION; update Sources/LullCore/Constants.swift"

# The release notes come from the top CHANGELOG section; it must be exactly
# "## <version> build <build>…" (so build 3 doesn't match "build 30").
TOP=$(grep -m1 '^## ' Docs/CHANGELOG.md || true)
VERSION_RE=${VERSION//./\\.}
[[ "$TOP" =~ ^##\ ${VERSION_RE}\ build\ ${BUILD}([^0-9]|$) ]] \
    || die "the top section of Docs/CHANGELOG.md ('$TOP') isn't for $VERSION build $BUILD; add '## $VERSION build $BUILD: …' first"

[[ $NO_BUILD -eq 1 ]] || make dist

INFO="build/DerivedData/Build/Products/Release/Lull.app/Contents/Info.plist"
BUILT="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO")-$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INFO")"
[[ "$BUILT" == "$VERSION-$BUILD" ]] || die "the built app is $BUILT but project.yml says $VERSION-$BUILD; run without --no-build"
NAME="Lull-$VERSION-$BUILD"
PKG="build/pkg/$NAME.pkg"
[[ -f "$PKG" ]] || die "$PKG not found (run without --no-build)"

# --no-build reuses an existing package: refuse it if anything it or the kit is
# made from changed afterwards, so binaries and kit can't come from different
# sources. (Modification times only: a file restored with an older timestamp
# isn't noticed. When in doubt, run without --no-build.)
if [[ $NO_BUILD -eq 1 ]]; then
    newer=$(find Sources Config Resources Scripts project.yml Package.swift Makefile -type f -not -name ".*" -newer "$PKG" -print -quit)
    [[ -z "$newer" ]] || die "$newer changed after $PKG was built; run without --no-build"
fi

OUT="build/release/$VERSION-$BUILD"
rm -rf "$OUT" && mkdir -p "$OUT"
cp "$PKG" "$OUT/"

# Jamf kit: everything an admin needs besides the package, no source required.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
KIT="$WORK/$NAME-jamf-kit"
mkdir -p "$KIT/profiles" "$KIT/extension-attributes" "$KIT/scripts"
cp Config/au.com.nickit.lull.mobileconfig "$KIT/profiles/"
# Login items profile. A Developer ID signed build gets the Team ID variant;
# its Team ID comes from the built app's signature, not from settings, so the
# profile always matches what's in the package. A build without a Developer ID
# has no Team ID, so it gets the identifier-only profile instead.
TEAM_ID=$(codesign -dvv build/DerivedData/Build/Products/Release/Lull.app 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$TEAM_ID" == "not set" ]] && TEAM_ID=""
TEAM_KIT_LINE=""
if [[ -n "$TEAM_ID" ]]; then
    sed "s/@TEAM_ID@/$TEAM_ID/g" Config/servicemanagement-teamid.mobileconfig.template > "$KIT/profiles/servicemanagement-teamid.mobileconfig"
    plutil -lint "$KIT/profiles/servicemanagement-teamid.mobileconfig" >/dev/null || die "Team ID profile isn't a valid plist"
    TEAM_KIT_LINE="  profiles/servicemanagement-teamid.mobileconfig   upload first: stops Lull being turned off in Login Items
                                   (requires Team ID $TEAM_ID, which this build is signed with)
"
else
    cp Config/servicemanagement.mobileconfig "$KIT/profiles/"
fi
cp Config/jamf-custom-schema.json "$KIT/"
cp Scripts/jamf/ea-status.sh Scripts/jamf/ea-time-integrity.sh "$KIT/extension-attributes/"
cp Scripts/uninstall.sh "$KIT/"
cp Scripts/jamf/portal-enrol.sh "$KIT/scripts/"
cat > "$KIT/README.txt" <<KITEOF
Lull $VERSION ($BUILD): Jamf kit

  jamf-custom-schema.json          Application & Custom Settings > Custom Schema
                                   (preference domain: au.com.nickit.lull)
${TEAM_KIT_LINE:-"  profiles/servicemanagement.mobileconfig   upload first: stops Lull being turned off in Login Items
"}  profiles/au.com.nickit.lull.mobileconfig  example settings profile with every setting (edit before use)
  extension-attributes/*.sh        Extension attributes: "Lull Status", "Lull Time Integrity"
  scripts/portal-enrol.sh          Optional parent portal: policy script, parameter 4 = enrolment secret
                                   (in the package policy, set its priority to Before)
  uninstall.sh                     also installed on each Mac at
                                   /Library/Application Support/Lull/bin/uninstall.sh

Deployment guide: Docs/DEPLOYMENT.md in the Lull repository.
KITEOF
(cd "$WORK" && COPYFILE_DISABLE=1 zip -qrX "$REPO/$OUT/$NAME-jamf-kit.zip" "$(basename "$KIT")")

(cd "$OUT" && shasum -a 256 "$NAME.pkg" "$NAME-jamf-kit.zip" > SHA256SUMS.txt)

# Release notes: the newest CHANGELOG section (between the first two "## " headings).
awk '/^## /{n++} n==1' Docs/CHANGELOG.md > "$OUT/RELEASE_NOTES.md"
cat >> "$OUT/RELEASE_NOTES.md" <<NOTES

### Downloads

- **$NAME.pkg**: the installer. Deploy it with a Jamf policy.
- **$NAME-jamf-kit.zip**: Jamf custom schema, profiles, extension attributes and uninstaller.
- **SHA256SUMS.txt**: check with \`shasum -a 256 -c SHA256SUMS.txt\`.

NOTES
# Say how the package is signed, rather than assuming. pkgutil exits non-zero
# for a signature it doesn't trust (expired, untrusted), so read its output
# rather than its exit status.
SIGCHECK=$(pkgutil --check-signature "$OUT/$NAME.pkg" 2>&1 || true)
if grep -q "Status: no signature" <<<"$SIGCHECK"; then
    cat >> "$OUT/RELEASE_NOTES.md" <<NOTES
The package is not signed with an Apple Developer ID. Jamf policies install it
without any extra steps.
NOTES
else
    SIGNER=$(awk '/^ *1\. /{sub(/^ *1\. /,""); print; exit}' <<<"$SIGCHECK")
    STATUS=$(awk -F': ' '/Status:/{print $2; exit}' <<<"$SIGCHECK")
    echo "The package is signed by **${SIGNER:-unknown}** (${STATUS:-status unknown})." >> "$OUT/RELEASE_NOTES.md"
    grep -q "Status: signed by a" <<<"$SIGCHECK" || echo "warning: package signature status: ${STATUS:-unknown}" >&2
    if xcrun stapler validate "$OUT/$NAME.pkg" >/dev/null 2>&1; then
        echo "It is notarised by Apple, with the ticket stapled, so it can also be installed by double-clicking it." >> "$OUT/RELEASE_NOTES.md"
    else
        echo "warning: the package is signed but not notarised" >&2
    fi
fi

echo "Release files in $OUT:"
ls -1 "$OUT" | sed 's/^/  /'
