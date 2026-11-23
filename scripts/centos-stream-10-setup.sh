#!/usr/bin/env bash
# CentOS Stream 10 Setup Manager
# Run as a regular user; sudo is requested for system changes.
set -Eeuo pipefail

APP_NAME="CentOS Stream 10 Setup Manager"
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
  [[ "${ID:-}" == centos && "${VERSION_ID:-}" == 10 ]] || die "This script targets CentOS Stream 10. Detected: ${PRETTY_NAME:-unknown}."
  [[ "${PLATFORM_ID:-}" == platform:el10* ]] || die "This script expects the EL10 platform."
  has whiptail || die "Install the menu dependency first: sudo dnf install -y newt"
  sudo -v
}
load_profile() {
  local key value
  PROFILE_SELECTED=()
  while IFS='=' read -r key value; do [[ "$key" == selected ]] && IFS=',' read -r -a PROFILE_SELECTED <<< "$value"; done < "$1"
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
  { printf '# CentOS Stream 10 Setup Manager profile\nversion=1\nselected='; local IFS=,; printf '%s\n' "${SELECTED[*]}"; } > "$file"
  chmod 600 "$file"
  log "Saved profile: $file"
}
install_pkgs() { log "Installing: $*"; sudo dnf install -y "$@" 2>&1 | tee -a "$LOG_FILE"; }
enable_service() { log "Enabling service $1"; sudo systemctl enable --now "$1"; }
enable_epel() {
  sudo dnf install -y epel-release 2>&1 | tee -a "$LOG_FILE" || sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
  sudo dnf config-manager --set-enabled crb 2>&1 | tee -a "$LOG_FILE" || true
}
enable_rpmfusion() {
  sudo dnf install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-10.noarch.rpm https://download1.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-10.noarch.rpm 2>&1 | tee -a "$LOG_FILE"
}
install_nvidia_580() {
  [[ "$(uname -m)" == x86_64 ]] || { msg "RPM Fusion's 580xx EL10 package is published for x86_64; this option is unavailable on this architecture."; return 1; }
  msg "NVIDIA 580xx is a legacy proprietary branch for supported older GPUs (commonly Maxwell, Pascal and Volta). Confirm your exact GPU is supported. Secure Boot may require akmods key enrollment; this script will not disable Secure Boot."
  confirm "Install proprietary NVIDIA 580xx from RPM Fusion for EL10? This can replace an existing driver and requires a reboot." || return 0
  enable_rpmfusion
  install_pkgs akmods kernel-devel-matched gcc make akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda
  sudo akmods --force --kernels "$(uname -r)" 2>&1 | tee -a "$LOG_FILE"
  if has mokutil && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    msg "Secure Boot is enabled. Enroll the akmods signing key if prompted before the NVIDIA module can load. The script has not changed Secure Boot settings."
  else
    msg "NVIDIA 580xx installation/build step completed. Reboot, then verify with nvidia-smi."
  fi
}
configure_auto_updates() {
  local freq clock cal
  freq="$(menu "Automatic update frequency:" daily "Every day" weekly "Every week" monthly "Every month")" || return 0
  clock="$(whiptail --title "$APP_NAME" --inputbox "Run time (24-hour HH:MM):" 10 72 "03:00" 3>&1 1>&2 2>&3)" || return 0
  [[ "$clock" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { msg "Use HH:MM."; return 1; }
  case "$freq" in daily) cal="*-*-* $clock:00";; weekly) cal="Sun *-*-* $clock:00";; monthly) cal="*-*-01 $clock:00";; esac
  confirm "Enable scheduled DNF updates on $cal? No automatic reboot will be configured." || return 0
  sudo tee /usr/local/sbin/centos-stream-10-setup-update >/dev/null <<'UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 9>/run/lock/centos-stream-10-setup-update.lock
flock -n 9 || exit 0
exec >>/var/log/centos-stream-10-setup-update.log 2>&1
printf '\n[%s] Starting DNF update.\n' "$(date --iso-8601=seconds)"
dnf -y upgrade --refresh
printf '[%s] Update completed. No automatic reboot configured.\n' "$(date --iso-8601=seconds)"
UPDATE
  sudo chmod 0755 /usr/local/sbin/centos-stream-10-setup-update
  sudo tee /etc/systemd/system/centos-stream-10-setup-update.service >/dev/null <<'UNIT'
[Unit]
Description=Scheduled CentOS Stream 10 update
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/centos-stream-10-setup-update
TimeoutStartSec=infinity
UNIT
  sudo tee /etc/systemd/system/centos-stream-10-setup-update.timer >/dev/null <<UNIT
[Unit]
Description=Scheduled CentOS Stream 10 DNF update
[Timer]
OnCalendar=$cal
Persistent=true
AccuracySec=1min
[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now centos-stream-10-setup-update.timer
  log "Enabled scheduled DNF updates: $cal"
}

preflight
log "===== $APP_NAME started ====="
log "Detected: $(. /etc/os-release; printf '%s' "$PRETTY_NAME")"
choose_profile
tasks=(system_update "Update packages" epel "Enable EPEL and CRB" rpmfusion "Enable RPM Fusion" nvidia580 "Install proprietary NVIDIA 580xx driver" podman "Install Podman and Compose" tuned "Install TuneD" cockpit "Install Cockpit" ssh "Install OpenSSH server" tailscale "Install Tailscale" virtualization "Install QEMU/KVM and virt-manager" snapper "Install Snapper" auto_updates "Configure scheduled automatic updates")
opts=()
for ((i=0; i<${#tasks[@]}; i+=2)); do id="${tasks[i]}"; opts+=("$id" "${tasks[i+1]}" "$(state_for "$id")"); done
mapfile -t SELECTED < <(checklist "Select CentOS Stream 10 tasks:" "Choose tasks to perform. Review before applying." "${opts[@]}") || true
(("${#SELECTED[@]}" > 0)) || { msg "No tasks selected. Log: $LOG_FILE"; exit 0; }
msg "Selected tasks:\n\n$(printf '%s\n' "${SELECTED[@]}")\n\nLog: $LOG_FILE"
confirm "Apply selected tasks now?" || exit 0
for task in "${SELECTED[@]}"; do
  case "$task" in
    system_update) sudo dnf upgrade --refresh -y 2>&1 | tee -a "$LOG_FILE";;
    epel) enable_epel;;
    rpmfusion) enable_rpmfusion;;
    nvidia580) install_nvidia_580;;
    podman) install_pkgs podman podman-compose podman-docker; sudo systemctl enable --now podman.socket;;
    tuned) install_pkgs tuned; enable_service tuned.service;;
    cockpit) install_pkgs cockpit; enable_service cockpit.socket;;
    ssh) install_pkgs openssh-server; enable_service sshd.service;;
    tailscale) log "Installing Tailscale from its official installer"; curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; enable_service tailscaled.service;;
    virtualization) install_pkgs @virtualization virt-manager; enable_service libvirtd.service; sudo usermod -aG libvirt "$USER";;
    snapper) install_pkgs snapper; log "Snapper installed only. Configure Btrfs subvolumes and snapshots manually; no filesystem layout is changed.";;
    auto_updates) configure_auto_updates;;
  esac
done
save_profile
log "Setup run completed."
msg "CentOS Stream 10 setup completed. Log: $LOG_FILE"
