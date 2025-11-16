#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Arch TUI Installer - FINAL FIX: Reliable User Input for Partitions (BIOS/Legacy Mode)
# ASSUMPTION: You have manually partitioned the disk and are booting in BIOS mode.

GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"
LOG="/var/log/arch-tui-installer.log"
exec &> >(tee -a "$LOG")

MNT="/mnt"

whiptail --title "Arch TUI Installer (Final Stable)" --msgbox "Welcome. This version uses text input for partition paths to ensure stability in your VM." 12 70

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
# Helper function to wait for new partitions to appear (FIX for VM stability)
# ----------------------
wait_for_device() {
    local device=$1
    local max_attempts=15
    local attempt=0
    
    if [ ! -b "$device" ]; then
      msg "Waiting for partition device $device to appear..."
      while [ ! -b "$device" ] && [ $attempt -lt $max_attempts ]; do
          partprobe "$DISK" 2>/dev/null || true
          sleep 1
          attempt=$((attempt + 1))
      done
      if [ ! -b "$device" ]; then
          die "Error: Partition device $device did not appear after $max_attempts seconds. Cannot continue."
      fi
      success "Device $device appeared."
    fi
}

# ----------------------
# Detect EFI, virtualization (Standard detection, not modified)
# ----------------------
if [ -d /sys/firmware/efi ]; then DETECTED_EFI="yes"; else DETECTED_EFI="no"; fi
msg "EFI detected by live environment: $DETECTED_EFI"

VIRT="$(systemd-detect-virt || true)"
if [[ -z "$VIRT" ]]; then VIRT="none"; fi
msg "Virtualization detected: $VIRT"

# ----------------------
# DEVICE SELECTION AND PARTITIONING FIX: Using direct input to bypass broken TUI menu
# ----------------------
msg "Using text input for partition paths to ensure stability."

# 1. Ask for the root partition directly via text input
ROOT_PART=$(input "Enter the full path to your ROOT partition (e.g., /dev/sda2):") || die "Cancelled"

# 2. Ask if the user wants to enable swap
if ask "Do you have a separate SWAP partition that you want to enable? (Recommended)"; then
  SWAP_PART=$(input "Enter the full path to your SWAP partition (e.g., /dev/sda1):") || msg "No SWAP partition entered."
else
  SWAP_PART=""
fi

# Derive other variables
DISK=$(echo "$ROOT_PART" | sed -E 's/p?[0-9]+$//')
AUTO_PART="no" 

# New: Enable swap now so genfstab includes it (and confirms it exists)
if [[ -n "$SWAP_PART" ]]; then
    msg "Attempting to enable swap on $SWAP_PART..."
    mkswap "$SWAP_PART" 2>/dev/null || true # Format as swap (ignore error if already formatted)
    swapon "$SWAP_PART" || msg "Failed to activate swap on $SWAP_PART. Continuing."
fi

# 3. EFI/Boot Partition Question (Now an ask() prompt)
if ask "Do you need a separate EFI/Boot partition? Choose NO for BIOS/Legacy Mode (recommended for your setup)."; then
  USE_EFI="yes"
  EFI_PART=$(input "Enter the full path to your EFI partition (e.g., /dev/sda1):") || die "Cancelled"
else
  USE_EFI="no" # Confirms BIOS/Legacy setup
  EFI_PART=""
fi

# The original TUI menu call and subsequent partition logic are removed here.
# AUTO_PART is now permanently "no"

# --- Format decision ---
if ask "Format target partitions? WARNING: this will erase data on $ROOT_PART ${EFI_PART:+and $EFI_PART}"; then
  DO_FORMAT="yes"
FS_ROOT=$(menu "Filesystem for root" \
    ext4 "EXT4 filesystem (recommended)" \
    btrfs "BTRFS filesystem (advanced)" \
    xfs "XFS filesystem") || die "Cancelled"
else
  DO_FORMAT="no"
  FS_ROOT="ext4" # Default to ext4 to avoid issues if DO_FORMAT="no"
fi

# Kernel and bootloader choices
KERNEL=$(menu "Select Kernel package" \
  linux "linux (mainline)" \
  linux-lts "linux-lts (LTS kernel)" \
  linux-zen "linux-zen (Zen kernel)") || die "Cancelled"

# Bootloader is GRUB, as USE_EFI is set to 'no'
if [[ "$USE_EFI" == "yes" ]]; then
  BOOTLOADER=$(menu "Select Bootloader" systemd-boot "systemd-boot (EFI simple)" grub "GRUB (works BIOS+EFI)") || die "Cancelled"
else
  BOOTLOADER="grub"
  msg "BIOS/Legacy selected; using GRUB."
fi


# Desktop selection (rest of setup is standard)
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
if [[ -n "${OPTIONAL_RAW// }" ]]; then
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
Root partition: $ROOT_PART
Swap partition: ${SWAP_PART:-<none>}
EFI requested: $USE_EFI
Format: $DO_FORMAT
Filesystem: $FS_ROOT
Kernel: $KERNEL
Bootloader: $BOOTLOADER
Desktop: $DESKTOP
Optional packages: ${OPTIONAL_PKGS[*]:-none}"

ask "$REVIEW\n\nClick YES to Install Now (will use $ROOT_PART)" || die "Installation cancelled"

# ----------------------
# Auto partition block is skipped (AUTO_PART="no")
# ----------------------

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

# FIX: Dynamically determine and install kernel headers for DKMS/VM tools 
case "$KERNEL" in
  linux) HDR_PKG="linux-headers" ;;
  linux-lts) HDR_PKG="linux-lts-headers" ;;
  linux-zen) HDR_PKG="linux-zen-headers" ;;
  *) HDR_PKG="${KERNEL}-headers" ;;
esac

# Add kernel headers to ensure DKMS (NVIDIA, VBox) works
BASE_PKGS=(base "$KERNEL" "$HDR_PKG" linux-firmware networkmanager sudo os-prober)

pacstrap "$MNT" "${BASE_PKGS[@]}" || die "pacstrap failed"
genfstab -U -L "$MNT" >> "$MNT/etc/fstab" # Use -L for safer label inclusion
success "Base and fstab created"

# install desktop, audio, optional packages
gauge_step "Packages" "Installing desktop & selected packages..." 10
if [ ${#DESKTOP_PKGS[@]} -ne 0 ] || [ ${#AUDIO_PKGS[@]} -ne 0 ]; then
  arch_chroot "pacman -Syu --noconfirm ${DESKTOP_PKGS[*]} ${AUDIO_PKGS[*]}"
fi
if [ ${#OPTIONAL_PKGS[@]} -ne 0 ]; then
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
  arch_chroot "pacman -S --noconfirm nvidia-dkms nvidia-utils nvidia-settings" || msg "NVIDIA install had issues"
  success "NVIDIA handled"
fi

# VM guest tools (based on systemd-detect-virt)
gauge_step "VM Tools" "Installing VM guest tools if detected..." 3
VIRT_LOWER=$(echo "$VIRT" | tr '[:upper:]' '[:lower:]')
VM_PKGS=()
VM_ENABLE_CMDS=()
if [[ "$VIRT_LOWER" == "oracle" || "$VIRT_LOWER" == "virtualbox" ]]; then
  VM_PKGS+=(virtualbox-guest-dkms dkms virtualbox-guest-utils)
  VM_ENABLE_CMDS+=( "systemctl enable vboxservice" )
elif [[ "$VIRT_LOWER" == "vmware" ]]; then
  VM_PKGS+=(open-vm-tools)
  VM_ENABLE_CMDS+=( "systemctl enable --now vmtoolsd" )
elif [[ "$VIRT_LOWER" == "kvm"  "$VIRT_LOWER" == "kvmqemu"  "$VIRT_LOWER" == "qemu" ]]; then
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
  arch_chroot "pacman -S --noconfirm systemd-boot" || die "systemd-boot install failed"
  arch_chroot "bootctl --path=/boot/efi install || true"
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  arch_chroot "mkdir -p /boot/efi/loader/entries"
  arch_chroot "cat >/boot/efi/loader/entries/arch.conf <<'EOF'
title   Arch Linux
linux   /vmlinuz-${KVER}
initrd  /initramfs-${KVER}.img
options root=UUID=${ROOT_UUID} rw
EOF"
  arch_chroot "echo 'default arch' > /boot/efi/loader/loader.conf"
  success "systemd-boot installed"
else # GRUB for BIOS/Legacy mode
  arch_chroot "pacman -S --noconfirm grub"
  if [[ "$USE_EFI" == "yes" ]]; then
    arch_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck || true"
  else
    DISK_FOR_GRUB="$DISK" # /dev/sda
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
