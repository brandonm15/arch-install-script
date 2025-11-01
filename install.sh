#!/bin/bash

# how to get:
# curl -fsSL https://raw.githubusercontent.com/brandonm15/arch-install-script/refs/heads/main/install.sh -o install.sh
# chmod +x install.sh

set -euo pipefail

CONFIG_DIR="./configs"

### Handle Config File
### ---------------------------------------------------------------------

echo -e "\n\n"

if [[ ! -d "$CONFIG_DIR" ]]; then
  echo "Config directory '$CONFIG_DIR' not found."
  exit 1
fi

# Get all .conf files in the directory
config_files=()
while IFS= read -r -d '' file; do
  config_files+=("$file")
done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.conf' -print0 | sort -z)

if [[ ${#config_files[@]} -eq 0 ]]; then
  echo "No config files found in $CONFIG_DIR"
  exit 1
fi

echo "Select a config file:"
select file in "${config_files[@]}"; do
  if [[ -n "$file" ]]; then
    CONFIG_FILE="$file"
    break
  fi
  echo "Invalid selection."
done

echo "Using config: $CONFIG_FILE"

# Export variables from config
set -a
source "$CONFIG_FILE"
set +a



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


### Encrypt Disk and Make filesystem 
### ---------------------------------------------------------------------

echo "Encrypting Disk..."
echo -n "$LUKS_PASS" | cryptsetup luksFormat "$MAIN" -q -
echo -n "$LUKS_PASS" | cryptsetup luksOpen "$MAIN" main -
echo "Disk encrypted."

echo "Making filesystem..."

PFX=""
[[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]] && PFX="p"
EFI="${DISK}${PFX}1"
MAIN="${DISK}${PFX}2"

mkfs.fat -F32 "$EFI"
mkfs.btrfs -f /dev/mapper/main



### Create Btrfs Subvolumes and mount 
### ---------------------------------------------------------------------

# Create Btrfs Subvolumes
echo "Creating Btrfs Subvolumes..."
mount /dev/mapper/main /mnt
cd /mnt
btrfs subvolume create @
btrfs subvolume create @home
echo "Btrfs Subvolumes created."
cd
umount /mnt

# Mount filesystems
echo "Mounting..."
mount -o $MOUNT_OPTIONS,subvol=@ /dev/mapper/main /mnt
mkdir /mnt/home
mount -o $MOUNT_OPTIONS,subvol=@home /dev/mapper/main /mnt/home
mkdir /mnt/boot
mount "$EFI" /mnt/boot
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
