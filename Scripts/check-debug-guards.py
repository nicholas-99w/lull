#!/usr/bin/env python3
"""Source-level check that Debug escape hatches are only compiled into Debug
builds (Docs/DEVELOPMENT.md > Dev safety). Complements check-release-hatches.sh, which
scans the built binaries.

Every line in Sources/ that mentions a Debug-only symbol must be inside an
`#if DEBUG` block (or the `#else` of `#if !DEBUG`). Exit 1 and list offenders
otherwise. Add new hatch symbols to SYMBOLS.

  python3 Scripts/check-debug-guards.py
"""
import pathlib, re, sys

SYMBOLS = [
    "debugDisableFlagPath", "debugMaxLockSeconds", "debugDevConfigFileName", "debugTimeOffsetKey",
    "debugTimeOffset", "debugConfigTimeOffset", "disableFlagPath", "DebugConfigSource",
    "MockDisplayStateSource", "Fixtures", "DemoOptions", "debugGate", "installDebugEscape",
    "debugLockedSince", "SimulateCommand", "PreviewModels", "PreviewSource", "debugPortalURL", "portalURLOverride",
]
PATTERN = re.compile(r"\b(" + "|".join(SYMBOLS) + r")\b")
ROOT = pathlib.Path(__file__).resolve().parent.parent / "Sources"

def debug_only(stack):
    # Each frame: (kind, in_else) where kind is "debug", "notdebug" or "other".
    return any((k == "debug" and not e) or (k == "notdebug" and e) for k, e in stack)

problems = []
checked = 0
for path in sorted(ROOT.rglob("*.swift")):
    stack = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        s = line.strip()
        if s.startswith("#if "):
            cond = s[4:].strip()
            stack.append(("debug" if cond == "DEBUG" else "notdebug" if cond == "!DEBUG" else "other", False))
            continue
        if s.startswith("#elseif"):
            if stack: stack[-1] = ("other", True)
            continue
        if s.startswith("#else"):
            if stack: stack[-1] = (stack[-1][0], True)
            continue
        if s.startswith("#endif"):
            if stack: stack.pop()
            continue
        code = s.split("//", 1)[0]
        if PATTERN.search(code):
            checked += 1
            if not debug_only(stack):
                problems.append(f"{path.relative_to(ROOT.parent)}:{n}: {s}")

if problems:
    print("FAIL: Debug-only symbols outside #if DEBUG:", file=sys.stderr)
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"OK: {checked} references to Debug-only symbols, all inside #if DEBUG")
