#!/bin/bash
# Arch automated install (Btrfs, optional LUKS, UEFI), VirtualBox-friendly
# Usage (interactive):   ./install.sh
# Usage (non-interactive):  ./install.sh configs/server.conf
#
# To fetch:
#   curl -fsSL https://raw.githubusercontent.com/brandonm15/arch-install-script/refs/heads/main/install.sh -o install.sh
#   chmod +x install.sh

set -euo pipefail

CONFIG_DIR="./configs"

# ---------------------------
# Helpers
# ---------------------------
info() { printf "\n[INFO] %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die()  { printf "\n[ERR ] %s\n" "$*" >&2; exit 1; }

# ---------------------------
# Pick / Load config
# ---------------------------
echo
CONFIG_FILE=""
if [[ $# -gt 0 ]]; then
  CONFIG_FILE="$CONFIG_DIR/$1"
elif [ -t 0 ]; then
  info "Available config files:"
  mapfile -t config_files < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.conf' | sort)
  ((${#config_files[@]})) || die "No *.conf files found in $CONFIG_DIR"
  for i in "${!config_files[@]}"; do
    printf "%2d) %s\n" "$((i+1))" "$(basename "${config_files[$i]}")"
  done
  read -rp "Select a config (1-${#config_files[@]}): " selection
  [[ "$selection" =~ ^[0-9]+$ ]] && (( selection>=1 && selection<=${#config_files[@]} )) \
    || die "Invalid selection"
  CONFIG_FILE="${config_files[$((selection-1))]}"
else
  die "This script needs a config argument when run non-interactively. Example: ./install.sh server.conf"
fi

[[ -f "$CONFIG_FILE" ]] || die "Config file '$CONFIG_FILE' not found."

# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

# ---------------------------
# Derived vars (AFTER config)
# ---------------------------
[[ -n "${DISK:-}" ]] || die "DISK not set in config."
[[ -b "$DISK" ]] || die "DISK '$DISK' is not a block device."

LUKS_LABEL="${LUKS_LABEL:-main}"

PARTITION_PFX=""
if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
  PARTITION_PFX="p"
fi

EFI_PARTITION_DEV="${DISK}${PARTITION_PFX}1"
MAIN_PARTITION_DEV="${DISK}${PARTITION_PFX}2"
MAIN_ENCRYPTED_PARTITION_DEV="/dev/mapper/${LUKS_LABEL}"

SSD_MOUNT_OPTIONS="noatime,ssd,compress=zstd,space_cache=v2,discard=async"
HDD_MOUNT_OPTIONS="noatime,compress=zstd,space_cache=v2,discard=async"
MOUNT_OPTIONS="$([[ "${SSD_DISK:-false}" == true ]] && echo "$SSD_MOUNT_OPTIONS" || echo "$HDD_MOUNT_OPTIONS")"

# ---------------------------
# Pre-flight checks
# ---------------------------
info "Checking internet connectivity..."
ping -c1 -W2 archlinux.org >/dev/null || die "No internet."

if [[ "${SKIP_UEFI_CHECK:-false}" != true ]]; then
  info "Checking UEFI boot..."
  [[ -d /sys/firmware/efi ]] || die "Boot the ISO in UEFI mode."
fi

# Ensure clean slate
info "Ensuring nothing is mounted..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
if [[ -e "$MAIN_ENCRYPTED_PARTITION_DEV" ]]; then
  cryptsetup luksClose "$LUKS_LABEL" 2>/dev/null || true
fi
mkdir -p /mnt

# Set clock/timezone (helpful when generating locales later)
info "Setting timezone/ntp..."
timedatectl set-timezone "${TZ:-Australia/Sydney}"
timedatectl set-ntp true

# ---------------------------
# Partition Disk (DESTROYS DATA)
# ---------------------------
info "About to WIPE ${DISK}. Ctrl+C to abort."
sleep 5

info "Partitioning disk..."
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1GiB -t1:ef00 -c1:"EFI System" "$DISK"
sgdisk -n2:0:0      -t2:8300 -c2:"Linux (Btrfs+LUKS)" "$DISK"
partprobe "$DISK"
udevadm settle

# ---------------------------
# Filesystems & (optional) LUKS
# ---------------------------
info "Formatting EFI system partition..."
mkfs.fat -F32 "$EFI_PARTITION_DEV"

if [[ "${ENCRYPT_DISK:-false}" == true ]]; then
  info "Encrypting main partition with LUKS..."
  # Read passphrase from variable via stdin
  echo -n "$LUKS_PASS" | cryptsetup luksFormat "$MAIN_PARTITION_DEV" -q --key-file=-
  echo -n "$LUKS_PASS" | cryptsetup luksOpen   "$MAIN_PARTITION_DEV" "$LUKS_LABEL" --key-file=-
  info "Creating Btrfs on encrypted mapper..."
  mkfs.btrfs -f "$MAIN_ENCRYPTED_PARTITION_DEV"
  ROOT_DEV="$MAIN_ENCRYPTED_PARTITION_DEV"
else
  warn "ENCRYPT_DISK=false — proceeding WITHOUT full-disk encryption."
  info "Creating Btrfs on main partition..."
  mkfs.btrfs -f "$MAIN_PARTITION_DEV"
  ROOT_DEV="$MAIN_PARTITION_DEV"
fi

# ---------------------------
# Btrfs layout & mounts
# ---------------------------
info "Creating Btrfs subvolumes..."
mount "$ROOT_DEV" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

info "Mounting filesystems..."
mount -o "$MOUNT_OPTIONS",subvol=@ "$ROOT_DEV" /mnt
mkdir -p /mnt/home
mount -o "$MOUNT_OPTIONS",subvol=@home "$ROOT_DEV" /mnt/home
mkdir -p /mnt/boot
mount "$EFI_PARTITION_DEV" /mnt/boot

# ---------------------------
# Base install
# ---------------------------
info "Installing base system..."
pacstrap /mnt base base-devel

info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ---------------------------
# Prepare in-chroot phase
# ---------------------------
info "Copying in-chroot script and config..."
[[ -f in_chroot_install.sh ]] || die "Missing in_chroot_install.sh in current directory."
cp in_chroot_install.sh /mnt/in_chroot_install.sh
chmod +x /mnt/in_chroot_install.sh
cp "$CONFIG_FILE" /mnt/config.conf

# ---------------------------
# Chroot
# ---------------------------
info "Entering chroot to complete setup..."
arch-chroot /mnt /bin/bash /in_chroot_install.sh

info "Installation complete."
echo -e "\nYou can reboot after exiting the chroot if it hasn't already.\n"
