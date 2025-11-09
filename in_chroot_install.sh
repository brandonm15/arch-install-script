#!/bin/bash
set -euo pipefail

echo -e "\n\nStarting chroot installation script...\n"

# Load config
set -a
source /config.conf
set +a

# -----------------------------
# Time / locale / keymap
# -----------------------------
ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
hwclock --systohc

# Enable locale in /etc/locale.gen
sed -i "s/^#\s*\(${LOCALE//\//\\/}\)/\1/" /etc/locale.gen
locale-gen
printf "LANG=%s\n" "$LOCALE" > /etc/locale.conf

# Keymap
[ -n "${KEYMAP:-}" ] && printf "KEYMAP=%s\n" "$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# -----------------------------
# Users
# -----------------------------
pacman -S --noconfirm sudo
echo "root:${ROOTPASS}" | chpasswd
useradd -m -G wheel "${USERNAME}"
echo "${USERNAME}:${USERPASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# -----------------------------
# Core packages
# -----------------------------
pacman -Syu --noconfirm \
  base-devel linux linux-headers linux-firmware btrfs-progs \
  grub efibootmgr mtools networkmanager network-manager-applet openssh git ufw acpid grub-btrfs \
  pipewire pipewire-pulse pipewire-jack sof-firmware \
  ttf-firacode-nerd 


if [[ "$HAS_BLUETOOTH" == "true" ]]; then
  pacman -S --noconfirm bluez bluez-utils
fi


# CPU microcode
if [[ "$CPU" == "amd" ]]; then
  pacman -S --noconfirm amd-ucode
elif [[ "$CPU" == "intel" ]]; then
  pacman -S --noconfirm intel-ucode
fi

# -----------------------------
# mkinitcpio
# -----------------------------
# Place microcode early, encrypt only if encryption enabled
if [[ "${ENCRYPT_DISK:-false}" == true ]]; then
  HOOKS="(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)"
else
  HOOKS="(base udev autodetect microcode modconf kms keyboard keymap consolefont block btrfs filesystems fsck)"
fi

sed -i 's/^MODULES=.*/MODULES=(btrfs atkbd)/' /etc/mkinitcpio.conf
sed -i "s|^HOOKS=.*|HOOKS=$HOOKS|" /etc/mkinitcpio.conf

mkinitcpio -P

# -----------------------------
# GRUB
# -----------------------------
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# Remove quiet
sed -i 's/ quiet//g' /etc/default/grub

if [[ "${ENCRYPT_DISK:-false}" == true ]]; then
  # Insert cryptdevice only when using encryption
  LUKS_DEV=$(blkid -t TYPE=crypto_LUKS -o device)
  LUKS_UUID=$(blkid -s UUID -o value "$LUKS_DEV")
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$LUKS_UUID:main root=/dev/mapper/main\"|" /etc/default/grub
else
  # Standard root= line
  ROOT_UUID=$(blkid -s UUID -o value "$(blkid -t TYPE=btrfs -o device | head -n1)")
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"root=UUID=$ROOT_UUID rootflags=subvol=@\"|" /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg

# -----------------------------
# Services
# -----------------------------
systemctl enable NetworkManager
systemctl start NetworkManager || true
[[ "$HAS_BLUETOOTH" == true ]] && systemctl enable bluetooth
[[ "$HAS_BATTERY" == true ]] && systemctl enable acpid
[[ "$SSD_DISK" == true ]] && systemctl enable fstrim.timer
systemctl enable sshd
systemctl enable ufw

# -----------------------------
# Rustup Install
# -----------------------------
pacman -S --noconfirm rustup
rustup install stable
rustup default stable
# Install rustup and Rust toolchain (system wide)
pacman -S --noconfirm rustup
sudo -u "$USERNAME" bash -c "
  rustup install stable
  rustup default stable
"

# Add Rust to PATH for all users (so makepkg sees it)
echo 'export PATH="$PATH:/home/'"$USERNAME"'/.cargo/bin"' > /etc/profile.d/rust.sh
chmod +x /etc/profile.d/rust.sh

# Reload environment for current shell
source /etc/profile.d/rust.sh



# -----------------------------
# Paru Install as USER (not root)
# -----------------------------
sudo -u "$USERNAME" bash <<EOF
  set -e
  cd /home/$USERNAME
  git clone https://aur.archlinux.org/paru.git
  cd paru
  makepkg -si --noconfirm
  cd ..
  rm -rf paru
EOF




# -----------------------------
# KDE Plasma 
# -----------------------------
pacman -S --noconfirm plasma-meta sddm xdg-desktop-portal-kde
systemctl enable sddm.service

# Enable multilib only if needed (Steam or other 32-bit packages)
if printf '%s\n' "${PACMAN_INSTALL_LIST[@]}" | grep -qx "steam"; then
  echo "Enabling multilib for Steam..."
  sed -i '/^\[multilib\]/,/^Include/ s/^#//' /etc/pacman.conf
  pacman -Syy --noconfirm
fi

# Install pacman packages
for pkg in "${PACMAN_INSTALL_LIST[@]}"; do
  if pacman -Si "$pkg" &>/dev/null; then
    pacman -S --noconfirm "$pkg"
  else
    echo "WARNING: Package '$pkg' not found, skipping."
  fi
done

# Install AUR packages with paru (must be run as the user)
for pkg in "${PARU_INSTALL_LIST[@]}"; do
  if sudo -u "$USERNAME" paru -Si "$pkg" &>/dev/null; then
    sudo -u "$USERNAME" paru -S --noconfirm "$pkg" || echo "WARNING: Failed to install AUR package '$pkg'"
  else
    echo "WARNING: AUR package '$pkg' not found, skipping."
  fi
done

echo
echo "Installation complete. You are now inside the chroot environment."
echo "Type 'exit' when you are done."

exec /bin/bash
