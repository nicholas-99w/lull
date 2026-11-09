#!/bin/bash
# Fails if any Debug-only escape hatch (Docs/DEVELOPMENT.md > Dev safety) is present in
# the Release binaries. Run via `make check-release` after `make release`.
#
#   Scripts/check-release-hatches.sh [products-dir]           # Release: no marker may appear
#   Scripts/check-release-hatches.sh --self-test [debug-dir]  # Debug: every marker must appear
#
# Markers are strings that only exist inside `#if DEBUG` code. If you add a new
# Debug-only hatch, add a unique marker string for it here; --self-test proves
# the markers are actually detectable (e.g. Xcode moves Debug code into
# Lull.debug.dylib, which is why every Mach-O file in the bundle is scanned).
set -euo pipefail

MODE=release
if [[ "${1:-}" == "--self-test" ]]; then
    MODE=selftest
    shift
fi
DEFAULT_DIR=build/DerivedData/Build/Products/$([[ $MODE == release ]] && echo Release || echo Debug)
PRODUCTS="${1:-$DEFAULT_DIR}"

MARKERS=(
    "/var/db/lull/DISABLE"          # DISABLE flag file
    "DebugTimeOffsetSeconds"        # dev-plist time offset key
    ".dev.plist"                    # dev config file
    "--time-offset"                 # lulld debug flag
    "--dev-config"                  # lulld debug flag
    "--state-dir"                   # lulld debug flag
    "--portal-url"                  # lulld debug flag (local test portal)
    "DEBUG: auto-released"          # daemon auto-release reason
    "DEBUG: DISABLE file present"   # daemon disable reason
    "simulate --config"             # lullctl debug command
    "--demo"                        # Lull.app demo mode
    "DEBUG emergency release"       # Lull.app key-chord release
    "DEBUG demo mode"               # mock state source
    "auto-released overlay"         # Lull.app auto-release
    "2026-10-05T11:00:00Z"          # preview/demo fixture time
)
# Positive control: present in every real build, so scanning the wrong file fails.
CONTROL="au.com.nickit"

# Every Mach-O file in the products we ship.
FILES=()
for f in "$PRODUCTS/lulld" "$PRODUCTS/lullctl"; do [[ -f "$f" ]] && FILES+=("$f"); done
if [[ -d "$PRODUCTS/Lull.app" ]]; then
    while IFS= read -r f; do
        file -b "$f" | grep -q "Mach-O" && FILES+=("$f")
    done < <(find "$PRODUCTS/Lull.app/Contents" -type f -perm +111)
fi
if [[ ${#FILES[@]} -lt 3 ]]; then
    echo "missing products in $PRODUCTS (build first)" >&2
    exit 1
fi

ALL_STRINGS=$(mktemp)
trap 'rm -f "$ALL_STRINGS"' EXIT
status=0
for f in "${FILES[@]}"; do
    strings -a "$f" > "$ALL_STRINGS.one"
    cat "$ALL_STRINGS.one" >> "$ALL_STRINGS"
    if [[ $MODE == release ]]; then
        if ! grep -qF -- "$CONTROL" "$ALL_STRINGS.one" && [[ "$(basename "$f")" != "__preview.dylib" ]]; then
            # Small stubs (e.g. a launcher) may lack it; only the main binaries must have it.
            case "$f" in */lulld|*/lullctl|*/MacOS/Lull)
                echo "FAIL: control string '$CONTROL' not found in $f (scanning the wrong file?)" >&2
                status=1 ;;
            esac
        fi
        for marker in "${MARKERS[@]}"; do
            if grep -qF -- "$marker" "$ALL_STRINGS.one"; then
                echo "FAIL: '$marker' found in $f" >&2
                status=1
            fi
        done
    fi
    rm -f "$ALL_STRINGS.one"
done

if [[ $MODE == selftest ]]; then
    for marker in "${MARKERS[@]}"; do
        if ! grep -qF -- "$marker" "$ALL_STRINGS"; then
            echo "FAIL: marker '$marker' not found in Debug products; the check can't detect it" >&2
            status=1
        fi
    done
    [[ $status -eq 0 ]] && echo "OK: all ${#MARKERS[@]} markers detectable in Debug products (${#FILES[@]} files)"
else
    [[ $status -eq 0 ]] && echo "OK: no Debug escape hatches in Release products (${#MARKERS[@]} markers x ${#FILES[@]} files)"
fi
exit $status
