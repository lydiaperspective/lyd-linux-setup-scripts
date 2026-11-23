#!/usr/bin/env bash
#
# Fedora KDE Setup Manager
# Interactive post-install configuration for Fedora KDE Plasma.
# Run as your regular user; sudo is requested only for system changes.
#
set -Eeuo pipefail

APP_NAME="Fedora KDE Setup Manager"
CONFIG_ROOT="$HOME/.config/fedora-kde-setup"
PROFILE_DIR="$CONFIG_ROOT/profiles"
mkdir -p "$PROFILE_DIR"
LOG_FILE="$PROFILE_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
AUTO_UPDATE_CALENDAR=""
AUTO_UPDATE_TIME="03:00"

declare -a SELECTED=()
declare -a PROFILE_SELECTED=()
declare -a PACKAGES=()
LOADED_PROFILE=""

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; whiptail --title "$APP_NAME" --msgbox "$*" 12 76 || true; exit 1; }
on_error() { local rc=$?; log "ERROR: command failed near line ${BASH_LINENO[0]} (exit $rc)"; printf 'Setup stopped. Log: %s\n' "$LOG_FILE" >&2; exit "$rc"; }
trap on_error ERR

require_command() { command -v "$1" >/dev/null 2>&1; }
contains() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }
ui_menu() { whiptail --title "$APP_NAME" --menu "$1" 20 82 12 "${@:2}" 3>&1 1>&2 2>&3; }
ui_checklist() { whiptail --title "$APP_NAME" --checklist "$2" 22 82 14 --separate-output "${@:3}" 3>&1 1>&2 2>&3; }
ui_confirm() { whiptail --title "$APP_NAME" --yesno "$1" 14 78; }
ui_message() { whiptail --title "$APP_NAME" --msgbox "$1" 14 78; }

check_platform() {
    [[ -r /etc/os-release ]] || die "Cannot identify this operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == fedora ]] || die "This script is intended for Fedora Linux. Detected: ${PRETTY_NAME:-unknown}."
    [[ "${VERSION_ID:-}" == "45" ]] || {
        ui_confirm "This script was designed for Fedora 45. Detected Fedora ${VERSION_ID:-unknown}. Continue anyway? Package availability may differ." || exit 0
    }
    [[ "$(id -u)" -ne 0 ]] || die "Run this script as your regular user, not with sudo."
    require_command whiptail || die "whiptail is required. Install it with: sudo dnf install newt"
}

load_profile() {
    local file key value
    PROFILE_SELECTED=()
    while IFS='=' read -r key value; do
        case "$key" in selected) IFS=',' read -r -a PROFILE_SELECTED <<< "$value";; esac
    done < "$1"
    LOADED_PROFILE="$(basename "$1" .conf)"
    log "Loaded profile: $LOADED_PROFILE"
}

choose_profile() {
    local -a files=() choices=("fresh" "Start with all options unchecked")
    local f name choice
    mapfile -t files < <(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | sort)
    for f in "${files[@]}"; do name="${f%.conf}"; choices+=("$name" "Saved selection profile"); done
    choice="$(ui_menu "Choose a profile:" "${choices[@]}")" || return 0
    [[ "$choice" == fresh ]] && return 0
    [[ -f "$PROFILE_DIR/$choice.conf" ]] && load_profile "$PROFILE_DIR/$choice.conf"
}

state_for() { contains "$1" "${PROFILE_SELECTED[@]}" && printf ON || printf OFF; }

save_profile() {
    local name file
    ui_confirm "Save the selected options as a reusable profile?" || return 0
    name="$(whiptail --title "$APP_NAME" --inputbox "Profile name (letters, numbers, dash and underscore):" 10 72 "$LOADED_PROFILE" 3>&1 1>&2 2>&3)" || return 0
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || { ui_message "Invalid profile name."; return 0; }
    file="$PROFILE_DIR/$name.conf"
    [[ ! -e "$file" ]] || ui_confirm "Overwrite existing profile '$name'?" || return 0
    { printf '# Fedora KDE Setup Manager profile\nversion=1\nselected='; local IFS=,; printf '%s\n' "${SELECTED[*]}"; } > "$file"
    chmod 600 "$file"
    log "Saved profile: $file"
}

add_packages() { local p; for p in "$@"; do contains "$p" "${PACKAGES[@]}" || PACKAGES+=("$p"); done; }

enable_service() {
    local unit="$1"
    log "Enabling system service: $unit"
    sudo systemctl enable --now "$unit"
}

install_base_packages() {
    (("${#PACKAGES[@]}" == 0)) && return 0
    log "Installing selected Fedora packages: ${PACKAGES[*]}"
    sudo dnf install -y "${PACKAGES[@]}" 2>&1 | tee -a "$LOG_FILE"
}

enable_rpmfusion() {
    local fedora
    fedora="$(rpm -E %fedora)"
    log "Enabling RPM Fusion free and nonfree repositories for Fedora $fedora"
    sudo dnf install -y \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora}.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora}.noarch.rpm" 2>&1 | tee -a "$LOG_FILE"
}

install_nvidia_580() {
    [[ "$(uname -m)" == x86_64 ]] || { ui_message "The RPM Fusion 580xx packages are intended for x86_64 systems."; return 1; }
    ui_message "NVIDIA 580xx is the legacy driver branch for supported older NVIDIA GPUs (including many Maxwell, Pascal and Volta cards). It is not the right branch for every NVIDIA GPU. Check your exact GPU model before continuing. Secure Boot may require enrolling the akmods signing key; do not disable Secure Boot just to make the driver load."
    ui_confirm "Install the proprietary NVIDIA 580xx driver from RPM Fusion? This may replace a different NVIDIA driver branch and requires a reboot." || return 0
    enable_rpmfusion
    log "Installing akmods build dependencies and NVIDIA 580xx driver"
    sudo dnf install -y akmods kernel-devel-matched gcc make \
      akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx \
      xorg-x11-drv-nvidia-580xx-cuda 2>&1 | tee -a "$LOG_FILE"
    log "Requesting akmods build for the running kernel"
    sudo akmods --force --kernels "$(uname -r)" 2>&1 | tee -a "$LOG_FILE"
    if require_command modinfo && modinfo -k "$(uname -r)" nvidia >/dev/null 2>&1; then
        log "NVIDIA module is available for running kernel $(uname -r)"
    else
        log "WARNING: NVIDIA module was not found for the running kernel. Check /var/cache/akmods/nvidia-580xx/ and /var/log/akmods/akmods.log."
    fi
    if require_command mokutil && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        ui_message "Secure Boot is enabled. The akmods module may need its signing certificate enrolled through MOK before the NVIDIA module can load. Review the akmods/MOK enrollment instructions for Fedora, complete enrollment at the next boot if prompted, then reboot. The script has not changed Secure Boot settings."
    else
        ui_message "NVIDIA 580xx installation/build step finished. Reboot before testing the driver. Verify with: nvidia-smi"
    fi
}

configure_auto_updates() {
    local frequency clock calendar
    frequency="$(ui_menu "Automatic update frequency:" daily "Every day" weekly "Every week" monthly "Every month" custom "Custom systemd OnCalendar expression")" || return 0
    clock="$(whiptail --title "$APP_NAME" --inputbox "Run time (24-hour HH:MM):" 10 72 "03:00" 3>&1 1>&2 2>&3)" || return 0
    [[ "$clock" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { ui_message "Invalid time. Use HH:MM (24-hour clock)."; return 1; }
    case "$frequency" in
        daily) calendar="*-*-* $clock:00";;
        weekly) calendar="Sun *-*-* $clock:00";;
        monthly) calendar="*-*-01 $clock:00";;
        custom)
            calendar="$(whiptail --title "$APP_NAME" --inputbox "Enter a systemd OnCalendar expression:" 10 76 "*-*-* $clock:00" 3>&1 1>&2 2>&3)" || return 0
            ;;
    esac
    AUTO_UPDATE_CALENDAR="$calendar"
    AUTO_UPDATE_TIME="$clock"
    SELECTED+=(auto_updates)
}

write_auto_update_units() {
    [[ -n "$AUTO_UPDATE_CALENDAR" ]] || return 0
    ui_confirm "Enable unattended DNF updates on this schedule? Updates can occasionally require manual intervention; automatic reboot is not enabled." || return 0
    sudo tee /usr/local/sbin/fedora-kde-setup-auto-update >/dev/null <<'UPDATE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 9>/run/lock/fedora-kde-setup-auto-update.lock
flock -n 9 || exit 0
exec >>/var/log/fedora-kde-setup-auto-update.log 2>&1
printf '\n[%s] Starting scheduled Fedora update.\n' "$(date --iso-8601=seconds)"
dnf -y upgrade --refresh
printf '[%s] Update completed. No automatic reboot is configured.\n' "$(date --iso-8601=seconds)"
UPDATE_SCRIPT
    sudo chmod 0755 /usr/local/sbin/fedora-kde-setup-auto-update
    sudo tee /etc/systemd/system/fedora-kde-setup-auto-update.service >/dev/null <<'SERVICE'
[Unit]
Description=Scheduled Fedora system update
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fedora-kde-setup-auto-update
TimeoutStartSec=infinity
SERVICE
    sudo tee /etc/systemd/system/fedora-kde-setup-auto-update.timer >/dev/null <<TIMER
[Unit]
Description=Scheduled Fedora system update timer
[Timer]
OnCalendar=$AUTO_UPDATE_CALENDAR
Persistent=true
AccuracySec=1min
[Install]
WantedBy=timers.target
TIMER
    sudo systemctl daemon-reload
    sudo systemctl enable --now fedora-kde-setup-auto-update.timer
    log "Enabled automatic updates: $AUTO_UPDATE_CALENDAR"
}

configure_headless() {
    ui_message "Headless conversion removes the KDE desktop package group and display manager. This is a major system change. The script will preview DNF's proposed transaction and ask again before removing anything. Keep SSH or another remote access method available if this is a remote machine."
    ui_confirm "Continue to preview KDE removal?" || return 0
    log "Previewing KDE desktop group removal; no changes will be made by this preview."
    sudo dnf group remove "KDE Plasma Workspaces" --assumeno 2>&1 | tee -a "$LOG_FILE" || true
    ui_confirm "Proceed with removing the KDE Plasma Workspaces group and SDDM? Review the preview in the log first. DNF may propose removing dependent packages." || return 0
    sudo systemctl set-default multi-user.target
    if systemctl list-unit-files sddm.service --no-legend 2>/dev/null | grep -q sddm; then
        sudo systemctl disable --now sddm.service || true
    fi
    sudo dnf group remove -y "KDE Plasma Workspaces" 2>&1 | tee -a "$LOG_FILE"
    sudo dnf remove -y sddm 2>&1 | tee -a "$LOG_FILE" || log "SDDM removal returned a non-zero status."
    log "Headless conversion requested. Review DNF output and reboot when ready."
}

main_menu() {
    local -a choices=(
      system_update "Refresh metadata and update Fedora"
      rpmfusion "Enable RPM Fusion repositories"
      nvidia580 "Install proprietary NVIDIA 580xx driver (RPM Fusion)"
      desktop_tools "Install desktop utilities and codecs"
      flatpak "Install Flatpak and enable Flathub"
      podman "Install Podman and Compose"
      tuned "Install TuneD and TuneD-PPD"
      lact "Install LACT GPU control"
      cooler "Install CoolerControl and sensor tools"
      snapper "Install Snapper (Btrfs snapshot tooling)"
      cockpit "Install and enable Cockpit"
      ssh "Install and enable OpenSSH server"
      tailscale "Install Tailscale"
      virtualization "Install QEMU/KVM and virt-manager"
      zed "Install Zed editor"
      auto_updates "Configure scheduled automatic DNF updates"
      headless "Convert this KDE installation to headless server"
    )
    local -a checklist=()
    local item desc
    for ((i=0; i<${#choices[@]}; i+=2)); do
        item="${choices[i]}"; desc="${choices[i+1]}"
        checklist+=("$item" "$desc" "$(state_for "$item")")
    done
    mapfile -t SELECTED < <(ui_checklist "Select setup tasks:" "Choose the tasks to perform. Review every selection before applying." "${checklist[@]}") || true
}

check_platform
log "===== $APP_NAME started ====="
log "Detected: $(. /etc/os-release; printf '%s' "$PRETTY_NAME")"
choose_profile
main_menu

if (("${#SELECTED[@]}" == 0)); then
    ui_message "No tasks selected. Nothing was changed.\n\nLog: $LOG_FILE"
    exit 0
fi

summary="$(printf '%s\n' "${SELECTED[@]}")"
ui_message "The following tasks are selected:\n\n$summary\n\nA log will be kept at:\n$LOG_FILE"
ui_confirm "Apply these selections now? System changes will use sudo." || exit 0

for task in "${SELECTED[@]}"; do
    case "$task" in
        system_update) log "Updating Fedora"; sudo dnf upgrade --refresh -y 2>&1 | tee -a "$LOG_FILE";;
        rpmfusion) enable_rpmfusion;;
        nvidia580) install_nvidia_580;;
        desktop_tools) add_packages ark dolphin konsole kate kcalc kcharselect ffmpeg gstreamer1-plugin-openh264; install_base_packages;;
        flatpak) add_packages flatpak; install_base_packages; sudo flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo;;
        podman) add_packages podman podman-compose podman-docker; install_base_packages; enable_service podman.socket;;
        tuned) add_packages tuned tuned-ppd; install_base_packages; enable_service tuned.service;;
        lact) add_packages lact; install_base_packages; enable_service lactd.service;;
        cooler) add_packages coolercontrol lm_sensors; install_base_packages; enable_service coolercontrold.service;;
        snapper) add_packages snapper; install_base_packages; log "Snapper installed. Create and configure Btrfs subvolume snapshots deliberately; no filesystem layout is changed automatically.";;
        cockpit) add_packages cockpit; install_base_packages; enable_service cockpit.socket;;
        ssh) add_packages openssh-server; install_base_packages; enable_service sshd.service;;
        tailscale) log "Installing Tailscale from its official Fedora repository setup"; curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; enable_service tailscaled.service;;
        virtualization) add_packages @virtualization virt-manager; install_base_packages; enable_service libvirtd.service;;
        zed) log "Installing Zed using its official installer"; curl -f https://zed.dev/install.sh | sh 2>&1 | tee -a "$LOG_FILE";;
        auto_updates) configure_auto_updates;;
        headless) configure_headless;;
    esac
done

write_auto_update_units
save_profile
log "Setup run completed."
ui_message "Fedora KDE Setup Manager finished.\n\nLog file:\n$LOG_FILE\n\nReview warnings and reboot if required."
