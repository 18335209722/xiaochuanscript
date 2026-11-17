#!/bin/bash
# macOS: double-click after reboot to create (or reopen) a signed-out Chrome profile named "claude".
cd "$(dirname "$0")" || exit 1
bash ./chrome-profile.sh
echo
printf "Done. Press Enter to close this window... "
read -r _
