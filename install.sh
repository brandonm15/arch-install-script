#!/bin/bash

# how to get:
# curl -fsSL https://raw.githubusercontent.com/brandonm15/arch-install-script/refs/heads/main/install.sh -o install.sh
# chmod +x install.sh

set -euo pipefail

### --- EDIT ME ---
DISK="/dev/sda"   # Root Disk for install     
HOSTNAME="archbox" # Hostname for the system
USERNAME="brandon" # Username for the system
ROOTPASS="changepass123" # Root password for the system !!! CHANGE THIS !!!
USERPASS="changepass123" # User password for the system !!! CHANGE THIS !!!
LUKS_PASS="changepass123" # LUKS password for the system !!! CHANGE THIS !!!
TZ="Australia/Sydney" # Timezone for the system
LOCALE="en_US.UTF-8" # Locale for the system
KEYMAP="us" # Keymap for the system
UCPU="amd-ucode" # CPU microcode for the system
MOUNT_OPTIONS="noatime,ssd,compress=zstd,space_cache=v2,discard=sync"
### ---------------

INSTALLER_CHROOT_SCRIPT_URL="https://raw.githubusercontent.com/brandonm15/arch-install-script/main/in_chroot_install.sh"

# Startup
echo "Starting installation..."
printf "3..."
sleep 1
printf "2..."
sleep 1
printf "1..."
sleep 1
printf "GO!"
sleep 1

### --- Init Checks and Setup ---
echo "Init --------------------------------------------------"

# Check internet connection
echo "Checking for internet connection..."
ping -c1 -W2 archlinux.org >/dev/null || { echo "No internet."; exit 1; }
echo "Internet connection found."

# Check for UEFI mode
echo "Checking for UEFI mode..."
[ -d /sys/firmware/efi ] || { echo "Boot the ISO in UEFI mode."; exit 1; }
echo "UEFI mode found."

# Check disk path exists
echo "Checking for disk path..."
[ -d "$DISK" ] || { echo "Disk path does not exist."; exit 1; }
echo "Disk path found."

# Check if nothing is mounted
echo "Checking if nothing is mounted..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
cryptsetup luksClose main 2>/dev/null || true

echo "--------------------------------------------------\n"


### Set Locale and Timezone ---
echo "Setting Timezone --------------------------------------------------"

# Set iso timezone
echo "Setting Timezone..."
timedatectl set-timezone Australia/Sydney
timedatectl set-ntp true

echo "--------------------------------------------------\n"


### Partition Disk ---
echo "Partitioning Disk --------------------------------------------------"

# Partition Disk
echo "Partitioning Disk..."

echo "About to WIPE ${DISK}. Ctrl+C to abort."
sleep 5

sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1GiB -t1:ef00 -c1:"EFI System" "$DISK"
sgdisk -n2:0:0      -t2:8300 -c2:"Linux (Btrfs+LUKS)" "$DISK"
echo "Disk partitioned."

echo "--------------------------------------------------\n"


### Encrypt Disk and Make filesystem ---
echo "Encrypting Disk and Making filesystem --------------------------------------------------"

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

echo "--------------------------------------------------\n"

### Create Btrfs Subvolumes and mount ---
echo "Creating Btrfs Subvolumes and mounting --------------------------------------------------"

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

echo "--------------------------------------------------\n"

### Install Base ---
echo "Installing Base --------------------------------------------------"

# Install Base
pacstrap /mnt base
# fstab
genfstab -U /mnt >> /mnt/etc/fstab

echo "--------------------------------------------------\n"


### Copy rest of installer script into chroot ---
echo "Copying rest of installer script into chroot --------------------------------------------------"
curl -fsSL "$INSTALLER_CHROOT_SCRIPT_URL" -o /mnt/in_chroot_install.sh
chmod +x /mnt/in_chroot_install.sh
echo "--------------------------------------------------\n"

### Chroot ---
echo "Chrooting --------------------------------------------------"

# Chroot config
arch-chroot /mnt /bin/bash in_chroot_install.sh
