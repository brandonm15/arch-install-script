#!/bin/bash

# how to get:
# curl -fsSL https://raw.githubusercontent.com/brandonm15/arch-install-script/refs/heads/main/install.sh -o install.sh
# chmod +x install.sh

set -eo pipefail

CONFIG_DIR="./configs"

# Helpful vars
LUKS_LABEL="main"
PARTITION_PFX=""
[[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]] && PARTITION_PFX="p"
EFI_PARTITION_DEV="${DISK}${PARTITION_PFX}1"
MAIN_PARTITION_DEV="${DISK}${PARTITION_PFX}2"
MAIN_ENCRYPTED_PARTITION_DEV="/dev/mapper/${LUKS_LABEL}"

SSD_MOUNT_OPTIONS="noatime,ssd,compress=zstd,space_cache=v2,discard=async"
HDD_MOUNT_OPTIONS="noatime,compress=zstd,space_cache=v2,discard=async"

### Handle Config File
### ---------------------------------------------------------------------

echo -e "\n\n"

CONFIG_FILE=""

if [[ $# -gt 0 ]]; then
  CONFIG_FILE="$CONFIG_DIR/$1"
elif [ -t 0 ]; then
  # Interactive shell, prompt user
  echo "Available config files:"
  mapfile -t config_files < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.conf' | sort)

  for i in "${!config_files[@]}"; do
    printf "%2d) %s\n" "$((i+1))" "$(basename "${config_files[$i]}")"
  done

  read -rp "Select a config (1-${#config_files[@]}): " selection

  if ! [[ "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#config_files[@]} )); then
    echo "Invalid selection"
    exit 1
  fi

  CONFIG_FILE="${config_files[$((selection-1))]}"
else
  echo "This script needs a config argument when run non-interactively."
  echo "Usage: bash -s server.conf"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file '$CONFIG_FILE' not found."
  exit 1
fi

set -a
source "$CONFIG_FILE"
set +a

echo -e "\n"

### Init Checks and Setup 
### ---------------------------------------------------------------------

# Check internet connection
echo "Checking for internet connection..."
ping -c1 -W2 archlinux.org >/dev/null || { echo "No internet."; exit 1; }
echo "Internet connection found."

# Check for UEFI mode
if [ "$SKIP_UEFI_CHECK" != true ]; then
  echo "Checking for UEFI mode..."
  [ -d /sys/firmware/efi ] || { echo "Boot the ISO in UEFI mode."; exit 1; }
  echo "UEFI mode found."
fi

# Check disk path exists
#echo "Checking for disk path..."
#[ -d "$DISK" ] || { echo "Disk path does not exist."; exit 1; }
#echo "Disk path found."

# Check if nothing is mounted
echo "Checking if nothing is mounted..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
cryptsetup luksClose main 2>/dev/null || true



### Set Locale and Timezone 
### ---------------------------------------------------------------------

# Set iso timezone
echo "Setting Timezone..."
timedatectl set-timezone Australia/Sydney
timedatectl set-ntp true



### Partition Disk 
### ---------------------------------------------------------------------

# Partition Disk
echo "Partitioning Disk..."

echo "About to WIPE ${DISK}. Ctrl+C to abort."
sleep 5

sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1GiB -t1:ef00 -c1:"EFI System" "$DISK"
sgdisk -n2:0:0      -t2:8300 -c2:"Linux (Btrfs+LUKS)" "$DISK"
echo "Disk partitioned."


### Encrypt Disk (If enabled) 
### ---------------------------------------------------------------------


if [ "$ENCRYPT_DISK" == true ]; then
  echo "Encrypting Disk..."
  echo -n "$LUKS_PASS" | cryptsetup luksFormat "$MAIN_PARTITION_DEV" -q -
  echo -n "$LUKS_PASS" | cryptsetup luksOpen "$MAIN_PARTITION_DEV" "$LUKS_LABEL" -
fi



### Create Btrfs Subvolumes and mount 
### ---------------------------------------------------------------------

# Create Btrfs Subvolumes
if [ "$ENCRYPT_DISK" == true ]; then  
  mkfs.btrfs -f "$MAIN_ENCRYPTED_PARTITION_DEV"
else
  mkfs.btrfs -f "$MAIN_PARTITION_DEV"
fi
echo "Creating Btrfs Subvolumes..."

# Format efi partition
mkfs.fat -F32 "$EFI_PARTITION_DEV"

# Mount correct partition
if [ "$ENCRYPT_DISK" == true ]; then
  mount "$MAIN_ENCRYPTED_PARTITION_DEV" /mnt
else
  mount "$MAIN_PARTITION_DEV" /mnt
fi

# Create Btrfs Subvolumes
cd /mnt
btrfs subvolume create @
btrfs subvolume create @home
echo "Btrfs Subvolumes created."
cd -
umount /mnt

# Get correct mount options
if [ "$SSD_DISK" == true ]; then
  MOUNT_OPTIONS="$SSD_MOUNT_OPTIONS"
else
  MOUNT_OPTIONS="$HDD_MOUNT_OPTIONS"
fi

# Mount filesystems
echo "Mounting..."
if [ "$ENCRYPT_DISK" == true ]; then
  mount -o $MOUNT_OPTIONS,subvol=@ "$MAIN_ENCRYPTED_PARTITION_DEV" /mnt
else
  mount -o $MOUNT_OPTIONS,subvol=@ "$MAIN_PARTITION_DEV" /mnt
fi
mkdir /mnt/home
if [ "$ENCRYPT_DISK" == true ]; then
  mount -o $MOUNT_OPTIONS,subvol=@home "$MAIN_ENCRYPTED_PARTITION_DEV" /mnt/home
else
  mount -o $MOUNT_OPTIONS,subvol=@home "$MAIN_PARTITION_DEV" /mnt/home
fi
mkdir /mnt/boot

mount "$EFI_PARTITION_DEV" /mnt/boot
echo "Filesystems mounted."



### Install Base 
### ---------------------------------------------------------------------

# Install Base
pacstrap /mnt base
# fstab
genfstab -U /mnt >> /mnt/etc/fstab


### Copy rest of installer script into chroot 
### ---------------------------------------------------------------------

# Copy file
cp in_chroot_install.sh /mnt/in_chroot_install.sh
chmod +x /mnt/in_chroot_install.sh

# Copy config
cp "$CONFIG_FILE" /mnt/config.conf


### Chroot 
### ---------------------------------------------------------------------

arch-chroot /mnt /bin/bash in_chroot_install.sh

# ---

echo "End of main install script \n"
