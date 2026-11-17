#!/bin/bash
# macOS: double-click to install the latest Clash Verge Rev if it is not installed yet, then open it.
cd "$(dirname "$0")" || exit 1
bash ./clash-verge.sh
echo
printf "Done. Press Enter to close this window... "
read -r _
