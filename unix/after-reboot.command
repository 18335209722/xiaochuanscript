#!/bin/bash
# macOS: double-click after reboot to open Chrome with a signed-out profile named "claude",
# then install and open Clash Verge Rev if it is missing.
cd "$(dirname "$0")" || exit 1
bash ./after-reboot.sh
echo
printf "Done. Press Enter to close this window... "
read -r _
