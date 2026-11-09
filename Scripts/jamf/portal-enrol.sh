#!/bin/bash
# Jamf Pro policy script: "Lull portal enrolment".
# Writes the portal enrolment secret to /var/db/lull/portal-enroll.json
# (root:wheel 0600), which lulld uses once to register this Mac with the
# parent portal (lull-portal contract/PORTAL_API.md). Never put the secret in the profile:
# profiles are readable by local users.
#
# Parameter 4: the enrolment secret (same as the portal's Lull__EnrolmentSecret).
#   Allowed characters: letters, digits and . _ ~ + / = - (at least 16).
# Run once per Mac (Jamf: Once per computer), or again after changing the secret.
set -euo pipefail

SECRET="${4:-}"
DIR=/var/db/lull
FILE="$DIR/portal-enroll.json"

if [[ $EUID -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi
# Restricting the characters means the value can't break out of the JSON below.
# Length is checked separately: macOS's regex library rejects repeat counts
# above 255 ({16,256} never matches), and bash 3.2 uses it.
CHARSET='^[-A-Za-z0-9._~+/=]+$'
if [[ ! "$SECRET" =~ $CHARSET ]] || (( ${#SECRET} < 16 || ${#SECRET} > 256 )); then
    echo "parameter 4 must be the enrolment secret (16-256 of A-Z a-z 0-9 . _ ~ + / = -)" >&2
    exit 1
fi

umask 077
mkdir -p "$DIR"
chown root:wheel "$DIR"
chmod 755 "$DIR"
tmp=$(mktemp "$DIR/.portal-enroll.XXXXXX")
printf '{"EnrolmentSecret":"%s"}\n' "$SECRET" > "$tmp"
chown root:wheel "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$FILE"
echo "wrote $FILE"
