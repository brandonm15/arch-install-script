#!/usr/bin/env bash

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
### ---------------

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


### Encrypt Disk ---
echo "Encrypting Disk --------------------------------------------------"

echo "Encrypting Disk..."
echo -n "$LUKS_PASS" | cryptsetup luksFormat "$MAIN" -q -
echo -n "$LUKS_PASS" | cryptsetup luksOpen "$MAIN" main -
echo "Disk encrypted."

echo "--------------------------------------------------\n"



PFX=""
[[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]] && PFX="p"
EFI="${DISK}${PFX}1"
MAIN="${DISK}${PFX}2"

# Encrypt main
echo -n "$LUKS_PASS" | cryptsetup luksFormat "$MAIN" -q -
echo -n "$LUKS_PASS" | cryptsetup luksOpen "$MAIN" main -

# Btrfs + subvols
mkfs.btrfs -f /dev/mapper/main
mount /dev/mapper/main /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

# Mount root/home (discard=sync per your notes)
mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=sync,subvol=@ /dev/mapper/main /mnt
mkdir -p /mnt/home
mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=sync,subvol=@home /dev/mapper/main /mnt/home

# EFI
mkfs.fat -F32 "$EFI"
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# Base
pacman -Sy --noconfirm archlinux-keyring
pacstrap /mnt base

# fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot config
arch-chroot /mnt /bin/bash <<'CHROOT'
set -euo pipefail
# Bring vars from outer env
HOSTNAME_VAR='"$HOSTNAME"'
USERNAME_VAR='"$USERNAME"'
ROOTPASS_VAR='"$ROOTPASS"'
USERPASS_VAR='"$USERPASS"'
TZ_VAR='"$TZ"'
LOCALE_VAR='"$LOCALE"'
KEYMAP_VAR='"$KEYMAP"'
UCPU_VAR='"$UCPU"'

# Time / locale / keymap
ln -sf "/usr/share/zoneinfo/${TZ_VAR}" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE_VAR//\//\\/}\)/\1/" /etc/locale.gen
locale-gen
printf "LANG=%s\n" "$LOCALE_VAR" > /etc/locale.conf
printf "KEYMAP=%s\n" "$KEYMAP_VAR" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME_VAR" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME_VAR}.localdomain ${HOSTNAME_VAR}
EOF

# Users
echo "root:${ROOTPASS_VAR}" | chpasswd
useradd -m -g users -G wheel "${USERNAME_VAR}"
echo "${USERNAME_VAR}:${USERPASS_VAR}" | chpasswd
pacman -S --noconfirm sudo vim
visudo -c >/dev/null || true
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Core pkgs (from your notes; fixed typos)
pacman -Syu --noconfirm \
  base-devel linux linux-headers linux-firmware btrfs-progs \
  grub efibootmgr mtools networkmanager network-manager-applet openssh git ufw acpid grub-btrfs \
  bluez bluez-utils pipewire alsa-utils pipewire-pulse pipewire-jack sof-firmware \
  ttf-firacode-nerd alacritty "$UCPU_VAR"

# mkinitcpio: add encrypt hook and btrfs module, then rebuild
sed -i 's/^MODULES=.*/MODULES=(btrfs atkbd)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -p linux

# GRUB (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# Add cryptdevice + root mapping; remove 'quiet'
LUKS_UUID=$(blkid -s UUID -o value "$(lsblk -no PKNAME /dev/mapper/main | sed "s|^|/dev/|")")
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' >> /etc/default/grub
sed -i 's/ quiet//g' /etc/default/grub
sed -i "s~^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"~GRUB_CMDLINE_LINUX_DEFAULT=\"\1 cryptdevice=UUID=${LUKS_UUID}:main root=/dev/mapper/main\"~" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Enable base services
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable sshd
systemctl enable ufw
systemctl enable acpid

# UFW basic rules (optional)
ufw default deny incoming || true
ufw default allow outgoing || true
ufw allow OpenSSH || true
ufw --force enable || true

# --- KDE Plasma desktop (full meta) + SDDM ---
# plasma-meta is the full Plasma 6 desktop; kde-applications-meta is the app suite (optional)
pacman -S --noconfirm plasma-meta kde-applications-meta sddm xdg-desktop-portal-kde

# Enable display manager
systemctl enable sddm.service

CHROOT

echo
echo "Done. Now reboot into KDE:"
echo "  umount -R /mnt && reboot"
