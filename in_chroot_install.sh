#! /bin/bash

set -euo pipefail

echo -e "\n\nStarting chroot installation script...\n"

# Load config
set -a
source /config.conf
set +a

### Time / locale / keymap
### ---------------------------------------------------------------------

ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE//\//\\/}\)/\0/" /etc/locale.gen
locale-gen
printf "LANG=%s\n" "$LOCALE" > /etc/locale.conf
# printf "KEYMAP=%s\n" "$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname



### Users
### ---------------------------------------------------------------------

pacman -S --noconfirm sudo
echo "root:${ROOTPASS}" | chpasswd
useradd -m -g users -G wheel "${USERNAME}"
echo "${USERNAME}:${USERPASS}" | chpasswd
chmod u+w /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
chmod u-w /etc/sudoers



### Core pkgs
### ---------------------------------------------------------------------

pacman -Syu --noconfirm \
  base-devel linux linux-headers linux-firmware btrfs-progs \
  grub efibootmgr mtools networkmanager network-manager-applet openssh git ufw acpid grub-btrfs \
  bluez bluez-utils pipewire alsa-utils pipewire-pulse pipewire-jack sof-firmware \
  ttf-firacode-nerd alacritty "$CPU_MICROCODE"

# mkinitcpio: add encrypt hook and btrfs module, then rebuild
sed -i 's/^MODULES=.*/MODULES=(btrfs atkbd)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -p linux

# GRUB (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# Add cryptdevice + root mapping; remove 'quiet'
LUKS_UUID=$(blkid -s UUID -o value "$(lsblk -no PKNAME /dev/mapper/main | sed "s|^|/dev/|")")
echo "LUKS_UUID: $LUKS_UUID"
grub-mkconfig -o /boot/grub/grub.cfg
sed -i 's/ quiet//g' /etc/default/grub
sed -i "s~^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"~GRUB_CMDLINE_LINUX_DEFAULT=\"\0 cryptdevice=UUID=${LUKS_UUID}:main root=/dev/mapper/main\"~" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

exit 0

# Enable base services
systemctl enable NetworkManager
if [ "$HAS_BLUETOOTH" = true ]; then
  systemctl enable bluetooth
fi
if [ "$HAS_BATTERY" = true ]; then
  systemctl enable acpid
fi
systemctl enable sshd
systemctl enable ufw

# UFW basic rules (optional)
#ufw default deny incoming || true
#ufw default allow outgoing || true
#ufw allow OpenSSH || true
#ufw --force enable || true

# --- KDE Plasma desktop (full meta) + SDDM ---
# plasma-meta is the full Plasma 5 desktop; kde-applications-meta is the app suite (optional)
pacman -S --noconfirm plasma-meta kde-applications-meta sddm xdg-desktop-portal-kde

# Enable display manager
systemctl enable sddm.service


echo
echo "Done. Now reboot into KDE:"
echo "  umount -R /mnt && reboot"