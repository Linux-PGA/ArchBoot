#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Arch TUI Installer - Final fixed script (with kernel header fix for DKMS)
# Usage: Save to /root/install-vm-final.sh on Arch live ISO, run: bash /root/install-vm-final.sh

GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"
LOG="/var/log/arch-tui-installer.log"
exec &> >(tee -a "$LOG")

MNT="/mnt"

whiptail --title "Arch TUI Installer (final)" --msgbox "Welcome — read prompts carefully. This script auto-detects EFI and virtualization and will confirm before formatting." 12 70

die(){ echo -e "${RED}ERROR:${RESET} $*" | tee -a "$LOG"; exit 1; }
msg(){ echo -e "${YELLOW}$*${RESET}" | tee -a "$LOG"; }
success(){ echo -e "${GREEN}$*${RESET}" | tee -a "$LOG"; }

menu(){ whiptail --title "$1" --menu "$1" 20 76 12 "${@:2}" 3>&1 1>&2 2>&3; }
ask(){ whiptail --title "Confirm" --yesno "$1" 10 70; return $?; }
input(){ whiptail --title "Input" --inputbox "$1" 10 70 3>&1 1>&2 2>&3; }
password_input(){ whiptail --title "Password" --passwordbox "$1" 10 70 3>&1 1>&2 2>&3; }
arch_chroot(){ arch-chroot "$MNT" /bin/bash -lc "$*"; }

gauge_step(){
  local title="$1"; local message="$2"; local duration=${3:-3}
  (
    for i in $(seq 0 5 100); do
      echo $i
      sleep $(bc <<< "$duration*0.05")
    done
  ) | whiptail --title "$title" --gauge "$message" 10 70 0
}

# ----------------------
# Detect EFI, virtualization
# ----------------------
if [ -d /sys/firmware/efi ]; then DETECTED_EFI="yes"; else DETECTED_EFI="no"; fi
msg "EFI detected by live environment: $DETECTED_EFI"

VIRT="$(systemd-detect-virt || true)"
if [[ -z "$VIRT" ]]; then VIRT="none"; fi
msg "Virtualization detected: $VIRT"

# ----------------------
# Device listing (safe, no awk quoting issues)
# ----------------------
msg "Detecting block devices..."
# produce pairs: tag description
DEVICE_PAIRS=()
# Use lsblk columns: NAME SIZE TYPE MODEL (MODEL may contain spaces)
while read -r name size type model_rest; do
  # In case model_rest is empty: keep it simple
  desc="${name} (${size}) ${type} ${model_rest}"
  DEVICE_PAIRS+=("$name" "$desc")
done < <(lsblk -dpno NAME,SIZE,TYPE,MODEL | grep -E '/dev/(sd|nvme|mmcblk)' || true)

if [ ${#DEVICE_PAIRS[@]} -eq 0 ]; then
  die "No block devices found."
fi

ROOT_SEL=$(menu "Select disk or partition to use for root (select whole disk to auto-partition)" "${DEVICE_PAIRS[@]}") || die "Cancelled"

# helper: whether selection is a partition (ends with a digit)
is_partition(){ [[ "$1" =~ [0-9]+$ ]]; }

if is_partition "$ROOT_SEL"; then
  ROOT_PART="$ROOT_SEL"
  DISK=$(echo "$ROOT_PART" | sed -E 's/p?[0-9]+$//')
  AUTO_PART="no"
else
  DISK="$ROOT_SEL"
  ROOT_PART=""
  AUTO_PART="ask"
fi

# Ask about EFI preference (show detection)
if ask "Do you want to use EFI mode? (If you enabled 'Enable EFI' in VirtualBox choose YES)\nDetected EFI by live system: $DETECTED_EFI"; then
  USE_EFI="yes"
else
  USE_EFI="no"
fi

# If whole disk chosen ask whether to auto-partition
if [[ "$AUTO_PART" == "ask" ]]; then
  if ask "You selected whole disk $DISK. Create partitions automatically on this disk now?"; then
    AUTO_PART="yes"
  else
    die "Please pre-create partitions and re-run installer."
  fi
fi

# Format decision (fixed whiptail menu entries)
if ask "Format target partitions? WARNING: this will erase data on selected partitions"; then
  DO_FORMAT="yes"
  FS_ROOT=$(menu "Filesystem for root" \
    ext4 "EXT4 filesystem (recommended)" \
    btrfs "BTRFS filesystem (advanced)" \
    xfs "XFS filesystem") || die "Cancelled"
else
  DO_FORMAT="no"
  FS_ROOT=""
fi

# Kernel and bootloader choices
KERNEL=$(menu "Select Kernel package" \
  linux "linux (mainline)" \
  linux-lts "linux-lts (LTS kernel)" \
  linux-zen "linux-zen (Zen kernel)") || die "Cancelled"

# Bootloader: offer systemd-boot only if EFI requested
if [[ "$USE_EFI" == "yes" ]]; then
  BOOTLOADER=$(menu "Select Bootloader" systemd-boot "systemd-boot (EFI simple)" grub "GRUB (works BIOS+EFI)") || die "Cancelled"
else
  BOOTLOADER="grub"
  msg "BIOS/Legacy selected; using GRUB."
fi

# Desktop selection
DESKTOP=$(menu "Choose Desktop Environment" \
  KDE "Plasma + KDE Apps" \
  GNOME "GNOME Shell" \
  XFCE "XFCE Lightweight" \
  Cinnamon "Cinnamon Desktop" \
  LXQt "LXQt Desktop" \
  MATE "MATE Desktop" \
  i3 "i3 Tiling WM" \
  Sway "Sway Wayland WM" \
  Hyprland "Hyprland Wayland Compositor") || DESKTOP="XFCE"

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

# Optional packages (checklist)
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

OPTIONAL_PKGS=()
# Safer way to parse whiptail checklist output
if [[ -n "${OPTIONAL_RAW// }" ]]; then
  # Remove surrounding quotes, then read into array
  read -r -a OPTIONAL_PKGS <<< "${OPTIONAL_RAW//\"/}"
fi

# GPU detection and user info
NVIDIA_PRESENT=$(lspci -nn | grep -i -E 'nvidia|geforce' || true)
INSTALL_NVIDIA="no"
if [[ -n "$NVIDIA_PRESENT" ]]; then
  if ask "NVIDIA GPU detected. Install proprietary drivers?"; then INSTALL_NVIDIA="yes"; fi
fi

HOSTNAME=$(input "Enter hostname (e.g. arch-vm):") || die "Cancelled"
USERNAME=$(input "Enter username:") || die "Cancelled"
ROOT_PASS=$(password_input "Enter root password (hidden):") || die "Cancelled"
USER_PASS=$(password_input "Enter password for $USERNAME (hidden):") || die "Cancelled"
TIMEZONE=$(input "Enter timezone (e.g. UTC or Europe/Berlin):") || die "Cancelled"
LOCALE=$(input "Enter locale (e.g. en_US.UTF-8):") || die "Cancelled"

REVIEW="Disk: $DISK
Root partition: ${ROOT_PART:-<will be created>}
EFI requested: $USE_EFI
Format: $DO_FORMAT
Filesystem: ${FS_ROOT:-<existing>}
Kernel: $KERNEL
Bootloader: $BOOTLOADER
Desktop: $DESKTOP
Desktop pkgs: ${DESKTOP_PKGS[*]}
Audio pkgs: ${AUDIO_PKGS[*]:-none}
Optional packages: ${OPTIONAL_PKGS[*]:-none}
NVIDIA driver: $INSTALL_NVIDIA
Virtualization: $VIRT
User: $USERNAME
Hostname: $HOSTNAME
Timezone: $TIMEZONE
Locale: $LOCALE"

ask "$REVIEW\n\nClick YES to Install Now (this will make changes to the selected disk/partition)" || die "Installation cancelled"

# ----------------------
# Auto partition if requested
# ----------------------
if [[ "$AUTO_PART" == "yes" ]]; then
  msg "Auto-creating partitions on $DISK..."
  if [[ "$USE_EFI" == "yes" ]]; then
    parted -s "$DISK" mklabel gpt || die "Failed to create GPT label"
    parted -s "$DISK" mkpart primary fat32 1MiB 551MiB || die "Failed to create EFI partition"
    parted -s "$DISK" set 1 esp on || true
    parted -s "$DISK" mkpart primary ext4 551MiB 100% || die "Failed to create root partition"
    if [[ "$DISK" =~ nvme ]]; then
      EFI_PART="${DISK}p1"; ROOT_PART="${DISK}p2"
    else
      EFI_PART="${DISK}1"; ROOT_PART="${DISK}2"
    fi
  else
    parted -s "$DISK" mklabel msdos || die "Failed to create msdos label"
    parted -s "$DISK" mkpart primary ext4 1MiB 100% || die "Failed to create root partition"
    if [[ "$DISK" =~ nvme ]]; then ROOT_PART="${DISK}p1"; else ROOT_PART="${DISK}1"; fi
    EFI_PART=""
  fi
  success "Created partitions: root=${ROOT_PART} efi=${EFI_PART:-<none>}"
fi

# sanity
if [[ -z "${ROOT_PART:-}" ]]; then die "No root partition selected or created."; fi

# final format confirmation
if [[ "$DO_FORMAT" == "yes" ]]; then
  if ! ask "About to format $ROOT_PART ${EFI_PART:+and $EFI_PART}. This will erase data. Are you 100% sure?"; then die "User aborted before formatting."; fi
fi

# format partitions
if [[ "$DO_FORMAT" == "yes" ]]; then
  gauge_step "Formatting" "Formatting partitions..." 3
  case "$FS_ROOT" in
    ext4) mkfs.ext4 -F "$ROOT_PART" ;;
    btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
    xfs) mkfs.xfs -f "$ROOT_PART" ;;
    *) die "Unsupported filesystem: $FS_ROOT" ;;
  esac
  if [[ -n "${EFI_PART:-}" ]]; then mkfs.fat -F32 "$EFI_PART"; fi
  success "Formatting complete"
fi

# mount
gauge_step "Mounting" "Mounting partitions..." 2
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT" || die "Failed to mount $ROOT_PART -> $MNT"
if [[ -n "${EFI_PART:-}" ]]; then mkdir -p "$MNT/boot/efi"; mount "$EFI_PART" "$MNT/boot/efi" || die "Failed to mount EFI partition"; fi
success "Mounted partitions"

# install base
gauge_step "Base install" "Installing base system (pacstrap)..." 10

# --- FIX: Dynamically determine and install kernel headers for DKMS/VM tools ---
case "$KERNEL" in
  linux) HDR_PKG="linux-headers" ;;
  linux-lts) HDR_PKG="linux-lts-headers" ;;
  linux-zen) HDR_PKG="linux-zen-headers" ;;
  *) HDR_PKG="${KERNEL}-headers" ;;
esac

# Add kernel headers to ensure DKMS (NVIDIA, VBox) works
BASE_PKGS=(base "$KERNEL" "$HDR_PKG" linux-firmware networkmanager sudo os-prober)

pacstrap "$MNT" "${BASE_PKGS[@]}" || die "pacstrap failed"
genfstab -U "$MNT" >> "$MNT/etc/fstab"
success "Base and fstab created"

# install desktop, audio, optional packages
gauge_step "Packages" "Installing desktop & selected packages..." 10
if [ ${#DESKTOP_PKGS[@]} -ne 0 ] || [ ${#AUDIO_PKGS[@]} -ne 0 ]; then
  arch_chroot "pacman -Syu --noconfirm ${DESKTOP_PKGS[*]} ${AUDIO_PKGS[*]}"
fi
if [ ${#OPTIONAL_PKGS[@]} -ne 0 ]; then
  # Use -S, not -Syu, to install optional packages only
  arch_chroot "pacman -S --noconfirm ${OPTIONAL_PKGS[*]}" || msg "Some optional packages failed"
fi
success "Packages installed"

# configure system
gauge_step "Configure" "Applying system configuration..." 5
arch_chroot "echo $HOSTNAME > /etc/hostname"
arch_chroot "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc"
arch_chroot "echo '$LOCALE UTF-8' > /etc/locale.gen && locale-gen && echo LANG=$LOCALE > /etc/locale.conf"
arch_chroot "echo root:$ROOT_PASS | chpasswd"
arch_chroot "useradd -m -G wheel -s /bin/bash $USERNAME || true"
arch_chroot "echo $USERNAME:$USER_PASS | chpasswd"
arch_chroot "sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers || true"
arch_chroot "systemctl enable NetworkManager || true"
success "System configured"

# NVIDIA drivers if desired
if [[ "$INSTALL_NVIDIA" == "yes" ]]; then
  gauge_step "NVIDIA" "Installing NVIDIA drivers..." 5
  # Use nvidia-dkms since kernel headers are now guaranteed to be installed
  NVIDIA_PKG="nvidia-dkms" 
  arch_chroot "pacman -S --noconfirm $NVIDIA_PKG nvidia-utils nvidia-settings" || msg "NVIDIA install had issues"
  success "NVIDIA handled"
fi

# VM guest tools (based on systemd-detect-virt)
gauge_step "VM Tools" "Installing VM guest tools if detected..." 3
VIRT_LOWER=$(echo "$VIRT" | tr '[:upper:]' '[:lower:]')
VM_PKGS=()
VM_ENABLE_CMDS=()

# The kernel header package is no longer needed here, as it was added to BASE_PKGS
if [[ "$VIRT_LOWER" == "oracle" || "$VIRT_LOWER" == "virtualbox" ]]; then
  VM_PKGS+=(virtualbox-guest-dkms dkms virtualbox-guest-utils)
  VM_ENABLE_CMDS+=( "systemctl enable vboxservice" )
elif [[ "$VIRT_LOWER" == "vmware" ]]; then
  VM_PKGS+=(open-vm-tools)
  VM_ENABLE_CMDS+=( "systemctl enable --now vmtoolsd" )
elif [[ "$VIRT_LOWER" == "kvm" || "$VIRT_LOWER" == "kvmqemu" || "$VIRT_LOWER" == "qemu" ]]; then
  VM_PKGS+=(qemu-guest-agent)
  VM_ENABLE_CMDS+=( "systemctl enable --now qemu-guest-agent" )
elif [[ "$VIRT_LOWER" == "microsoft" || "$VIRT_LOWER" == "hyperv" ]]; then
  VM_PKGS+=(hyperv-daemons)
  VM_ENABLE_CMDS+=( "systemctl enable --now hv-fcopy-daemon || true" )
fi

# install VM pkgs if any (clean empty tokens)
if [ ${#VM_PKGS[@]} -ne 0 ]; then
  CLEAN_VM_PKGS=()
  for p in "${VM_PKGS[@]}"; do
    [[ -n "$p" ]] && CLEAN_VM_PKGS+=("$p")
  done
  if [ ${#CLEAN_VM_PKGS[@]} -ne 0 ]; then
    arch_chroot "pacman -S --noconfirm ${CLEAN_VM_PKGS[*]}" || msg "VM guest tools install had issues"
    for cmd in "${VM_ENABLE_CMDS[@]}"; do arch_chroot "$cmd" || true; done
    success "VM guest tools installed (if available in repos)"
  fi
else
  msg "No VM guest tools required for $VIRT"
fi

# bootloader installation
gauge_step "Bootloader" "Installing bootloader..." 6
case "$KERNEL" in linux) KVER="linux" ;; linux-lts) KVER="linux-lts" ;; linux-zen) KVER="linux-zen" ;; *) KVER="$KERNEL" ;; esac

if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  arch_chroot "bootctl --path=/boot/efi install || true"
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  arch_chroot "mkdir -p /boot/efi/loader/entries"
  arch_chroot "cat >/boot/efi/loader/entries/arch.conf <<'EOF'
title   Arch Linux
linux   /vmlinuz-${KVER}
initrd  /initramfs-${KVER}.img
options root=UUID=${ROOT_UUID} rw
EOF"
  arch_chroot "echo 'default arch' > /boot/efi/loader/loader.conf"
  success "systemd-boot installed"
else
  # Removed redundant os-prober package install here (already in BASE_PKGS)
  arch_chroot "pacman -S --noconfirm grub"
  if [[ "$USE_EFI" == "yes" ]]; then
    arch_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck || true"
  else
    DISK_FOR_GRUB=$(echo "$ROOT_PART" | sed -E 's/p?[0-9]+$//')
    arch_chroot "grub-install --target=i386-pc --recheck $DISK_FOR_GRUB || true"
  fi
  arch_chroot "grub-mkconfig -o /boot/grub/grub.cfg || true"
  success "GRUB installed"
fi

# Enable display manager
if [[ -n "$DISPLAY_MANAGER" ]]; then
  arch_chroot "systemctl enable $DISPLAY_MANAGER" || msg "Failed to enable display manager $DISPLAY_MANAGER"
fi

whiptail --title "Done" --msgbox "Installation finished!\n\nNext steps (in live environment):\n1) umount -R $MNT\n2) reboot\n\nLogin as root or $USERNAME after reboot." 15 70

success "All steps completed ✅"
