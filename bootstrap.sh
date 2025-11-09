#!/bin/bash

# Get instructions:
# curl -fsSL https://raw.githubusercontent.com/brandonm15/arch-install-script/main/bootstrap.sh -o bootstrap.sh
# chmod +x bootstrap.sh
# ./bootstrap.sh 

set -euo pipefail

GIT_REPO_URL="https://github.com/brandonm15/arch-install-script.git"
REPO_DIR="arch-install-script"

# Ensure git exists
pacman -Sy --noconfirm >/dev/null
if ! pacman -Q git &>/dev/null; then
  pacman -S --noconfirm git
fi

# If repo directory exists, ask whether to delete
if [[ -d "$REPO_DIR" ]]; then
  read -rp "Directory '$REPO_DIR' already exists. Delete and re-clone? (y/N): " choice
  if [[ "$choice" =~ ^([yY]|[yY][eE][sS])$ ]]; then
    rm -rf "$REPO_DIR"
    git clone "$GIT_REPO_URL"
  else
    echo "Using existing directory."
  fi
else
  git clone "$GIT_REPO_URL"
fi

# Enter bash instance to change passwors
echo
echo "You are now inside the bash instance."
echo "Type 'exit' to return to the installer."
bash

# Make installer executable
chmod +x "$REPO_DIR/install.sh"

# Run installer
cd "$REPO_DIR"
./install.sh
