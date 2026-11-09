#!/bin/bash
# Removes a dev install (Scripts/dev-install.sh). Same as the production
# uninstaller, which also removes the Debug dev config.
#   sudo Scripts/dev-uninstall.sh [--purge]
exec "$(cd "$(dirname "$0")" && pwd)/uninstall.sh" "$@"
