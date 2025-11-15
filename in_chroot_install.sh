#!/bin/bash
set -euo pipefail

echo -e "\n\nStarting chroot installation script...\n"

# Load config
set -a
source /config.conf
set +a

STEAM_DIR="/home/$USERNAME/.local/share/steam"
STEAM_SUBVOL_NAME="@steam"

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
HDD_MOUNT_OPTIONS="noatime,compress=zstd,space_cache=v2"
MOUNT_OPTIONS="$([[ "${SSD_DISK:-false}" == true ]] && echo "$SSD_MOUNT_OPTIONS" || echo "$HDD_MOUNT_OPTIONS")"

if [[ "${ENCRYPT_DISK:-false}" == true ]]; then
  ROOT_DEV="${MAIN_ENCRYPTED_PARTITION_DEV}"
else
  ROOT_DEV="${MAIN_PARTITION_DEV}"
fi


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
  ttf-firacode-nerd timeshift 


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
# Steam btrfs subvolume
# -----------------------------
if [[ "$INSTALL_STEAM" == true ]]; then
  echo "Creating Steam Btrfs subvolume..."

  # mount the top-level subvolume (real root)
  mkdir -p /mnt/btrfs-root
  mount -o subvol=/ "$ROOT_DEV" /mnt/btrfs-root

  # create @steam inside the real btrfs root
  btrfs subvolume create "/mnt/btrfs-root/$STEAM_SUBVOL_NAME"

  # unmount top-level root
  umount /mnt/btrfs-root

  # ensure user steam directory exists inside mounted @
  mkdir -p "$STEAM_DIR"

  # get UUID of root btrfs filesystem
  BTRFS_UUID=$(findmnt -no UUID /)

  # add to fstab using subvol name (not subvolid)
  echo "UUID=$BTRFS_UUID  $STEAM_DIR  btrfs  subvol=$STEAM_SUBVOL_NAME,$MOUNT_OPTIONS 0 0" >> /etc/fstab

  # reload fstab
  systemctl daemon-reload

  # mount it
  mount "$STEAM_DIR"
fi

# -----------------------------
# Desktop Environment
# -----------------------------
case "$DESKTOP_ENV" in
  kde)
    pacman -S --noconfirm plasma-meta sddm xdg-desktop-portal-kde
    systemctl enable sddm.service
    ;;
  gnome)
    pacman -S --noconfirm gnome gnome-extra
    systemctl enable gdm.service
    ;;
  cinnamon)
    pacman -S --noconfirm cinnamon lightdm lightdm-gtk-greeter
    systemctl enable lightdm.service
    ;;
  *)
    echo "WARNING: Unknown desktop environment '$DESKTOP_ENV' – skipping desktop environment installation"
    ;;
esac


# -----------------------------
# Enable multilib and steam
# -----------------------------

# Enable multilib only if needed (Steam or other 32-bit packages)
if [[ "$INSTALL_STEAM" == true ]]; then
  echo "Enabling multilib for Steam..."
  sed -i '/\[multilib\]/,/Include/ s/^[[:space:]]*#//g' /etc/pacman.conf
  pacman -Syy --noconfirm

  case "$GPU" in
    amd)
      pacman -S --noconfirm vulkan-radeon lib32-vulkan-radeon steam
      ;;
    intel)
      pacman -S --noconfirm vulkan-intel lib32-vulkan-intel steam
      ;;
    nvidia)
      pacman -S --noconfirm nvidia-utils lib32-nvidia-utils steam
      ;;
    *)
      echo "WARNING: Unknown GPU '$GPU' – skipping Vulkan drivers"
      ;;
  esac
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
