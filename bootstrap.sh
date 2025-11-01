#!/bin/bash

# Get instructions:
# curl -fsSL https://raw.githubusercontent.com/brandonm15/arch-install-script/main/bootstrap.sh -o bootstrap.sh
# chmod +x bootstrap.sh

GIT_REPO_URL="https://github.com/brandonm15/arch-install-script.git"

set -euo pipefail

if ! pacman -Q git &>/dev/null; then
  pacman -S --noconfirm git
fi

# Clone the repository
git clone "$GIT_REPO_URL"

# make executable
chmod +x arch-install-script/install.sh

# Run the installer
cd arch-install-script
./install.sh