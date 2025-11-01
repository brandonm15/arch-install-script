#!/bin/bash

# Get instructions:
# curl -fsSL https://raw.githubusercontent.com/brandonm15/arch-install-script/main/bootstrap.sh | bash

GIT_REPO_URL="git@github.com:brandonm15/arch-install-script.git"

set -euo pipefail

pacman -S --noconfirm git

# Clone the repository
git clone "$GIT_REPO_URL"

# make executable
chmod +x arch-install-script/install.sh

# Run the installer
cd arch-install-script
./install.sh