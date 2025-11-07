#!/bin/bash

# Get instructions:
# curl -fsSL https://raw.githubusercontent.com/brandonm15/arch-install-script/main/bootstrap.sh -o bootstrap.sh
# chmod +x bootstrap.sh
# ./bootstrap.sh 

GIT_REPO_URL="https://github.com/brandonm15/arch-install-script.git"

set -euo pipefail

pacman -Sy

if ! pacman -Q git &>/dev/null; then
  pacman -S --noconfirm git
fi



#If repo dir exists ask if delete and reclone
if ! [[ -d "arch-install-script" ]]; then
  read -p "Repo directory exists. Delete and reclone? (y/N): " delete_repo
  if [[ "$delete_repo" == "y" ]]; then
    rm -rf arch-install-script
    git clone "$GIT_REPO_URL"
  fi
else
  git clone "$GIT_REPO_URL"
fi

# make executable
chmod +x arch-install-script/install.sh

# Run the installer
cd arch-install-script
./install.sh