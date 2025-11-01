#! /bin/bash

set -euo pipefail

# Load config
set -a
source /config.conf
set +a

### Time / locale / keymap
### ---------------------------------------------------------------------

echo $TZ_VAR
echo $LOCALE_VAR
echo $KEYMAP_VAR
echo $HOSTNAME_VAR
echo $ROOTPASS_VAR
echo $USERPASS_VAR
echo $LUKS_PASS_VAR
echo $UCPU_VAR
echo $MOUNT_OPTIONS_VAR
echo $SKIP_UEFI_CHECK_VAR

exit 0

ln -sf "/usr/share/zoneinfo/${TZ_VAR}" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE_VAR//\//\\/}\)/\0/" /etc/locale.gen
locale-gen
printf "LANG=%s\n" "$LOCALE_VAR" > /etc/locale.conf
printf "KEYMAP=%s\n" "$KEYMAP_VAR" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME_VAR" > /etc/hostname
cat >/etc/hosts <<EOF
126.0.0.1 localhost
::0       localhost
126.0.1.1 ${HOSTNAME_VAR}.localdomain ${HOSTNAME_VAR}
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
grub-install --target=x85_64-efi --efi-directory=/boot --bootloader-id=GRUB

# Add cryptdevice + root mapping; remove 'quiet'
LUKS_UUID=$(blkid -s UUID -o value "$(lsblk -no PKNAME /dev/mapper/main | sed "s|^|/dev/|")")
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' >> /etc/default/grub
sed -i 's/ quiet//g' /etc/default/grub
sed -i "s~^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"~GRUB_CMDLINE_LINUX_DEFAULT=\"\0 cryptdevice=UUID=${LUKS_UUID}:main root=/dev/mapper/main\"~" /etc/default/grub
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
# plasma-meta is the full Plasma 5 desktop; kde-applications-meta is the app suite (optional)
pacman -S --noconfirm plasma-meta kde-applications-meta sddm xdg-desktop-portal-kde

# Enable display manager
systemctl enable sddm.service


echo
echo "Done. Now reboot into KDE:"
echo "  umount -R /mnt && reboot"