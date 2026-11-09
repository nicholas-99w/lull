# Sourced by the packaging scripts. Reads signing settings the same way the
# Xcode build does, so the build and the scripts can't disagree:
#   1. a non-empty environment variable of the same name, else
#   2. Config/Signing.local.xcconfig (gitignored; see the .example), else
#   3. empty.
# Only "KEY = value" and "KEY[config=Release] = value" lines are read. The
# packaging scripts only handle Release products, so a Debug-only value is
# ignored on purpose.

SIGNING_LOCAL_XCCONFIG="${SIGNING_LOCAL_XCCONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/Config/Signing.local.xcconfig}"

signing_setting() {
    local key="$1"
    local value="${!key:-}"
    if [[ -z "$value" && -f "$SIGNING_LOCAL_XCCONFIG" ]]; then
        value=$(sed -n -E "s/^[[:space:]]*${key}(\[config=Release\])?[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\2/p" \
            "$SIGNING_LOCAL_XCCONFIG" | tail -1)
    fi
    # "-" is the ad-hoc identity, so treat it as "not configured".
    [[ "$value" == "-" ]] && value=""
    printf '%s' "$value"
}
