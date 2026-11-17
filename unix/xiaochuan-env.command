#!/bin/bash
# macOS: double-click this file in Finder to open the menu.
cd "$(dirname "$0")" || exit 1
bash ./xiaochuan-env.sh
echo
printf "Done. Press Enter to close this window... "
read -r _
