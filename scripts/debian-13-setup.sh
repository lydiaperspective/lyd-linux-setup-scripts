#!/usr/bin/env bash
# Debian 13 (Trixie) Setup Manager
# Run as a regular user; sudo is requested for system changes.
set -Eeuo pipefail

APP_NAME="Debian 13 Setup Manager"
CONFIG_ROOT="$HOME/.config/lyd-linux-setup"
PROFILE_DIR="$CONFIG_ROOT/profiles"
mkdir -p "$PROFILE_DIR"
LOG_FILE="$PROFILE_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
declare -a SELECTED=() PROFILE_SELECTED=()
LOADED_PROFILE=""

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; whiptail --title "$APP_NAME" --msgbox "$*" 12 76 || true; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
contains() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }
msg() { whiptail --title "$APP_NAME" --msgbox "$1" 14 78; }
confirm() { whiptail --title "$APP_NAME" --yesno "$1" 14 78; }
menu() { whiptail --title "$APP_NAME" --menu "$1" 20 82 12 "${@:2}" 3>&1 1>&2 2>&3; }
checklist() { whiptail --title "$APP_NAME" --checklist "$2" 22 84 16 --separate-output "${@:3}" 3>&1 1>&2 2>&3; }

preflight() {
  [[ $EUID -ne 0 ]] || die "Run as your normal user, not with sudo."
  [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
  . /etc/os-release
  [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || die "This script targets Debian 13 (Trixie). Detected: ${PRETTY_NAME:-unknown}."
  has whiptail || die "Install the menu dependency first: sudo apt install whiptail"
  sudo -v
}

load_profile() {
  local key value
  PROFILE_SELECTED=()
  while IFS='=' read -r key value; do
    [[ "$key" == selected ]] && IFS=',' read -r -a PROFILE_SELECTED <<< "$value"
  done < "$1"
  # Translate portable task names from the other managers.
  contains sshd "${PROFILE_SELECTED[@]}" && PROFILE_SELECTED+=(ssh)
  { contains qemu "${PROFILE_SELECTED[@]}" || contains libvirt "${PROFILE_SELECTED[@]}" || contains virt_manager "${PROFILE_SELECTED[@]}"; } && PROFILE_SELECTED+=(virtualization)
  LOADED_PROFILE="$(basename "$1" .conf)"
  log "Loaded profile $LOADED_PROFILE"
}
choose_profile() {
  local -a files=() choices=("fresh" "Start with all tasks unchecked")
  local f name choice
  mapfile -t files < <(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | sort)
  for f in "${files[@]}"; do name="${f%.conf}"; choices+=("$name" "Saved task selections"); done
  choice="$(menu "Choose a starting profile:" "${choices[@]}")" || return 0
  [[ "$choice" == fresh ]] && return 0
  [[ -f "$PROFILE_DIR/$choice.conf" ]] && load_profile "$PROFILE_DIR/$choice.conf"
}
state_for() { contains "$1" "${PROFILE_SELECTED[@]}" && printf ON || printf OFF; }
save_profile() {
  local name file
  confirm "Save these task selections as a reusable profile?" || return 0
  name="$(whiptail --title "$APP_NAME" --inputbox "Profile name (letters, numbers, dash and underscore):" 10 72 "$LOADED_PROFILE" 3>&1 1>&2 2>&3)" || return 0
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || { msg "Invalid profile name."; return 0; }
  file="$PROFILE_DIR/$name.conf"
  [[ ! -e "$file" ]] || confirm "Overwrite $name?" || return 0
  { printf '# Debian 13 Setup Manager profile\nversion=1\nselected='; local IFS=,; printf '%s\n' "${SELECTED[*]}"; } > "$file"
  chmod 600 "$file"
  log "Saved profile: $file"
}
install_pkgs() { (("${#@}" == 0)) && return 0; log "Installing: $*"; sudo apt-get install -y "$@" 2>&1 | tee -a "$LOG_FILE"; }
enable_service() { log "Enabling service $1"; sudo systemctl enable --now "$1"; }

enable_nonfree() {
  log "Ensuring Debian non-free components are enabled for NVIDIA packages."
  msg "Debian 13 uses deb822 sources on many fresh installs. The script will not rewrite your APT source files automatically. Ensure the Debian Trixie, Trixie-updates and Trixie-security entries include contrib, non-free and non-free-firmware, then continue."
  confirm "Have you enabled contrib, non-free and non-free-firmware in your Debian sources?" || return 1
  sudo apt-get update
}
install_nvidia_proprietary() {
  msg "Debian 13's official Trixie archive currently packages the proprietary NVIDIA 550 branch, not 580. This option installs Debian's packaged proprietary driver. It does not add a mismatched Debian 12 repository or use NVIDIA's standalone .run installer."
  confirm "Install the Debian-packaged proprietary NVIDIA driver (550 branch)?" || return 0
  enable_nonfree
  install_pkgs linux-headers-amd64 dkms nvidia-driver nvidia-kernel-dkms nvidia-settings
  log "NVIDIA packages installed. Reboot before testing with nvidia-smi."
}
configure_auto_updates() {
  local freq clock cal
  freq="$(menu "Automatic update frequency:" daily "Every day" weekly "Every week" monthly "Every month")" || return 0
  clock="$(whiptail --title "$APP_NAME" --inputbox "Run time (24-hour HH:MM):" 10 72 "03:00" 3>&1 1>&2 2>&3)" || return 0
  [[ "$clock" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { msg "Use HH:MM."; return 1; }
  case "$freq" in daily) cal="*-*-* $clock:00";; weekly) cal="Sun *-*-* $clock:00";; monthly) cal="*-*-01 $clock:00";; esac
  confirm "Enable unattended APT upgrades on $cal? No automatic reboot will be configured." || return 0
  install_pkgs unattended-upgrades
  sudo tee /etc/systemd/system/debian-13-setup-update.service >/dev/null <<'UNIT'
[Unit]
Description=Scheduled Debian package updates
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/apt-get update
ExecStart=/usr/bin/unattended-upgrade
UNIT
  sudo tee /etc/systemd/system/debian-13-setup-update.timer >/dev/null <<UNIT
[Unit]
Description=Scheduled Debian package update timer
[Timer]
OnCalendar=$cal
Persistent=true
[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now debian-13-setup-update.timer
  log "Enabled scheduled updates: $cal"
}
configure_headless() {
  msg "This removes the KDE Plasma desktop task and display manager. Review the package-manager preview carefully; do not do this over a remote session unless SSH access is verified."
  confirm "Preview KDE removal?" || return 0
  sudo apt-get -s purge task-kde-desktop sddm plasma-desktop 2>&1 | tee -a "$LOG_FILE" || true
  confirm "Proceed with purging the listed KDE desktop packages and autoremove? Review the simulation in the log." || return 0
  sudo systemctl set-default multi-user.target
  sudo systemctl disable --now sddm.service 2>/dev/null || true
  sudo apt-get purge -y task-kde-desktop sddm plasma-desktop 2>&1 | tee -a "$LOG_FILE"
  sudo apt-get autoremove --purge -y 2>&1 | tee -a "$LOG_FILE"
  log "Headless conversion completed. Review package removals before reboot."
}

preflight
log "===== $APP_NAME started ====="
log "Detected: $(. /etc/os-release; printf '%s' "$PRETTY_NAME")"
choose_profile
tasks=(system_update "Update all installed packages" desktop_tools "KDE/desktop utilities and media tools" gaming_tweaks "Install gaming performance tools and user MangoHud config" woman_alias "Add woman command as an alias for man" flatpak "Install Flatpak and Flathub" podman "Install Podman and Compose" tuned "Install TuneD" snapper "Install Snapper" cockpit "Install Cockpit" ssh "Install OpenSSH server" tailscale "Install Tailscale" virtualization "Install QEMU/KVM and virt-manager" nvidia "Install Debian proprietary NVIDIA driver (550)" auto_updates "Configure scheduled automatic updates" headless "Convert KDE installation to headless")
opts=()
for ((i=0; i<${#tasks[@]}; i+=2)); do id="${tasks[i]}"; opts+=("$id" "${tasks[i+1]}" "$(state_for "$id")"); done
mapfile -t SELECTED < <(checklist "Select Debian setup tasks:" "Choose tasks to perform. All changes are reviewed before execution." "${opts[@]}") || true
(("${#SELECTED[@]}" > 0)) || { msg "No tasks selected. Log: $LOG_FILE"; exit 0; }
msg "Selected tasks:\n\n$(printf '%s\n' "${SELECTED[@]}")\n\nLog: $LOG_FILE"
confirm "Apply selected tasks now?" || exit 0
for task in "${SELECTED[@]}"; do
  case "$task" in
    system_update) sudo apt-get update 2>&1 | tee -a "$LOG_FILE"; sudo apt-get full-upgrade -y 2>&1 | tee -a "$LOG_FILE";;
    desktop_tools) install_pkgs ark dolphin konsole kate kcalc ffmpeg;;
    gaming_tweaks)
      msg "Gaming tweaks installs GameMode, MangoHud and vkBasalt. GameMode applies temporary optimisations only when a game requests it; MangoHud is opt-in per game; vkBasalt is installed but its visual effects are not enabled globally. No CPU governor, overclock, kernel parameter or security setting is changed."
      install_pkgs gamemode mangohud vkbasalt
      mkdir -p "$HOME/.config/MangoHud"
      if [[ ! -e "$HOME/.config/MangoHud/MangoHud.conf" ]]; then
        cat > "$HOME/.config/MangoHud/MangoHud.conf" <<'MANGOHUD'
### Lyd Linux Setup - conservative MangoHud defaults
fps
frametime
cpu_stats
gpu_stats
ram
vram
gpu_temp
cpu_temp
position=top-left
toggle_hud=Shift_R+F12
MANGOHUD
        log "Created user MangoHud configuration at $HOME/.config/MangoHud/MangoHud.conf"
      else
        log "Existing MangoHud configuration preserved."
      fi
      log "GameMode can be used with Steam launch option: gamemoderun %command%"
      log "MangoHud can be used with Steam launch option: mangohud %command%"
      log "Combined Steam launch option: gamemoderun mangohud %command%"
      log "vkBasalt remains opt-in; enable per game with ENABLE_VKBASALT=1 in its launch options."
      ;;
    woman_alias)
      install_pkgs man-db
      if command -v woman >/dev/null 2>&1; then
        msg "A command named 'woman' already exists at $(command -v woman). To avoid replacing another program, no alias was installed."
        log "Skipped woman wrapper: existing command found at $(command -v woman)"
      else
        sudo tee /usr/local/bin/woman >/dev/null <<'WOMAN'
#!/bin/sh
exec man "$@"
WOMAN
        sudo chmod 755 /usr/local/bin/woman
        log "Installed /usr/local/bin/woman as a system-wide wrapper for man."
        msg "Installed 'woman'. You can now run commands such as: woman ls"
      fi
      ;;
    flatpak) install_pkgs flatpak plasma-discover-backend-flatpak; sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo;;
    podman) install_pkgs podman podman-compose podman-docker; sudo systemctl enable --now podman.socket;;
    tuned) install_pkgs tuned; enable_service tuned.service;;
    snapper) install_pkgs snapper; log "Snapper installed only. Configure Btrfs subvolumes and snapshots manually; no filesystem layout is changed.";;
    cockpit) install_pkgs cockpit; enable_service cockpit.socket;;
    ssh) install_pkgs openssh-server; enable_service ssh.service;;
    tailscale) log "Installing Tailscale using its official installer"; curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; enable_service tailscaled.service;;
    virtualization) install_pkgs qemu-system-x86 libvirt-daemon-system libvirt-clients virt-manager ovmf; enable_service libvirtd.service; sudo usermod -aG libvirt "$USER";;
    nvidia) install_nvidia_proprietary;;
    auto_updates) configure_auto_updates;;
    headless) configure_headless;;
  esac
done
save_profile
log "Setup run completed."
msg "Debian 13 setup completed. Log: $LOG_FILE"
