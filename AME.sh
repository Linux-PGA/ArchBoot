#!/usr/bin/env bash
set -euo pipefail

# ================================
# Arch TUI Installer with Optional Packages
# ================================

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

LOG="/var/log/arch-tui-installer.log"
exec &> >(tee -a "$LOG")

MNT="/mnt"

whiptail --title "Arch TUI Installer" --msgbox "Welcome to Arch TUI Installer\nAll actions are interactive and safe." 12 60

# ----------------------
# Helper functions
# ----------------------
die() { echo -e "${RED}ERROR:${RESET} $*" | tee -a "$LOG"; exit 1; }
msg() { echo -e "${YELLOW}$*${RESET}" | tee -a "$LOG"; }
success() { echo -e "${GREEN}$*${RESET}" | tee -a "$LOG"; }

menu() { whiptail --title "$1" --menu "$1" 20 70 10 "${@:2}" 3>&1 1>&2 2>&3; }
ask() { whiptail --title "Confirm" --yesno "$1" 10 60; }
input() { whiptail --title "Input" --inputbox "$1" 10 60 3>&1 1>&2 2>&3; }
arch_chroot() { arch-chroot "$MNT" /bin/bash -c "$*"; }

gauge_step() {
  local title="$1"
  local message="$2"
  local duration=${3:-3}
  (
    for i in $(seq 0 5 100); do
      echo $i
      sleep $(bc <<< "$duration*0.05")
    done
  ) | whiptail --title "$title" --gauge "$message" 10 70 0
}

# ----------------------
# Step 1: Partition selection
# ----------------------
msg "Detecting block devices..."
DEVICES=($(lsblk -dpno NAME | grep -E '/dev/(sd|nvme|mmcblk)'))
DEVICE_LIST=()
for d in "${DEVICES[@]}"; do
  SIZE=$(lsblk -dn -o SIZE "$d")
  DEVICE_LIST+=("$d" "$SIZE")
done

ROOT_PART=$(menu "Select Root Partition" "${DEVICE_LIST[@]}") || die "Cancelled"
if ask "EFI partition present?"; then
  EFI_PART=$(menu "Select EFI Partition" "${DEVICE_LIST[@]}") || die "Cancelled"
  USE_EFI="yes"
else
  EFI_PART=""
  USE_EFI="no"
fi

if ask "Format partitions? WARNING: this will erase data"; then
  DO_FORMAT="yes"
  FS_ROOT=$(menu "Filesystem for root" ext4 btrfs xfs)
  [[ "$USE_EFI" == "yes" ]] && msg "EFI will be formatted as FAT32"
else
  DO_FORMAT="no"
fi

# ----------------------
# Step 2: Kernel & Bootloader
# ----------------------
KERNEL=$(menu "Select Kernel" linux linux-lts linux-zen)
if [[ "$USE_EFI" == "yes" ]]; then
  BOOTLOADER=$(menu "Select Bootloader" systemd-boot grub)
else
  msg "BIOS mode detected, using GRUB"
  BOOTLOADER="grub"
fi

# ----------------------
# Step 3: Desktop & Audio
# ----------------------
DESKTOP=$(menu "Choose Desktop Environment" \
  KDE "Plasma + KDE Apps" \
  GNOME "GNOME Shell" \
  XFCE "XFCE Lightweight" \
  Cinnamon "Cinnamon Desktop" \
  LXQt "LXQt Desktop" \
  MATE "MATE Desktop" \
  i3 "i3 Tiling WM" \
  Sway "Sway Wayland WM" \
  Hyprland "Hyprland Wayland Compositor")

declare -a DESKTOP_PKGS
DISPLAY_MANAGER=""
case "$DESKTOP" in
  KDE) DESKTOP_PKGS=(plasma kde-applications sddm); DISPLAY_MANAGER="sddm" ;;
  GNOME) DESKTOP_PKGS=(gnome gnome-extra gdm); DISPLAY_MANAGER="gdm" ;;
  XFCE) DESKTOP_PKGS=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter); DISPLAY_MANAGER="lightdm" ;;
  Cinnamon) DESKTOP_PKGS=(cinnamon lightdm lightdm-gtk-greeter); DISPLAY_MANAGER="lightdm" ;;
  LXQt) DESKTOP_PKGS=(lxqt lightdm lightdm-gtk-greeter); DISPLAY_MANAGER="lightdm" ;;
  MATE) DESKTOP_PKGS=(mate mate-extra lightdm lightdm-gtk-greeter); DISPLAY_MANAGER="lightdm" ;;
  i3) DESKTOP_PKGS=(i3-wm i3status dmenu xorg xorg-server lightdm lightdm-gtk-greeter); DISPLAY_MANAGER="lightdm" ;;
  Sway) DESKTOP_PKGS=(sway wlroots wayland xorg-xwayland waybar mako swaybg lightdm lightdm-gtk-greeter); DISPLAY_MANAGER="lightdm" ;;
  Hyprland) DESKTOP_PKGS=(hyprland wayland xorg-xwayland waybar swaybg mako lightdm lightdm-gtk-greeter); DISPLAY_MANAGER="lightdm" ;;
  *) DESKTOP_PKGS=(plasma kde-applications sddm); DISPLAY_MANAGER="sddm" ;;
esac

if ask "Install PipeWire audio?"; then
  AUDIO_PKGS=(pipewire pipewire-alsa pipewire-pulse wireplumber)
else
  AUDIO_PKGS=()
fi

# ----------------------
# Step 4: Optional Packages
# ----------------------
OPTIONAL_PKGS=$(whiptail --title "Optional Packages" --checklist \
"Select additional utilities to install" 25 90 30 \
"fastfetch" "Fast system info" OFF \
"htop" "Interactive process viewer" OFF \
"neofetch" "System info tool" OFF \
"wget" "Download files" OFF \
"curl" "Data transfer" OFF \
"git" "Version control" OFF \
"vim" "Editor" OFF \
"nano" "Editor" OFF \
"tmux" "Terminal multiplexer" OFF \
"screenfetch" "System info" OFF \
"btop" "Resource monitor" OFF \
"exa" "Modern ls replacement" OFF \
"bat" "Cat with syntax highlight" OFF \
"ripgrep" "Search tool" OFF \
"lazygit" "Git UI" OFF \
"paru" "AUR helper" OFF \
"fish" "Alternative shell" OFF \
"zsh" "Alternative shell" OFF \
"ncdu" "Disk usage analyzer" OFF \
"nmap" "Network scanner" OFF \
"aria2" "Download utility" OFF \
"rsync" "File sync tool" OFF \
"unzip" "Archive extraction" OFF \
"tar" "Archive tool" OFF \
"zip" "Archive tool" OFF \
"gparted" "Partition editor" OFF \
"bleachbit" "System cleanup" OFF \
"docker" "Container runtime" OFF \
"docker-compose" "Container tool" OFF 3>&1 1>&2 2>&3)

# ----------------------
# Step 5: GPU detection
# ----------------------
NVIDIA_PRESENT=$(lspci -nn | grep -i -E 'nvidia|geforce' || true)
if [[ -n "$NVIDIA_PRESENT" ]]; then
  INSTALL_NVIDIA="no"
  ask "NVIDIA GPU detected. Install proprietary drivers?" && INSTALL_NVIDIA="yes"
else
  INSTALL_NVIDIA="no"
fi

# ----------------------
# Step 6: User & Hostname
# ----------------------
HOSTNAME=$(input "Enter hostname:")
USERNAME=$(input "Enter username:")
ROOT_PASS=$(input "Enter root password (hidden):")
USER_PASS=$(input "Enter password for $USERNAME (hidden):")
TIMEZONE=$(input "Enter timezone (UTC, Europe/Berlin, etc):")
LOCALE=$(input "Enter locale (e.g., en_US.UTF-8):")

# ----------------------
# Step 7: Final Review
# ----------------------
REVIEW="Root: $ROOT_PART
EFI: ${EFI_PART:-<none>}
Format: $DO_FORMAT
Filesystem: ${FS_ROOT:-<existing>}
Kernel: $KERNEL
Bootloader: $BOOTLOADER
Desktop: $DESKTOP
Desktop pkgs: ${DESKTOP_PKGS[*]}
Audio pkgs: ${AUDIO_PKGS[*]:-none}
Optional packages: ${OPTIONAL_PKGS[*]:-none}
NVIDIA driver: $INSTALL_NVIDIA
User: $USERNAME
Hostname: $HOSTNAME
Timezone: $TIMEZONE
Locale: $LOCALE"

ask "$REVIEW\n\nClick YES to Install Now" || die "Installation cancelled"

# ----------------------
# Step 8: Installation with gauges
# ----------------------
[[ "$DO_FORMAT" == "yes" ]] && { gauge_step "Step 1/8" "Formatting partitions..." 3; case "$FS_ROOT" in ext4) mkfs.ext4 -F "$ROOT_PART";; btrfs) mkfs.btrfs -f "$ROOT_PART";; xfs) mkfs.xfs -f "$ROOT_PART";; esac; [[ "$USE_EFI" == "yes" ]] && mkfs.fat -F32 "$EFI_PART"; success "Partitions formatted ✅"; }

gauge_step "Step 2/8" "Mounting partitions..." 2
mount "$ROOT_PART" "$MNT"
[[ -n "$EFI_PART" ]] && { mkdir -p "$MNT/boot/efi"; mount "$EFI_PART" "$MNT/boot/efi"; }
success "Partitions mounted ✅"

gauge_step "Step 3/8" "Installing base system..." 10
BASE_PKGS=(base "$KERNEL" linux-firmware networkmanager sudo os-prober)
pacstrap "$MNT" "${BASE_PKGS[@]}"
success "Base system installed ✅"

gauge_step "Step 4/8" "Installing Desktop & Audio packages..." 10
arch_chroot "pacman -S --noconfirm ${DESKTOP_PKGS[*]} ${AUDIO_PKGS[*]}"
genfstab -U "$MNT" >> "$MNT/etc/fstab"
success "Desktop & Audio installed ✅"

gauge_step "Step 5/8" "Installing Optional Packages..." 8
[[ -n "$OPTIONAL_PKGS" ]] && arch_chroot "pacman -S --noconfirm ${OPTIONAL_PKGS[@]}"
success "Optional packages installed ✅"

gauge_step "Step 6/8" "Configuring system..." 5
arch_chroot "echo $HOSTNAME > /etc/hostname"
arch_chroot "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc"
arch_chroot "echo '$LOCALE UTF-8' > /etc/locale.gen && locale-gen && echo LANG=$LOCALE > /etc/locale.conf"
arch_chroot "echo root:$ROOT_PASS | chpasswd"
arch_chroot "useradd -m -G wheel -s /bin/bash $USERNAME && echo $USERNAME:$USER_PASS | chpasswd && sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers || true"
arch_chroot "systemctl enable NetworkManager"
success "System configured ✅"

[[ "$INSTALL_NVIDIA" == "yes" ]] && { gauge_step "Step 7/8" "Installing NVIDIA drivers..." 5; [[ "$KERNEL" == "linux" ]] && NVIDIA_PKG="nvidia" || NVIDIA_PKG="nvidia-dkms"; arch_chroot "pacman -S --noconfirm $NVIDIA_PKG nvidia-utils nvidia-settings"; success "NVIDIA drivers installed ✅"; }

gauge_step "Step 8/8" "Installing bootloader..." 5
if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  arch_chroot "bootctl install || true"
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  arch_chroot "mkdir -p /boot/efi/loader/entries"
  arch_chroot "cat >/boot/efi/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-$KERNEL
initrd  /initramfs-$KERNEL.img
options root=UUID=$ROOT_UUID rw
EOF"
  arch_chroot "echo 'default arch' > /boot/efi/loader/loader.conf"
  success "systemd-boot installed ✅"
else
  DISK=$(echo "$ROOT_PART" | sed -E 's/p?[0-9]+$//')
  arch_chroot "pacman -S --noconfirm grub os-prober"
  [[ "$USE_EFI" == "yes" ]] && arch_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB || true" || arch_chroot "grub-install --target=i386-pc --recheck $DISK"
  arch_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
  success "GRUB installed ✅"
fi

whiptail --title "Installation Complete" --msgbox "Installation finished!\n\nNext steps:\n1) umount -R $MNT\n2) reboot\n\nLogin as root or $USERNAME\n" 15 70
success "All steps completed ✅"
