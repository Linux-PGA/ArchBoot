#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ================================
# Arch TUI Installer (fixed)
# ================================

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

LOG="/var/log/arch-tui-installer.log"
exec &> >(tee -a "$LOG")

MNT="/mnt"

whiptail --title "Arch TUI Installer" --msgbox "Welcome to the fixed Arch TUI Installer\nAll actions are interactive and safe. Read prompts carefully." 12 70

die() { echo -e "${RED}ERROR:${RESET} $*" | tee -a "$LOG"; exit 1; }
msg() { echo -e "${YELLOW}$*${RESET}" | tee -a "$LOG"; }
success() { echo -e "${GREEN}$*${RESET}" | tee -a "$LOG"; }

menu() { whiptail --title "$1" --menu "$1" 20 70 10 "${@:2}" 3>&1 1>&2 2>&3; }
ask() { whiptail --title "Confirm" --yesno "$1" 10 70; return $?; }
input() { whiptail --title "Input" --inputbox "$1" 10 70 3>&1 1>&2 2>&3; }
password_input() { whiptail --title "Password" --passwordbox "$1" 10 70 3>&1 1>&2 2>&3; }

arch_chroot() { arch-chroot "$MNT" /bin/bash -lc "$*"; }

gauge_step() {
  local title="$1"; local message="$2"; local duration=${3:-3}
  (
    for i in $(seq 0 5 100); do
      echo $i
      sleep $(bc <<< "$duration*0.05")
    done
  ) | whiptail --title "$title" --gauge "$message" 10 70 0
}

# ----------------------
# Devices detection and selection
# ----------------------
msg "Detecting block devices..."
mapfile -t DEVICES < <(lsblk -dpno NAME,SIZE,TYPE | grep -E '/dev/(sd|nvme|mmcblk)' | awk '{print $1 " " $2 " " $3}')
DEVICE_LIST=()
# We'll populate menu with both disks and partitions, but tag type
for line in "${DEVICES[@]}"; do
  dev=$(awk '{print $1}' <<<"$line")
  size=$(awk '{print $2}' <<<"$line")
  type=$(awk '{print $3}' <<<"$line")
  label="${dev} (${size})"
  DEVICE_LIST+=("$dev" "$label")
done

if [ ${#DEVICE_LIST[@]} -eq 0 ]; then
  die "No block devices found."
fi

ROOT_SEL=$(menu "Select Disk or Partition for root" "${DEVICE_LIST[@]}") || die "Cancelled"
# Decide if selection is a whole disk or a partition
is_partition() {
  # returns 0 if partition, 1 if whole disk
  local d="$1"
  # partitions usually end with a number (sda1, nvme0n1p1)
  if [[ "$d" =~ [0-9]+$ ]]; then return 0; else return 1; fi
}

if is_partition "$ROOT_SEL"; then
  ROOT_PART="$ROOT_SEL"
  # derive disk
  DISK=$(echo "$ROOT_PART" | sed -E 's/p?[0-9]+$//')
  AUTO_PART="no"
else
  # selected a whole disk
  DISK="$ROOT_SEL"
  ROOT_PART=""
  AUTO_PART="ask"
fi

# EFI question
if ask "Will you use EFI on this VM? (If you enabled 'Enable EFI' in VirtualBox choose YES)"; then
  USE_EFI="yes"
else
  USE_EFI="no"
fi

# If user picked a whole disk, ask to auto-create partition(s)
if [[ "$AUTO_PART" == "ask" ]]; then
  if ask "You selected whole disk $DISK. Do you want the installer to create partitions automatically on this disk?"; then
    AUTO_PART="yes"
  else
    die "Please pre-create partitions and re-run installer."
  fi
fi

# Partition format decision
if ask "Format target partitions? WARNING: this will erase data on the selected partitions"; then
  DO_FORMAT="yes"
  FS_ROOT=$(menu "Filesystem for root" ext4 btrfs xfs) || die "Cancelled"
else
  DO_FORMAT="no"
  FS_ROOT=""
fi

# ----------------------
# Kernel & Bootloader
# ----------------------
KERNEL=$(menu "Select Kernel" linux linux-lts linux-zen) || die "Cancelled"

if [[ "$USE_EFI" == "yes" ]]; then
  BOOTLOADER=$(menu "Select Bootloader" systemd-boot grub) || die "Cancelled"
else
  msg "BIOS mode selected; using GRUB for BIOS installs."
  BOOTLOADER="grub"
fi

# ----------------------
# Desktop & Audio
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
  Hyprland "Hyprland" ) || DESKTOP="XFCE"

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
  *) DESKTOP_PKGS=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter); DISPLAY_MANAGER="lightdm" ;;
esac

if ask "Install PipeWire audio?"; then
  AUDIO_PKGS=(pipewire pipewire-alsa pipewire-pulse wireplumber)
else
  AUDIO_PKGS=()
fi

# ----------------------
# Optional Packages (checklist returns tags separated by space)
# ----------------------
OPTIONAL_RAW=$(whiptail --title "Optional Packages" --checklist \
"Select additional utilities to install (space to toggle)" 25 90 30 \
fastfetch "Fast system info" OFF \
htop "Interactive process viewer" OFF \
neofetch "System info tool" OFF \
wget "Download files" OFF \
curl "Data transfer" OFF \
git "Version control" OFF \
vim "Editor" OFF \
nano "Editor" OFF \
tmux "Terminal multiplexer" OFF \
btop "Resource monitor" OFF \
exa "Modern ls replacement" OFF \
bat "Cat with syntax highlight" OFF \
ripgrep "Search tool" OFF \
lazygit "Git UI" OFF \
paru "AUR helper" OFF \
fish "Alternative shell" OFF \
zsh "Alternative shell" OFF \
ncdu "Disk usage analyzer" OFF \
nmap "Network scanner" OFF \
aria2 "Download utility" OFF \
rsync "File sync tool" OFF \
unzip "Archive extraction" OFF \
tar "Archive tool" OFF \
zip "Archive tool" OFF \
gparted "Partition editor" OFF \
bleachbit "System cleanup" OFF \
docker "Container runtime" OFF \
docker-compose "Container tool" OFF 3>&1 1>&2 2>&3)

# Whiptail returns quoted tokens; convert to array safely
OPTIONAL_PKGS=()
if [[ -n "${OPTIONAL_RAW// }" ]]; then
  # turn into an array
  # e.g. OPTIONAL_RAW could be: "vim" "git"
  eval "OPTIONAL_PKGS=($OPTIONAL_RAW)"
fi

# ----------------------
# GPU detection
# ----------------------
NVIDIA_PRESENT=$(lspci -nn | grep -i -E 'nvidia|geforce' || true)
INSTALL_NVIDIA="no"
if [[ -n "$NVIDIA_PRESENT" ]]; then
  if ask "NVIDIA GPU detected in VM. Install proprietary drivers?"; then
    INSTALL_NVIDIA="yes"
  fi
fi

# ----------------------
# User & Hostname (hidden passwords)
# ----------------------
HOSTNAME=$(input "Enter hostname (e.g. arch-vbox):") || die "Cancelled"
USERNAME=$(input "Enter username:") || die "Cancelled"
ROOT_PASS=$(password_input "Enter root password (will be hidden):") || die "Cancelled"
USER_PASS=$(password_input "Enter $USERNAME password (will be hidden):") || die "Cancelled"
TIMEZONE=$(input "Enter timezone (e.g., UTC or Europe/Berlin):") || die "Cancelled"
LOCALE=$(input "Enter locale (e.g., en_US.UTF-8):") || die "Cancelled"

# ----------------------
# Final review
# ----------------------
REVIEW="Disk: $DISK
Root partition: ${ROOT_PART:-<will be created>}
EFI: ${USE_EFI}
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

ask "$REVIEW\n\nClick YES to Install Now (this will make changes to the selected disk/partition)" || die "Installation cancelled"

# ----------------------
# If auto partition is requested, create partitions non-interactively
# ----------------------
if [[ "$AUTO_PART" == "yes" ]]; then
  msg "Creating partition table and partitions on $DISK..."
  if [[ "$USE_EFI" == "yes" ]]; then
    # GPT + EFI
    parted -s "$DISK" mklabel gpt || die "Failed to create GPT label on $DISK"
    parted -s "$DISK" mkpart primary fat32 1MiB 551MiB || die "Failed to create EFI partition"
    parted -s "$DISK" set 1 esp on || true
    parted -s "$DISK" mkpart primary ext4 551MiB 100% || die "Failed to create root partition"
    # set device names (handle nvme p1 vs sda1)
    if [[ "$DISK" =~ nvme ]]; then
      EFI_PART="${DISK}p1"; ROOT_PART="${DISK}p2"
    else
      EFI_PART="${DISK}1"; ROOT_PART="${DISK}2"
    fi
  else
    # BIOS / dos label + single root partition
    parted -s "$DISK" mklabel msdos || die "Failed to create msdos label on $DISK"
    parted -s "$DISK" mkpart primary ext4 1MiB 100% || die "Failed to create root partition"
    if [[ "$DISK" =~ nvme ]]; then
      ROOT_PART="${DISK}p1"
    else
      ROOT_PART="${DISK}1"
    fi
    EFI_PART=""
  fi
  success "Partitions created: root=$ROOT_PART efi=${EFI_PART:-<none>}"
fi

# ----------------------
# Format partitions (if requested)
# ----------------------
if [[ "$DO_FORMAT" == "yes" ]]; then
  gauge_step "Formatting" "Formatting partitions..." 3
  case "$FS_ROOT" in
    ext4) mkfs.ext4 -F "$ROOT_PART" ;;
    btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
    xfs) mkfs.xfs -f "$ROOT_PART" ;;
    *) die "Unsupported filesystem: $FS_ROOT" ;;
  esac
  if [[ -n "${EFI_PART:-}" ]]; then
    mkfs.fat -F32 "$EFI_PART"
  fi
  success "Formatted partitions"
fi

# ----------------------
# Mount
# ----------------------
gauge_step "Mounting" "Mounting partitions..." 2
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT" || die "Failed to mount $ROOT_PART on $MNT"
if [[ -n "${EFI_PART:-}" ]]; then
  mkdir -p "$MNT/boot/efi"
  mount "$EFI_PART" "$MNT/boot/efi" || die "Failed to mount EFI partition"
fi
success "Mounted"

# ----------------------
# Install base system
# ----------------------
gauge_step "Base install" "Installing base system..." 10
BASE_PKGS=(base "$KERNEL" linux-firmware networkmanager sudo os-prober)
pacstrap "$MNT" "${BASE_PKGS[@]}" || die "pacstrap failed"
success "Base installed"

# ----------------------
# Generate fstab early
# ----------------------
genfstab -U "$MNT" >> "$MNT/etc/fstab"
success "fstab generated"

# ----------------------
# Install Desktop & Audio packages inside chroot
# ----------------------
gauge_step "Desktop" "Installing Desktop & Audio packages..." 10
if [ ${#DESKTOP_PKGS[@]} -ne 0 ] || [ ${#AUDIO_PKGS[@]} -ne 0 ]; then
  arch_chroot "pacman -Syu --noconfirm ${DESKTOP_PKGS[*]} ${AUDIO_PKGS[*]}"
fi
success "Desktop & audio packages installed"

# ----------------------
# Optional packages
# ----------------------
if [ ${#OPTIONAL_PKGS[@]} -ne 0 ]; then
  gauge_step "Optional" "Installing optional packages..." 5
  arch_chroot "pacman -S --noconfirm ${OPTIONAL_PKGS[*]}" || msg "Some optional packages may have failed to install"
  success "Optional packages done"
fi

# ----------------------
# Configure system
# ----------------------
gauge_step "Configure" "Configuring system..." 5
arch_chroot "echo $HOSTNAME > /etc/hostname"
arch_chroot "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc"
arch_chroot "echo '$LOCALE UTF-8' > /etc/locale.gen && locale-gen && echo LANG=$LOCALE > /etc/locale.conf"
arch_chroot "echo root:$ROOT_PASS | chpasswd"
arch_chroot "useradd -m -G wheel -s /bin/bash $USERNAME || true"
arch_chroot "echo $USERNAME:$USER_PASS | chpasswd"
arch_chroot "sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers || true"
arch_chroot "systemctl enable NetworkManager || true"
success "System configured"

# ----------------------
# NVIDIA drivers (if requested)
# ----------------------
if [[ "$INSTALL_NVIDIA" == "yes" ]]; then
  gauge_step "NVIDIA" "Installing NVIDIA drivers..." 5
  if [[ "$KERNEL" == "linux" ]]; then
    NVIDIA_PKG="nvidia"
  else
    NVIDIA_PKG="nvidia-dkms"
  fi
  arch_chroot "pacman -S --noconfirm $NVIDIA_PKG nvidia-utils nvidia-settings" || msg "NVIDIA install had issues"
  success "NVIDIA step done"
fi

# ----------------------
# Bootloader installation
# ----------------------
gauge_step "Bootloader" "Installing bootloader..." 6

# Map kernel package to correct vmlinuz/initramfs names
case "$KERNEL" in
  linux) KVER="linux" ;;
  linux-lts) KVER="linux-lts" ;;
  linux-zen) KVER="linux-zen" ;;
  *) KVER="$KERNEL" ;;
esac

if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  arch_chroot "bootctl --path=/boot/efi install || true"
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  # create loader entry (use single-quoted EOF to avoid interpolation issues)
  arch_chroot "mkdir -p /boot/efi/loader/entries"
  arch_chroot "cat > /boot/efi/loader/entries/arch.conf <<'EOF'
title   Arch Linux
linux   /vmlinuz-${KVER}
initrd  /initramfs-${KVER}.img
options root=UUID=${ROOT_UUID} rw
EOF"
  arch_chroot "echo 'default arch' > /boot/efi/loader/loader.conf"
  success "systemd-boot installed"
else
  # GRUB
  arch_chroot "pacman -S --noconfirm grub os-prober"
  if [[ "$USE_EFI" == "yes" ]]; then
    arch_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB || true"
  else
    # determine disk from ROOT_PART
    DISK_FOR_GRUB=$(echo "$ROOT_PART" | sed -E 's/p?[0-9]+$//')
    arch_chroot "grub-install --target=i386-pc --recheck $DISK_FOR_GRUB"
  fi
  arch_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
  success "GRUB installed"
fi

whiptail --title "Installation Complete" --msgbox "Installation finished!\n\nNext steps (in live environment):\n1) umount -R $MNT\n2) reboot\n\nLogin as root or $USERNAME after reboot." 15 70
success "All steps completed ✅"
