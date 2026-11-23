#!/usr/bin/env bash
#
# CachyOS Setup Manager
# Interactive, repeatable post-install configuration for CachyOS.
#
# Run as your regular user. The script requests sudo when required.
#
set -Eeuo pipefail

APP_NAME="CachyOS Setup Manager"
PROFILE_DIR="$HOME/.config/lyd-linux-setup/profiles"
mkdir -p "$PROFILE_DIR"
LOG_DIR="$PROFILE_DIR"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
AUTO_UPDATE_CALENDAR=""

declare -a SELECTED=()
declare -a PACKAGES=()
declare -a PODMAN_OPTIONS=()
declare -a TUNED_OPTIONS=()
declare -a SNAPPER_OPTIONS=()
declare -a COOLER_OPTIONS=()
declare -a KDE_OPTIONS=()
declare -a SERVER_OPTIONS=()
declare -a VIRT_OPTIONS=()
declare -a FLATPAK_OPTIONS=()
declare -a FLATPAK_BACKUPS=()
FLATPAK_BACKUP_ROOT="$HOME/.local/share/cachyos-setup/flatpak-backups"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    whiptail --title "$APP_NAME" --msgbox "$*" 12 72 || true
    exit 1
}

on_error() {
    local status=$?
    log "ERROR: command failed at line ${BASH_LINENO[0]} (exit $status)"
    printf '\nSetup stopped. Log: %s\n' "$LOG_FILE" >&2
    exit "$status"
}
trap on_error ERR

require_command() {
    command -v "$1" >/dev/null 2>&1
}

contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

remove_selected_item() {
    local target="$1" item
    local -a kept=()
    for item in "${SELECTED[@]}"; do
        [[ "$item" == "$target" ]] || kept+=("$item")
    done
    SELECTED=("${kept[@]}")
}

add_packages() {
    local package
    for package in "$@"; do
        contains "$package" "${PACKAGES[@]}" || PACKAGES+=("$package")
    done
}

ui_checklist() {
    local title="$1" prompt="$2"
    shift 2
    whiptail --title "$title" --checklist "$prompt" 22 78 14 \
        --separate-output "$@" 3>&1 1>&2 2>&3
}

ui_menu() {
    local prompt="$1"
    shift
    whiptail --title "$APP_NAME" --menu "$prompt" 18 78 10 \
        "$@" 3>&1 1>&2 2>&3
}

ui_confirm() {
    whiptail --title "$APP_NAME" --yesno "$1" 12 76
}

ui_message() {
    whiptail --title "$APP_NAME" --msgbox "$1" 13 76
}


# ----- Portable selection profiles -------------------------------------------

declare -a PROFILE_SELECTED=()
declare -a PROFILE_PODMAN=()
declare -a PROFILE_TUNED=()
declare -a PROFILE_SNAPPER=()
declare -a PROFILE_COOLER=()
declare -a PROFILE_KDE=()
declare -a PROFILE_SERVER=()
declare -a PROFILE_VIRT=()
declare -a PROFILE_FLATPAK=()
LOADED_PROFILE=""

default_state() {
    if contains "$1" "${PROFILE_SELECTED[@]}" ||
       contains "$1" "${PROFILE_PODMAN[@]}" ||
       contains "$1" "${PROFILE_TUNED[@]}" ||
       contains "$1" "${PROFILE_SNAPPER[@]}" ||
       contains "$1" "${PROFILE_COOLER[@]}" ||
       contains "$1" "${PROFILE_KDE[@]}" ||
       contains "$1" "${PROFILE_SERVER[@]}" ||
       contains "$1" "${PROFILE_VIRT[@]}" ||
       contains "$1" "${PROFILE_FLATPAK[@]}"; then
        printf 'ON'
    else
        printf 'OFF'
    fi
}

load_profile_file() {
    local file="$1" key value
    PROFILE_SELECTED=()
    PROFILE_PODMAN=()
    PROFILE_TUNED=()
    PROFILE_SNAPPER=()
    PROFILE_COOLER=()
    PROFILE_KDE=()
    PROFILE_SERVER=()
    PROFILE_VIRT=()
    PROFILE_FLATPAK=()

    # This is a simple data format, not a shell script: never source it.
    while IFS='=' read -r key value; do
        case "$key" in
            selected) IFS=',' read -r -a PROFILE_SELECTED <<< "$value";;
            podman) IFS=',' read -r -a PROFILE_PODMAN <<< "$value";;
            tuned) IFS=',' read -r -a PROFILE_TUNED <<< "$value";;
            snapper) IFS=',' read -r -a PROFILE_SNAPPER <<< "$value";;
            cooler) IFS=',' read -r -a PROFILE_COOLER <<< "$value";;
            kde) IFS=',' read -r -a PROFILE_KDE <<< "$value";;
            server) IFS=',' read -r -a PROFILE_SERVER <<< "$value";;
            virt) IFS=',' read -r -a PROFILE_VIRT <<< "$value";;
            flatpak) IFS=',' read -r -a PROFILE_FLATPAK <<< "$value";;
        esac
    done < "$file"
    LOADED_PROFILE="$(basename "$file" .conf)"
    log "Loaded selection profile: $LOADED_PROFILE"
}

choose_profile() {
    mkdir -p "$PROFILE_DIR"
    local -a profile_files=() choices=()
    local file name selected

    while true; do
        profile_files=()
        choices=("fresh" "Start with all options unchecked"
                 "open_profiles" "Open the profile folder in your default file manager")
        mapfile -t profile_files < <(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\\n' | sort)
        for file in "${profile_files[@]}"; do
            name="${file%.conf}"
            choices+=("$name" "Load saved selection profile")
        done

        selected="$(ui_menu "Choose a starting configuration:" "${choices[@]}")" || return 0
        case "$selected" in
            open_profiles)
                if require_command xdg-open; then
                    log "Opening profile folder: $PROFILE_DIR"
                    xdg-open "$PROFILE_DIR" >/dev/null 2>&1 &
                else
                    ui_message "Could not find xdg-open. Install xdg-utils to open the profile folder automatically.\\n\\nFolder:\\n$PROFILE_DIR"
                fi
                ;;
            fresh|"") return 0;;
            *)
                file="$PROFILE_DIR/$selected.conf"
                if [[ -f "$file" ]]; then
                    load_profile_file "$file"
                    ui_message "Loaded profile: $selected\\n\\nIts saved selections will be pre-checked in the setup menus. Review them before proceeding."
                    return 0
                fi
                ;;
        esac
    done
}

join_array() {
    local IFS=,
    printf '%s' "$*"
}

save_profile() {
    local name file
    if ! ui_confirm "Save the selections from this run as a reusable profile? You can copy the profile file to another machine."; then
        return 0
    fi
    name="$(whiptail --title "$APP_NAME" --inputbox "Enter a profile name (letters, numbers, dash and underscore only):" 10 72 "$LOADED_PROFILE" 3>&1 1>&2 2>&3)" || return 0
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || {
        ui_message "Invalid profile name. Use 1-40 letters, numbers, underscores or dashes."
        return 0
    }
    mkdir -p "$PROFILE_DIR"
    file="$PROFILE_DIR/$name.conf"
    if [[ -e "$file" ]] && ! ui_confirm "Profile '$name' already exists. Overwrite it?"; then
        return 0
    fi
    (
        umask 077
        {
            printf '# CachyOS Setup Manager profile - portable selection data\n'
            printf 'version=2\n'
            printf 'selected=%s\n' "$(join_array "${SELECTED[@]}")"
            printf 'podman=%s\n' "$(join_array "${PODMAN_OPTIONS[@]}")"
            printf 'tuned=%s\n' "$(join_array "${TUNED_OPTIONS[@]}")"
            printf 'snapper=%s\n' "$(join_array "${SNAPPER_OPTIONS[@]}")"
            printf 'cooler=%s\n' "$(join_array "${COOLER_OPTIONS[@]}")"
            printf 'kde=%s\n' "$(join_array "${KDE_OPTIONS[@]}")"
            printf 'server=%s\n' "$(join_array "${SERVER_OPTIONS[@]}")"
            printf 'virt=%s\n' "$(join_array "${VIRT_OPTIONS[@]}")"
            printf 'flatpak=%s\n' "$(join_array "${FLATPAK_OPTIONS[@]}")"
        } > "$file"
    )
    log "Saved selection profile: $file"
    ui_message "Profile saved:\n\n$file\n\nCopy this .conf file to the same profiles directory on another machine to reuse these selections."
}


# Flatpak manifest backup / restore

backup_flatpaks() {
    require_command flatpak || { ui_message "Flatpak is not installed."; return 1; }
    local stamp destination scope app origin remote url
    stamp="$(date +%Y%m%d-%H%M%S)"
    destination="$FLATPAK_BACKUP_ROOT/flatpak-$stamp"
    mkdir -p "$destination"
    printf 'CachyOS Setup Manager Flatpak backup\nCreated: %s\n' "$(date --iso-8601=seconds)" > "$destination/README.txt"
    for scope in user system; do
        local scope_flag="--$scope"
        : > "$destination/$scope-apps.tsv"
        : > "$destination/$scope-remotes.tsv"
        while read -r remote url _; do
            [[ -n "$remote" && "$remote" != "Name" && -n "$url" ]] || continue
            printf '%s\t%s\n' "$remote" "$url" >> "$destination/$scope-remotes.tsv"
        done < <(flatpak remotes "$scope_flag" --columns=name,url 2>/dev/null || true)
        while IFS= read -r app; do
            [[ -n "$app" ]] || continue
            origin="$(flatpak info "$scope_flag" --show-origin "$app" 2>/dev/null || true)"
            [[ -n "$origin" && "$origin" != "-" ]] || origin=""
            printf '%s\t%s\n' "$origin" "$app" >> "$destination/$scope-apps.tsv"
        done < <(flatpak list "$scope_flag" --app --columns=application 2>/dev/null || true)
    done
    if ! grep -q . "$destination/user-apps.tsv" "$destination/system-apps.tsv"; then
        rm -rf "$destination"
        ui_message "No installed Flatpak applications were found."
        return 0
    fi
    tar -czf "$destination.tar.gz" -C "$FLATPAK_BACKUP_ROOT" "$(basename "$destination")"
    rm -rf "$destination"
    log "Flatpak backup created: $destination.tar.gz"
    ui_message "Flatpak backup created:\n\n$destination.tar.gz\n\nIncludes application IDs, user/system scope, origins and remote URLs. Does not include app data or runtimes."
}

restore_flatpaks() {
    require_command flatpak || { ui_message "Flatpak is not installed. Install it first."; return 1; }
    mkdir -p "$FLATPAK_BACKUP_ROOT"
    mapfile -t FLATPAK_BACKUPS < <(find "$FLATPAK_BACKUP_ROOT" -maxdepth 1 -type f -name 'flatpak-*.tar.gz' -printf '%f\n' | sort -r)
    if (("${#FLATPAK_BACKUPS[@]}" == 0)); then
        ui_message "No Flatpak backups found in:\n$FLATPAK_BACKUP_ROOT"
        return 0
    fi
    local -a choices=()
    local archive chosen extract_dir backup_dir scope remote url app failed=0 installed=0
    for archive in "${FLATPAK_BACKUPS[@]}"; do choices+=("$archive" "Flatpak application list"); done
    chosen="$(ui_menu "Select a Flatpak backup to restore:" "${choices[@]}")" || return 0
    [[ -n "$chosen" ]] || return 0
    ui_confirm "Restore $chosen? Apps will be installed in their recorded user/system scope." || return 0
    extract_dir="$(mktemp -d "$FLATPAK_BACKUP_ROOT/restore.XXXXXX")"
    if ! tar -xzf "$FLATPAK_BACKUP_ROOT/$chosen" -C "$extract_dir"; then
        rm -rf "$extract_dir"; ui_message "Could not read the selected backup."; return 1
    fi
    backup_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -name 'flatpak-*' -print -quit)"
    if [[ -z "$backup_dir" ]]; then
        rm -rf "$extract_dir"; ui_message "Invalid Flatpak backup archive."; return 1
    fi
    for scope in user system; do
        local remote_file="$backup_dir/$scope-remotes.tsv"
        [[ -f "$remote_file" ]] || continue
        while IFS=$'\t' read -r remote url; do
            [[ -n "$remote" && -n "$url" ]] || continue
            if [[ "$scope" == system ]]; then
                sudo flatpak remote-add --if-not-exists --system "$remote" "$url" 2>&1 | tee -a "$LOG_FILE"
            else
                flatpak remote-add --if-not-exists --user "$remote" "$url" 2>&1 | tee -a "$LOG_FILE"
            fi
        done < "$remote_file"
    done
    for scope in user system; do
        local app_file="$backup_dir/$scope-apps.tsv"
        [[ -f "$app_file" ]] || continue
        while IFS=$'\t' read -r origin app; do
            [[ -n "$app" ]] || continue
            origin="${origin:-flathub}"
            if [[ "$scope" == system ]]; then
                if sudo flatpak install --system --noninteractive --assumeyes "$origin" "$app" 2>&1 | tee -a "$LOG_FILE"; then
                    ((installed+=1))
                else
                    ((failed+=1))
                fi
            else
                if flatpak install --user --noninteractive --assumeyes "$origin" "$app" 2>&1 | tee -a "$LOG_FILE"; then
                    ((installed+=1))
                else
                    ((failed+=1))
                fi
            fi
        done < "$app_file"
    done
    rm -rf "$extract_dir"
    log "Flatpak restore finished: $installed installed, $failed failed."
    ui_message "Flatpak restore finished.\n\nInstalled: $installed\nFailed: $failed\n\nReview the log for details."
}

enable_system_service() {
    local unit="$1"
    if ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -Fq "$unit"; then
        log "SKIP: system service not found: $unit"
        return 0
    fi
    log "Enabling system service: $unit"
    sudo systemctl enable --now "$unit"
}

enable_user_service() {
    local unit="$1"
    if ! systemctl --user list-unit-files "$unit" --no-legend 2>/dev/null | grep -Fq "$unit"; then
        log "SKIP: user service not found: $unit"
        return 0
    fi
    log "Enabling user service: $unit"
    systemctl --user enable --now "$unit"
}

select_category() {
    local category="$1" prompt="$2"
    shift 2
    local result
    result="$(ui_checklist "$category" "$prompt" "$@")" || return 1
    if [[ -n "$result" ]]; then
        while IFS= read -r item; do
            [[ -n "$item" ]] && SELECTED+=("$item")
        done <<< "$result"
    fi
}

select_nested() {
    local title="$1" prompt="$2" destination="$3"
    shift 3
    local result
    result="$(ui_checklist "$title" "$prompt" "$@")" || return 1
    case "$destination" in
        podman) PODMAN_OPTIONS=();;
        tuned) TUNED_OPTIONS=();;
        snapper) SNAPPER_OPTIONS=();;
        cooler) COOLER_OPTIONS=();;
        kde) KDE_OPTIONS=();;
        server) SERVER_OPTIONS=();;
        virt) VIRT_OPTIONS=();;
        flatpak) FLATPAK_OPTIONS=();;
    esac
    if [[ -n "$result" ]]; then
        while IFS= read -r item; do
            [[ -n "$item" ]] || continue
            case "$destination" in
                podman) PODMAN_OPTIONS+=("$item");;
                tuned) TUNED_OPTIONS+=("$item");;
                snapper) SNAPPER_OPTIONS+=("$item");;
                cooler) COOLER_OPTIONS+=("$item");;
                kde) KDE_OPTIONS+=("$item");;
                server) SERVER_OPTIONS+=("$item");;
                virt) VIRT_OPTIONS+=("$item");;
                flatpak) FLATPAK_OPTIONS+=("$item");;
            esac
        done <<< "$result"
    fi
}

# ----- Preflight -------------------------------------------------------------

[[ $EUID -ne 0 ]] || {
    echo "Run this script as your normal user, not root." >&2
    exit 1
}
[[ -r /etc/os-release ]] || die "Cannot identify this operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "cachyos" || " ${ID_LIKE:-} " == *" arch "* ]] ||
    die "This script is intended for CachyOS or an Arch-based system."

if ! require_command whiptail; then
    echo "Installing whiptail (libnewt)..."
    sudo pacman -S --needed libnewt || exit 1
fi
sudo -v || exit 1

choose_profile

# ----- Main selection: deliberately split into labelled sections ------------

select_category "01 - System & Gaming" \
    "Select system and gaming applications. SPACE toggles; ENTER continues." \
    steam "Steam (and Steam device rules)" "$(default_state steam)" \
    solaar "Solaar - Logitech device manager" "$(default_state solaar)" \
    flatpak "Flatpak runtime and Flathub" "$(default_state flatpak)" \
    discover "KDE Discover + Flatpak support" "$(default_state discover)" \
    flatpak_backup "Back up installed Flatpak applications" "$(default_state flatpak_backup)" \
    flatpak_restore "Restore applications from a Flatpak backup" "$(default_state flatpak_restore)" || exit 0

select_category "02 - Containers" \
    "Select container tools. Podman has a separate configuration submenu." \
    podman "Podman environment (configure components next)" "$(default_state podman)" \
    distrobox "Distrobox" "$(default_state distrobox)" || exit 0

select_category "03 - Network & Power Services" \
    "Select background services and power management tools." \
    tailscale "Tailscale (configure service next)" "$(default_state tailscale)" \
    tuned "TuneD + TuneD-PPD (configure services next)" "$(default_state tuned)" \
    lact "LACT GPU control (configure daemon next)" "$(default_state lact)" || exit 0

select_category "04 - Cooling & Fan Control" \
    "Select CoolerControl and optional supporting utilities." \
    coolercontrol "CoolerControl (configure hardware support next)" "$(default_state coolercontrol)" || exit 0

select_category "05 - Filesystem & Snapshots" \
    "Select Btrfs snapshot tools. Root setup is guarded by filesystem checks." \
    snapper "Snapper + Btrfs Assistant (configure next)" "$(default_state snapper)" || exit 0

select_category "06 - Development" \
    "Select development applications." \
    zed "Zed IDE (official installer)" "$(default_state zed)" || exit 0

select_category "07 - KDE Plasma" \
    "Select desktop configuration backup or restore tools." \
    kde_backup "Back up Plasma panels, widgets and desktop settings" "$(default_state kde_backup)" \
    kde_restore "Restore a previous Plasma configuration backup" "$(default_state kde_restore)" || exit 0

select_category "08 - Server & Remote Access" \
    "Select server administration and network services. Service activation is configured next." \
    cockpit "Cockpit web-based server administration" "$(default_state cockpit)" \
    sshd "OpenSSH server" "$(default_state sshd)" \
    nfs "NFS server utilities" "$(default_state nfs)" \
    auto_updates "Scheduled automatic CachyOS updates (Snapper snapshot, offline update and reboot)" "$(default_state auto_updates)" || exit 0

select_category "09 - Storage & Virtualization" \
    "Select storage sync and virtual machine tools." \
    rclone "Rclone cloud and remote storage sync" "$(default_state rclone)" \
    qemu "QEMU desktop virtual machine emulator" "$(default_state qemu)" \
    libvirt "Libvirt virtualization management" "$(default_state libvirt)" \
    virt_manager "Virtual Machine Manager (virt-manager)" "$(default_state virt_manager)" || exit 0

select_category "10 - Flatpak Applications" \
    "Choose Flatpak applications to install. Waterfox can replace the system Firefox package." \
    flatpak_apps "Install selected Flatpak applications (configure next)" "$(default_state flatpak_apps)" || exit 0

select_category "11 - Lyd Ark Themes" \
    "Optional KDE Plasma appearance from the pinned Lyd Ark Themes revision." \
    mystical_theme "Install and apply the Mystical KDE theme" "$(default_state mystical_theme)" || exit 0

select_category "12 - Controller Support" \
    "Optional udev access rules for extra controller inputs in Steam Input." \
    8bitdo_pro2 "8BitDo Pro 2 rear buttons in Steam Input (DInput mode)" "$(default_state 8bitdo_pro2)" || exit 0

# ----- Nested configuration menus --------------------------------------------

if contains podman "${SELECTED[@]}"; then
    select_nested "Podman Configuration" \
        "Choose components and socket activation. System and user sockets are independent." podman \
        compose "Install podman-compose" "$(default_state compose)" \
        docker "Install podman-docker compatibility" "$(default_state docker)" \
        system_socket "Enable system podman.socket" "$(default_state system_socket)" \
        user_socket "Enable rootless user podman.socket" "$(default_state user_socket)" \
        linger "Enable lingering for this user (rootless containers after logout)" "$(default_state linger)" || exit 0
fi

if contains tailscale "${SELECTED[@]}"; then
    if contains tailscale_service "${PROFILE_SELECTED[@]}"; then
        SELECTED+=(tailscale_service)
    elif ui_confirm "Enable and start tailscaled.service now?"; then
        SELECTED+=(tailscale_service)
    fi
fi

if contains tuned "${SELECTED[@]}"; then
    select_nested "TuneD Configuration" \
        "Choose which system services to enable." tuned \
        tuned_service "Enable tuned.service" "$(default_state tuned_service)" \
        ppd_service "Enable tuned-ppd.service" "$(default_state ppd_service)" || exit 0
fi

if contains lact "${SELECTED[@]}"; then
    if contains lact_service "${PROFILE_SELECTED[@]}"; then
        SELECTED+=(lact_service)
    elif ui_confirm "Enable and start lactd.service now?"; then
        SELECTED+=(lact_service)
    fi
fi

if contains coolercontrol "${SELECTED[@]}"; then
    select_nested "CoolerControl Configuration" \
        "Choose optional hardware support and daemon configuration." cooler \
        daemon "Enable coolercontrold.service" "$(default_state daemon)" \
        liquidctl "Install liquidctl USB cooling support" "$(default_state liquidctl)" \
        sensors "Install lm_sensors" "$(default_state sensors)" \
        detect "Run sensors-detect (interactive; review its prompts)" "$(default_state detect)" || exit 0
fi

if contains snapper "${SELECTED[@]}"; then
    select_nested "Snapper Configuration" \
        "Only configure root snapshots when / is Btrfs. Existing configurations are preserved." snapper \
        root_config "Create root Snapper configuration if missing" "$(default_state root_config)" \
        snap_pac "Install snap-pac for pre/post Pacman snapshots" "$(default_state snap_pac)" \
        timeline "Enable snapper-timeline.timer" "$(default_state timeline)" \
        cleanup "Enable snapper-cleanup.timer" "$(default_state cleanup)" \
        assistant "Install Btrfs Assistant" "$(default_state assistant)" || exit 0
fi

if contains kde_backup "${SELECTED[@]}" || contains kde_restore "${SELECTED[@]}"; then
    select_nested "KDE Backup Options" \
        "Choose whether to include window-manager and shortcut settings." kde \
        kwin "Include KWin settings and rules" "$(default_state kwin)" \
        shortcuts "Include global keyboard shortcuts" "$(default_state shortcuts)" || exit 0
fi

if contains cockpit "${SELECTED[@]}" || contains sshd "${SELECTED[@]}" || contains nfs "${SELECTED[@]}" || contains auto_updates "${SELECTED[@]}"; then
    select_nested "Server Service Configuration" \
        "Choose server services and optional system changes. Headless mode removes the Plasma desktop and graphical login manager; reboot is required." server \
        cockpit_socket "Enable Cockpit web console socket (cockpit.socket)" "$(default_state cockpit_socket)" \
        cockpit_storaged "Install Cockpit storage module" "$(default_state cockpit_storaged)" \
        cockpit_machines "Install Cockpit virtual machines module (cockpit-machines)" "$(default_state cockpit_machines)" \
        cockpit_files "Install Cockpit file browser module" "$(default_state cockpit_files)" \
        cockpit_network "Install NetworkManager and enable NetworkManager.service for Cockpit networking" "$(default_state cockpit_network)" \
        sshd_service "Enable and start sshd.service" "$(default_state sshd_service)" \
        nfs_service "Enable and start nfs-server.service" "$(default_state nfs_service)" \
        lts_kernel "Install CachyOS LTS kernel (keep the current kernel as fallback)" "$(default_state lts_kernel)" \
        package_cache "Retain recent package versions with paccache.timer (default: 3 versions)" "$(default_state package_cache)" \
        snapper_updates "Enable Snapper pre/post Pacman snapshots (Btrfs; asks before root config)" "$(default_state snapper_updates)" \
        update_guidance "Show conservative manual-update guidance" "$(default_state update_guidance)" \
        headless "Remove KDE Plasma desktop, KDE apps and graphical login manager" "$(default_state headless)" || exit 0
fi

if contains qemu "${SELECTED[@]}" || contains libvirt "${SELECTED[@]}" || contains virt_manager "${SELECTED[@]}" || contains cockpit_machines "${SERVER_OPTIONS[@]}"; then
    select_nested "Virtualization Setup" \
        "Choose optional VM features, networking and permissions. Group access grants broad VM-management privileges." virt \
        libvirt_service "Enable and start libvirtd.service" "$(default_state libvirt_service)" \
        libvirt_network "Enable libvirt default NAT network (installs dnsmasq)" "$(default_state libvirt_network)" \
        ovmf "Install UEFI firmware for virtual machines (edk2-ovmf)" "$(default_state ovmf)" \
        swtpm "Install software TPM emulator (swtpm; useful for Windows 11 guests)" "$(default_state swtpm)" \
        virt_viewer "Install SPICE/VNC console viewer (virt-viewer)" "$(default_state virt_viewer)" \
        virt_install "Install virt-install command-line tools" "$(default_state virt_install)" \
        libvirt_group "Add this user to the libvirt group (requires logout; privileged access)" "$(default_state libvirt_group)" || exit 0
fi

# Configure the scheduled offline-update calendar. A Btrfs root with a
# working Snapper root configuration is required; otherwise automation is
# declined rather than running upgrades without the requested snapshot.
if contains auto_updates "${SELECTED[@]}"; then
    if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" != "btrfs" ]]; then
        ui_message "Automatic updates require a Btrfs root filesystem so a pre-update Snapper snapshot can be created. The option has been skipped."
        remove_selected_item auto_updates
    else
        frequency="$(ui_menu "Choose automatic update frequency:" daily "Every day" weekly "Once per week" monthly "Once per month" custom "Custom systemd calendar expression")" || frequency=""
        if [[ -z "$frequency" ]]; then
            remove_selected_item auto_updates
        else
            if [[ "$frequency" == "custom" ]]; then
                AUTO_UPDATE_CALENDAR="$(whiptail --title "$APP_NAME" --inputbox "Enter a systemd OnCalendar expression. Example: Mon..Fri *-*-* 03:00:00" 10 76 "*-*-* 03:00:00" 3>&1 1>&2 2>&3)" || AUTO_UPDATE_CALENDAR=""
                if [[ -z "$AUTO_UPDATE_CALENDAR" ]]; then
                    remove_selected_item auto_updates
                fi
            else
                update_time="$(whiptail --title "$APP_NAME" --inputbox "Enter the local 24-hour time for updates (HH:MM)." 10 68 "03:00" 3>&1 1>&2 2>&3)" || update_time=""
                if [[ ! "$update_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    ui_message "Invalid time. Use 24-hour HH:MM, for example 03:00. Automatic updates were not enabled."
                    remove_selected_item auto_updates
                else
                    case "$frequency" in
                        daily) AUTO_UPDATE_CALENDAR="*-*-* ${update_time}:00";;
                        weekly)
                            weekday="$(ui_menu "Choose the update day:" Mon Monday Tue Tuesday Wed Wednesday Thu Thursday Fri Friday Sat Saturday Sun Sunday)" || weekday=""
                            if [[ -z "$weekday" ]]; then
                                remove_selected_item auto_updates
                            else
                                AUTO_UPDATE_CALENDAR="${weekday} *-*-* ${update_time}:00"
                            fi
                            ;;
                        monthly)
                            month_day="$(whiptail --title "$APP_NAME" --inputbox "Day of the month (1-28):" 10 68 "1" 3>&1 1>&2 2>&3)" || month_day=""
                            if [[ "$month_day" =~ ^([1-9]|1[0-9]|2[0-8])$ ]]; then
                                printf -v month_day "%02d" "$month_day"
                                AUTO_UPDATE_CALENDAR="*-*-${month_day} ${update_time}:00"
                            else
                                ui_message "Choose a day from 1 to 28. Automatic updates were not enabled."
                                remove_selected_item auto_updates
                            fi
                            ;;
                    esac
                fi
            fi
        fi
        if contains auto_updates "${SELECTED[@]}"; then
            if ! systemd-analyze calendar "$AUTO_UPDATE_CALENDAR" >/dev/null 2>&1; then
                ui_message "The selected schedule is not a valid systemd calendar expression. Automatic updates were not enabled."
                remove_selected_item auto_updates
                AUTO_UPDATE_CALENDAR=""
            elif ! ui_confirm "Enable unattended CachyOS updates on this schedule?\n\nSchedule: $AUTO_UPDATE_CALENDAR\n\nThe system will create a Snapper snapshot, prepare the official offline update, and reboot automatically when updates are pending. This can interrupt active sessions and services."; then
                remove_selected_item auto_updates
                AUTO_UPDATE_CALENDAR=""
            else
                contains snapper "${SELECTED[@]}" || SELECTED+=(snapper)
                contains root_config "${SNAPPER_OPTIONS[@]}" || SNAPPER_OPTIONS+=(root_config)
                contains snap_pac "${SNAPPER_OPTIONS[@]}" || SNAPPER_OPTIONS+=(snap_pac)
                contains cleanup "${SNAPPER_OPTIONS[@]}" || SNAPPER_OPTIONS+=(cleanup)
            fi
        fi
    fi
fi

# Optional stability-oriented server setup.
if contains snapper_updates "${SERVER_OPTIONS[@]}"; then
    contains snapper "${SELECTED[@]}" || SELECTED+=(snapper)
    contains root_config "${SNAPPER_OPTIONS[@]}" || SNAPPER_OPTIONS+=(root_config)
    contains snap_pac "${SNAPPER_OPTIONS[@]}" || SNAPPER_OPTIONS+=(snap_pac)
fi

# Cockpit's Machines module needs a working libvirt backend.
if contains cockpit_machines "${SERVER_OPTIONS[@]}"; then
    contains libvirt_service "${VIRT_OPTIONS[@]}" || VIRT_OPTIONS+=(libvirt_service)
    contains libvirt "${SELECTED[@]}" || SELECTED+=(libvirt)
    contains qemu "${SELECTED[@]}" || SELECTED+=(qemu)
fi

# Virtual Machine Manager is installed as a ready-to-use local libvirt setup:
# QEMU backend, daemon, dnsmasq-backed default NAT network.
if contains virt_manager "${SELECTED[@]}"; then
    contains libvirt_service "${VIRT_OPTIONS[@]}" || VIRT_OPTIONS+=(libvirt_service)
    contains libvirt_network "${VIRT_OPTIONS[@]}" || VIRT_OPTIONS+=(libvirt_network)
    contains libvirt "${SELECTED[@]}" || SELECTED+=(libvirt)
    contains qemu "${SELECTED[@]}" || SELECTED+=(qemu)
fi

# Options that require the libvirt daemon automatically include its service.
if contains libvirt_network "${VIRT_OPTIONS[@]}" || contains libvirt_group "${VIRT_OPTIONS[@]}" || contains virt_install "${VIRT_OPTIONS[@]}"; then
    contains libvirt_service "${VIRT_OPTIONS[@]}" || VIRT_OPTIONS+=(libvirt_service)
    contains libvirt "${SELECTED[@]}" || SELECTED+=(libvirt)
fi
if contains libvirt_service "${VIRT_OPTIONS[@]}"; then
    contains libvirt "${SELECTED[@]}" || SELECTED+=(libvirt)
fi
if contains virt_manager "${SELECTED[@]}" || contains libvirt "${SELECTED[@]}"; then
    contains qemu "${SELECTED[@]}" || SELECTED+=(qemu)
fi

if contains flatpak_apps "${SELECTED[@]}"; then
    select_nested "Flatpak Application Selection" \
        "Choose applications to install from Flathub. Waterfox replaces Firefox only after successful installation and confirmation." flatpak \
        waterfox "Waterfox browser (net.waterfox.waterfox)" "$(default_state waterfox)" \
        syncthingy "SyncThingy tray application (com.github.zocker_160.SyncThingy)" "$(default_state syncthingy)" || exit 0
fi

# Selecting a Cockpit module or its socket implicitly selects the Cockpit base package.
if contains cockpit_socket "${SERVER_OPTIONS[@]}" ||
   contains cockpit_storaged "${SERVER_OPTIONS[@]}" ||
   contains cockpit_machines "${SERVER_OPTIONS[@]}" ||
   contains cockpit_files "${SERVER_OPTIONS[@]}" ||
   contains cockpit_network "${SERVER_OPTIONS[@]}"; then
    contains cockpit "${SELECTED[@]}" || SELECTED+=(cockpit)
fi

# ----- Package plan -----------------------------------------------------------

contains steam "${SELECTED[@]}" && add_packages steam steam-devices
contains 8bitdo_pro2 "${SELECTED[@]}" && add_packages steam-devices
contains solaar "${SELECTED[@]}" && add_packages solaar
contains flatpak "${SELECTED[@]}" && add_packages flatpak
contains discover "${SELECTED[@]}" && add_packages discover flatpak
contains flatpak_restore "${SELECTED[@]}" && add_packages flatpak
contains podman "${SELECTED[@]}" && add_packages podman
contains compose "${PODMAN_OPTIONS[@]}" && add_packages podman-compose
contains docker "${PODMAN_OPTIONS[@]}" && add_packages podman-docker
contains distrobox "${SELECTED[@]}" && add_packages distrobox
contains tailscale "${SELECTED[@]}" && add_packages tailscale
contains tuned "${SELECTED[@]}" && add_packages tuned tuned-ppd
contains lact "${SELECTED[@]}" && add_packages lact
contains coolercontrol "${SELECTED[@]}" && add_packages coolercontrol
contains liquidctl "${COOLER_OPTIONS[@]}" && add_packages liquidctl
contains sensors "${COOLER_OPTIONS[@]}" && add_packages lm_sensors
contains snapper "${SELECTED[@]}" && add_packages snapper
contains snapper_updates "${SERVER_OPTIONS[@]}" && add_packages snapper snap-pac
contains auto_updates "${SELECTED[@]}" && add_packages pacman-offline snapper snap-pac
contains lts_kernel "${SERVER_OPTIONS[@]}" && add_packages linux-cachyos-lts
contains package_cache "${SERVER_OPTIONS[@]}" && add_packages pacman-contrib
contains snap_pac "${SNAPPER_OPTIONS[@]}" && add_packages snap-pac
contains assistant "${SNAPPER_OPTIONS[@]}" && add_packages btrfs-assistant

# Server and remote-access tools
if contains cockpit "${SELECTED[@]}"; then
    add_packages cockpit
    contains cockpit_storaged "${SERVER_OPTIONS[@]}" && add_packages cockpit-storaged
    contains cockpit_machines "${SERVER_OPTIONS[@]}" && add_packages cockpit-machines
    contains cockpit_files "${SERVER_OPTIONS[@]}" && add_packages cockpit-files
    contains cockpit_network "${SERVER_OPTIONS[@]}" && add_packages networkmanager
fi
contains sshd "${SELECTED[@]}" && add_packages openssh
contains nfs "${SELECTED[@]}" && add_packages nfs-utils

# Storage and virtualization
contains rclone "${SELECTED[@]}" && add_packages rclone
contains qemu "${SELECTED[@]}" && add_packages qemu-desktop
if contains libvirt "${SELECTED[@]}" || contains virt_manager "${SELECTED[@]}"; then
    add_packages qemu-desktop libvirt
fi
contains virt_manager "${SELECTED[@]}" && add_packages virt-manager
contains libvirt_network "${VIRT_OPTIONS[@]}" && add_packages dnsmasq
contains ovmf "${VIRT_OPTIONS[@]}" && add_packages edk2-ovmf
contains swtpm "${VIRT_OPTIONS[@]}" && add_packages swtpm
contains virt_viewer "${VIRT_OPTIONS[@]}" && add_packages virt-viewer
contains virt_install "${VIRT_OPTIONS[@]}" && add_packages virt-install

if contains flatpak_apps "${SELECTED[@]}"; then
    add_packages flatpak
fi
contains mystical_theme "${SELECTED[@]}" && add_packages git jq

save_profile

# ----- Review ----------------------------------------------------------------

SUMMARY="Selected packages:\n"
if (("${#PACKAGES[@]}" == 0)); then
    SUMMARY+="  (none)\n"
else
    for package in "${PACKAGES[@]}"; do SUMMARY+="  • $package\n"; done
fi
SUMMARY+="\nSelected actions:\n"
for item in "${SELECTED[@]}"; do SUMMARY+="  • $item\n"; done
for item in "${SERVER_OPTIONS[@]}"; do SUMMARY+="  • server: $item\n"; done
SUMMARY+="\nLog file: $LOG_FILE\n\nProceed?"
ui_confirm "$SUMMARY" || exit 0

# ----- Install packages -------------------------------------------------------

if (("${#PACKAGES[@]}" > 0)); then
    log "Installing packages: ${PACKAGES[*]}"
    sudo pacman -S --needed --noconfirm "${PACKAGES[@]}" 2>&1 | tee -a "$LOG_FILE"
fi

# ----- Optional KDE-to-headless conversion -----------------------------------

if contains headless "${SERVER_OPTIONS[@]}"; then
    if ui_confirm "HEADLESS CONVERSION\n\nThis removes the installed KDE Plasma desktop and KDE-specific applications, removes the KDE graphical login manager (SDDM or Plasma Login Manager), and sets the default boot target to multi-user.target. A reboot is required.\n\nYour current graphical session is left running until you reboot. Shared graphics drivers, Xorg/Wayland libraries, network tools, SSH, server applications, user files and containers are not deliberately removed. Review the package-manager removal transaction carefully."; then
        declare -a KDE_REMOVE_CANDIDATES=(
            plasma-meta kde-applications-meta plasma-desktop plasma-workspace plasma-wayland-session
            plasma-wayland-protocols plasma-login-manager plasma-x11-session kwin kwin-x11
            sddm sddm-kcm
            cachyos-kde-settings cachyos-emerald-kde-theme-git cachyos-nord-kde-theme-git
            char-white bluedevil kwayland-integration kinfocenter ark audiocd-kio
            breeze-gtk dolphin dragon ffmpegthumbs filelight gwenview haruna kate
            kcalc kdeconnect kde-gtk-config kdegraphics-thumbnailers kdeplasma-addons
            kdialog khotkeys kinit kio-admin kio-fuse konsole kscreen kwallet-pam
            kwalletmanager okular partitionmanager phonon-qt6-vlc plasma-browser-integration
            plasma-disks plasma-firewall plasma-nm plasma-pa
            plasma-systemmonitor plasma-thunderbolt plymouth-kcm powerdevil
            print-manager solid spectacle xsettingsd
        )
        declare -a KDE_REMOVE_INSTALLED=()
        # Include every installed member of Arch's Plasma package group so
        # future Plasma component splits are covered as well.
        while IFS= read -r package; do
            [[ -n "$package" ]] || continue
            contains "$package" "${KDE_REMOVE_INSTALLED[@]}" || KDE_REMOVE_INSTALLED+=("$package")
        done < <(pacman -Qqg plasma 2>/dev/null || true)
        for package in "${KDE_REMOVE_CANDIDATES[@]}"; do
            if pacman -Q "$package" >/dev/null 2>&1; then
                contains "$package" "${KDE_REMOVE_INSTALLED[@]}" || KDE_REMOVE_INSTALLED+=("$package")
            fi
        done

        # Include the package that owns the configured display-manager unit,
        # but do not touch a different display manager if it is not KDE-related.
        dm_unit_path="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
        dm_unit="$(basename "$dm_unit_path" 2>/dev/null || true)"
        if [[ -z "$dm_unit" ]]; then
            for candidate_unit in sddm.service plasma-login-manager.service; do
                if systemctl is-enabled --quiet "$candidate_unit" 2>/dev/null; then
                    dm_unit="$candidate_unit"
                    break
                fi
            done
        fi
        dm_package=""
        if [[ -n "$dm_unit_path" && -f "$dm_unit_path" ]]; then
            dm_package="$(pacman -Qqo "$dm_unit_path" 2>/dev/null || true)"
            if [[ -n "$dm_package" && "$dm_package" != "sddm" && "$dm_package" != "plasma-login-manager" ]]; then
                log "Active display manager is $dm_package ($dm_unit); preserving it because it is not the KDE login manager."
                dm_package=""
            fi
            if [[ -n "$dm_package" ]] && ! contains "$dm_package" "${KDE_REMOVE_INSTALLED[@]}"; then
                KDE_REMOVE_INSTALLED+=("$dm_package")
            fi
        fi

        if (("${#KDE_REMOVE_INSTALLED[@]}" == 0)); then
            log "No known KDE Plasma packages were found to remove."
            ui_message "No known KDE Plasma packages from the supported CachyOS KDE package set were found. No packages were removed."
        else
            log "KDE/headless removal candidates: ${KDE_REMOVE_INSTALLED[*]}"
            removal_summary="The following installed packages will be passed to pacman -Rns:\n\n"
            for package in "${KDE_REMOVE_INSTALLED[@]}"; do removal_summary+="• $package\n"; done
            removal_summary+="\nPacman may also offer to remove unused dependencies. Review its transaction and answer no if it proposes removing anything you need.\n\nContinue?"
            if ui_confirm "$removal_summary"; then
                previous_target="$(systemctl get-default 2>/dev/null || printf 'graphical.target')"
                dm_was_enabled="no"
                if [[ -n "$dm_unit" ]] && systemctl is-enabled --quiet "$dm_unit" 2>/dev/null; then
                    dm_was_enabled="yes"
                    log "Disabling display manager for next boot (without stopping the current session): $dm_unit"
                    sudo systemctl disable "$dm_unit" 2>&1 | tee -a "$LOG_FILE"
                fi
                if sudo pacman -Rns "${KDE_REMOVE_INSTALLED[@]}" 2>&1 | tee -a "$LOG_FILE"; then
                    log "Setting the default systemd target to multi-user.target."
                    sudo systemctl set-default multi-user.target
                    log "KDE Plasma package removal completed. Reboot to enter headless mode."
                    ui_message "KDE Plasma removal completed. The system default is now multi-user.target and the KDE display manager is disabled. Your current graphical session has not been forcibly stopped. Reboot when ready to start in headless mode.\n\nIf pacman declined any package removal, review the log and handle remaining packages manually."
                else
                    log "WARNING: pacman did not complete KDE package removal; restoring previous boot settings."
                    if [[ "$dm_was_enabled" == "yes" && -n "$dm_unit" ]]; then
                        sudo systemctl enable "$dm_unit" 2>&1 | tee -a "$LOG_FILE" || true
                    fi
                    sudo systemctl set-default "$previous_target" 2>&1 | tee -a "$LOG_FILE" || true
                    ui_message "Pacman did not complete the removal. The previous boot target and display-manager enablement have been restored where possible. Review the log before trying again."
                fi
            else
                log "User cancelled KDE/headless package removal."
            fi
        fi
    else
        log "User declined KDE-to-headless conversion."
    fi
fi

# ----- 8BitDo Pro 2 Steam Input support --------------------------------------

if contains 8bitdo_pro2 "${SELECTED[@]}"; then
    rule_file="/etc/udev/rules.d/71-8bitdo-pro2-steam-input.rules"
    log "Installing 8BitDo Pro 2 Steam Input hidraw access rules."
    sudo tee "$rule_file" >/dev/null <<'UDEV_RULES'
# 8BitDo 2.4 GHz / wired hidraw access for Steam Input
KERNEL=="hidraw*", ATTRS{idVendor}=="2dc8", MODE="0660", TAG+="uaccess"

# 8BitDo Bluetooth hidraw access for Steam Input
KERNEL=="hidraw*", KERNELS=="*2DC8:*", MODE="0660", TAG+="uaccess"
UDEV_RULES
    sudo chmod 0644 "$rule_file"
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=hidraw
    log "Installed 8BitDo Pro 2 udev rules. Reconnect the controller to apply them."
    ui_message "8BitDo Pro 2 Steam Input support was configured.\n\nSet the controller's mode switch to D (DInput), then connect it by USB or Bluetooth. Disconnect and reconnect it now, then restart Steam if it was already open.\n\nIn Steam, enable Steam Input for the game and open the controller layout editor. The rear buttons should be available as separate inputs.\n\nIf they still do not appear, check Steam Settings > Controller > Test Device Inputs and verify the controller is detected in DInput mode."
fi

# ----- Flatpak / Discover -----------------------------------------------------

if contains flatpak "${SELECTED[@]}" || contains discover "${SELECTED[@]}" || contains flatpak_apps "${SELECTED[@]}"; then
    log "Adding system Flathub remote"
    sudo flatpak remote-add --if-not-exists --system flathub \
        https://flathub.org/repo/flathub.flatpakrepo
fi

if contains flatpak_backup "${SELECTED[@]}"; then
    backup_flatpaks
fi
if contains flatpak_restore "${SELECTED[@]}"; then
    restore_flatpaks
fi

if contains flatpak_apps "${SELECTED[@]}"; then
    if ! require_command flatpak; then
        log "ERROR: Flatpak command is unavailable; skipping selected Flatpak apps."
    else
        if contains waterfox "${FLATPAK_OPTIONS[@]}"; then
            log "Installing Waterfox Flatpak for the current user."
            if flatpak install --user --noninteractive --assumeyes flathub net.waterfox.waterfox 2>&1 | tee -a "$LOG_FILE"; then
                if pacman -Q firefox >/dev/null 2>&1 && ui_confirm "Waterfox is installed. Remove the system Firefox package now? This removes only the pacman package named 'firefox'."; then
                    sudo pacman -R --noconfirm firefox 2>&1 | tee -a "$LOG_FILE"
                fi
            else
                log "WARNING: Waterfox Flatpak installation failed; system Firefox was left untouched."
            fi
        fi
        if contains syncthingy "${FLATPAK_OPTIONS[@]}"; then
            flatpak install --user --noninteractive --assumeyes flathub com.github.zocker_160.SyncThingy 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
fi

# ----- Podman -----------------------------------------------------------------

if contains system_socket "${PODMAN_OPTIONS[@]}"; then
    enable_system_service podman.socket
fi
if contains user_socket "${PODMAN_OPTIONS[@]}"; then
    enable_user_service podman.socket
fi
if contains linger "${PODMAN_OPTIONS[@]}"; then
    log "Enabling lingering for $USER"
    sudo loginctl enable-linger "$USER"
fi


# ----- Server tools -----------------------------------------------------------

if contains cockpit_socket "${SERVER_OPTIONS[@]}"; then
    enable_system_service cockpit.socket
fi
if contains cockpit_network "${SERVER_OPTIONS[@]}"; then
    enable_system_service NetworkManager.service
fi
if contains sshd_service "${SERVER_OPTIONS[@]}" && contains sshd "${SELECTED[@]}"; then
    enable_system_service sshd.service
fi
if contains nfs_service "${SERVER_OPTIONS[@]}" && contains nfs "${SELECTED[@]}"; then
    enable_system_service nfs-server.service
fi

# Package cache maintenance: paccache.timer retains the last three
# cached package versions by default and runs on its packaged schedule.
if contains package_cache "${SERVER_OPTIONS[@]}"; then
    enable_system_service paccache.timer
fi

if contains update_guidance "${SERVER_OPTIONS[@]}"; then
    ui_message "Conservative update workflow:\n\n• Updates remain manual unless you explicitly enable Scheduled automatic CachyOS updates.\n• Before a full upgrade, make sure important data is backed up and any selected Snapper pre/post Pacman snapshots are working.\n• Use 'sudo pacman -Syu' for a manual full system upgrade; avoid partial upgrades.\n• For extra caution, wait briefly after major CachyOS/kernel/Mesa updates and check release notes before upgrading.\n• Keep the regular kernel installed alongside linux-cachyos-lts, and verify both boot entries before relying on the LTS kernel."
fi

# ----- Virtualization ---------------------------------------------------------

if contains libvirt_service "${VIRT_OPTIONS[@]}"; then
    enable_system_service libvirtd.service
fi
if contains libvirt_network "${VIRT_OPTIONS[@]}"; then
    if sudo virsh -c qemu:///system net-info default >/dev/null 2>&1; then
        sudo virsh -c qemu:///system net-autostart default 2>&1 | tee -a "$LOG_FILE"
        if ! sudo virsh -c qemu:///system net-info default 2>/dev/null | grep -q 'Active:.*yes'; then
            sudo virsh -c qemu:///system net-start default 2>&1 | tee -a "$LOG_FILE" || \
                log "WARNING: Could not start libvirt's default NAT network."
        fi
    elif ui_confirm "The libvirt 'default' NAT network does not exist. Create it now? This creates the standard 192.168.122.0/24 NAT network (virbr0) and enables it to start automatically with libvirt."; then
        network_xml="$(mktemp)"
        cat > "$network_xml" <<'XML'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
XML
        if sudo virsh -c qemu:///system net-define "$network_xml" 2>&1 | tee -a "$LOG_FILE" &&
           sudo virsh -c qemu:///system net-autostart default 2>&1 | tee -a "$LOG_FILE" &&
           sudo virsh -c qemu:///system net-start default 2>&1 | tee -a "$LOG_FILE"; then
            log "Created, enabled and started libvirt's default NAT network."
        else
            log "WARNING: Could not create or start libvirt's default NAT network. Review the log."
        fi
        rm -f "$network_xml"
    else
        log "User declined creation of the missing libvirt default NAT network."
    fi
fi
if contains libvirt_group "${VIRT_OPTIONS[@]}"; then
    if getent group libvirt >/dev/null 2>&1; then
        if id -nG "$USER" | tr ' ' '\n' | grep -Fxq libvirt; then
            log "User $USER is already a member of the libvirt group."
        else
            sudo usermod -aG libvirt "$USER"
            log "Added $USER to libvirt group. Log out and back in for membership to take effect."
        fi
    else
        log "WARNING: libvirt group was not found; package installation may have failed."
    fi
fi

# ----- Tailscale / TuneD / LACT ----------------------------------------------

contains tailscale_service "${SELECTED[@]}" && enable_system_service tailscaled.service
contains tuned_service "${TUNED_OPTIONS[@]}" && enable_system_service tuned.service
contains ppd_service "${TUNED_OPTIONS[@]}" && enable_system_service tuned-ppd.service
contains lact_service "${SELECTED[@]}" && enable_system_service lactd.service

# ----- CoolerControl ----------------------------------------------------------

if contains daemon "${COOLER_OPTIONS[@]}"; then
    enable_system_service coolercontrold.service
fi
if contains detect "${COOLER_OPTIONS[@]}"; then
    if require_command sensors-detect; then
        log "Starting sensors-detect. Review each proposed change before accepting."
        sudo sensors-detect 2>&1 | tee -a "$LOG_FILE"
    else
        log "sensors-detect is unavailable; install lm_sensors to use this option."
    fi
fi

# CoolerControl hardware-specific kernel modules and boot parameters are NOT
# guessed or written automatically. Detection results must be reviewed first.

# ----- Snapper ----------------------------------------------------------------

if contains snapper "${SELECTED[@]}"; then
    ROOT_FS="$(findmnt -n -o FSTYPE / || true)"
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        log "Root filesystem is $ROOT_FS, not Btrfs; skipping root Snapper setup."
    else
        if contains root_config "${SNAPPER_OPTIONS[@]}"; then
            if ! sudo snapper -c root get-config >/dev/null 2>&1; then
                if ui_confirm "Create a Snapper configuration for /? This assumes the root Btrfs subvolume layout is suitable."; then
                    sudo snapper -c root create-config /
                else
                    log "User skipped root Snapper configuration."
                fi
            else
                log "Root Snapper configuration already exists; leaving it unchanged."
            fi
        fi
        if contains snap_pac "${SNAPPER_OPTIONS[@]}"; then
            if ! sudo snapper -c root get-config >/dev/null 2>&1; then
                log "WARNING: snap-pac is installed but root Snapper configuration is missing."
            fi
        fi
        contains timeline "${SNAPPER_OPTIONS[@]}" && enable_system_service snapper-timeline.timer
        contains cleanup "${SNAPPER_OPTIONS[@]}" && enable_system_service snapper-cleanup.timer
    fi
fi

# ----- Scheduled CachyOS offline updates --------------------------------------

if contains auto_updates "${SELECTED[@]}"; then
    if ! sudo snapper -c root get-config >/dev/null 2>&1; then
        log "ERROR: Scheduled updates were selected, but the root Snapper configuration is unavailable. The update timer was not installed."
        ui_message "Automatic updates were not configured because the root Snapper configuration is unavailable. Configure Snapper for / and run the setup again."
    elif [[ ! -f /etc/pacman.d/offline.conf ]] || ! command -v pacman-offline >/dev/null 2>&1; then
        log "ERROR: pacman-offline or its /etc/pacman.d/offline.conf configuration is missing."
        ui_message "Automatic updates were not configured because pacman-offline did not install its expected configuration. Check the package installation log."
    else
        if ! grep -Eq '^[[:space:]]*Include[[:space:]]*=[[:space:]]*/etc/pacman.d/offline\.conf([[:space:]]|$)' /etc/pacman.conf; then
            pacman_backup="/etc/pacman.conf.cachyos-setup-$(date +%Y%m%d-%H%M%S).bak"
            pacman_tmp="$(mktemp)"
            sudo cp -a /etc/pacman.conf "$pacman_backup"
            if sudo awk '
                { print }
                /^\[options\][[:space:]]*$/ && !inserted {
                    print "Include = /etc/pacman.d/offline.conf"
                    inserted=1
                }
                END { if (!inserted) exit 1 }
            ' /etc/pacman.conf > "$pacman_tmp"; then
                sudo install -m 0644 "$pacman_tmp" /etc/pacman.conf
                log "Added pacman-offline configuration include; backup: $pacman_backup"
            else
                log "ERROR: Could not locate the [options] section in /etc/pacman.conf. Automatic updates were not enabled."
                rm -f "$pacman_tmp"
                exit 1
            fi
            rm -f "$pacman_tmp"
        fi

        sudo tee /usr/local/sbin/cachyos-setup-auto-update >/dev/null <<'AUTO_UPDATE_SCRIPT'
#!/usr/bin/bash
set -Eeuo pipefail
exec 9>/run/lock/cachyos-setup-auto-update.lock
flock -n 9 || exit 0
exec >> /var/log/cachyos-setup-auto-update.log 2>&1
printf '\n[%s] Starting scheduled CachyOS offline update.\n' "$(date --iso-8601=seconds)"
if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" != "btrfs" ]]; then
    echo "ERROR: Root filesystem is no longer Btrfs; refusing to update without the configured snapshot workflow."
    exit 1
fi
if ! snapper -c root get-config >/dev/null 2>&1; then
    echo "ERROR: Snapper root configuration is unavailable; refusing scheduled update."
    exit 1
fi
snapper -c root create --type single --cleanup-algorithm number --description "Before scheduled CachyOS update"
pacman-offline -y
if [[ -e /system-update ]]; then
    echo "Offline update prepared; rebooting to apply it."
    systemctl reboot
else
    echo "No updates were prepared; no reboot is necessary."
fi
AUTO_UPDATE_SCRIPT
        sudo chmod 0755 /usr/local/sbin/cachyos-setup-auto-update

        sudo tee /etc/systemd/system/cachyos-setup-auto-update.service >/dev/null <<'AUTO_UPDATE_SERVICE'
[Unit]
Description=Prepare scheduled CachyOS offline update with a Snapper snapshot
Wants=network-online.target
After=network-online.target
ConditionPathIsExecutable=/usr/local/sbin/cachyos-setup-auto-update

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/usr/local/sbin/cachyos-setup-auto-update
AUTO_UPDATE_SERVICE

        sudo tee /etc/systemd/system/cachyos-setup-auto-update.timer >/dev/null <<AUTO_UPDATE_TIMER
[Unit]
Description=Scheduled CachyOS offline system update

[Timer]
OnCalendar=$AUTO_UPDATE_CALENDAR
Persistent=false
AccuracySec=1min
RandomizedDelaySec=0

[Install]
WantedBy=timers.target
AUTO_UPDATE_TIMER
        sudo systemctl daemon-reload
        sudo systemctl enable --now cachyos-setup-auto-update.timer
        sudo systemctl restart cachyos-setup-auto-update.timer
        log "Enabled scheduled CachyOS offline updates: $AUTO_UPDATE_CALENDAR"

        # Restart-policy containers can be restored by Podman's restart unit.
        # Quadlet/systemd-managed containers are started by their own units.
        if require_command podman; then
            enable_system_service podman-restart.service || log "WARNING: Could not enable the system Podman restart unit."
            enable_user_service podman-restart.service || log "WARNING: Could not enable the user Podman restart unit."
            if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
                if ui_confirm "Podman is installed. Enable user lingering for $USER so rootless Podman services can start at boot before login? Containers still need restart policies or enabled user systemd/Quadlet units."; then
                    sudo loginctl enable-linger "$USER"
                    log "Enabled user lingering for rootless Podman startup."
                else
                    log "NOTE: User lingering was not enabled; rootless containers may wait until the user logs in."
                fi
            fi
        fi
        ui_message "Scheduled CachyOS offline updates are enabled.\n\nSchedule: $AUTO_UPDATE_CALENDAR\nA Snapper snapshot is created before each update preparation. If updates are available, pacman-offline stages them and the machine reboots to apply them. The timer does not catch up missed runs while the machine is off.\n\nEnabled system services and configured Podman restart/systemd units can start after reboot; containers without restart policies or enabled units will not be started automatically."
    fi
fi

# ----- Zed --------------------------------------------------------------------

if contains zed "${SELECTED[@]}"; then
    log "Installing Zed using its official installer"
    if curl -f https://zed.dev/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; then
        if require_command fish; then
            fish -c 'fish_add_path -U "$HOME/.local/bin"'
        fi
    else
        log "WARNING: Zed installer failed."
    fi
fi


# ----- Lyd Ark Mystical KDE theme --------------------------------------------

if contains mystical_theme "${SELECTED[@]}"; then
    THEME_COMMIT="d6db4c654497cfcc125ff0c9439c4afd03f0e2fe"
    THEME_REPO="https://github.com/lydiaperspective/lyd-ark-themes.git"
    theme_tmp="$(mktemp -d)"
    log "Fetching Lyd Ark Mystical theme at pinned revision $THEME_COMMIT"
    if git clone --quiet --filter=blob:none --no-checkout "$THEME_REPO" "$theme_tmp/repo" &&
       git -C "$theme_tmp/repo" checkout --quiet "$THEME_COMMIT" -- themes/mystical; then
        theme_root="$theme_tmp/repo/themes/mystical"
        color_file="$(find "$theme_root" -type f -path '*/colors/Mystical.colors' -print -quit)"
        lookandfeel_dir=""
        if [[ -d "$theme_root/look-and-feel" ]]; then
            lookandfeel_dir="$(find "$theme_root/look-and-feel" -mindepth 1 -maxdepth 1 -type d -print -quit)"
        fi
        if [[ -n "$color_file" ]]; then
            mkdir -p "$HOME/.local/share/color-schemes"
            install -m 0644 "$color_file" "$HOME/.local/share/color-schemes/Mystical.colors"
            log "Installed Mystical KDE color scheme."
        else
            log "WARNING: Mystical.colors was not found in the pinned theme source."
        fi
        if [[ -n "$lookandfeel_dir" ]] && require_command kpackagetool6; then
            if kpackagetool6 --type Plasma/LookAndFeel --install "$lookandfeel_dir" 2>&1 | tee -a "$LOG_FILE"; then
                log "Installed Mystical Plasma Look-and-Feel package."
                if require_command plasma-apply-lookandfeel && ui_confirm "Apply the installed Mystical global theme now? This changes the current Plasma appearance."; then
                    plugin_id=""
                    metadata_file="$(find "$lookandfeel_dir" -maxdepth 2 -type f \( -name metadata.json -o -name metadata.desktop \) -print -quit)"
                    if [[ -n "$metadata_file" ]] && require_command jq && [[ "$metadata_file" == *.json ]]; then
                        plugin_id="$(jq -r '.KPlugin.Id // empty' "$metadata_file")"
                    elif [[ -n "$metadata_file" ]]; then
                        plugin_id="$(sed -n 's/^X-KDE-PluginInfo-Name=//p' "$metadata_file" | head -n1)"
                    fi
                    if [[ -n "$plugin_id" ]]; then
                        plasma-apply-lookandfeel --apply "$plugin_id" 2>&1 | tee -a "$LOG_FILE"
                    else
                        log "WARNING: Could not determine the Mystical Look-and-Feel plugin ID; theme installed but not automatically applied."
                    fi
                fi
            else
                log "WARNING: Could not install the Mystical Look-and-Feel package."
            fi
        else
            log "WARNING: KDE Plasma package tools were not found; color scheme was installed only if available."
        fi
    else
        log "WARNING: Could not download the pinned Lyd Ark Mystical theme revision."
    fi
    rm -rf "$theme_tmp"
fi

# ----- KDE Plasma backup / restore --------------------------------------------

KDE_BACKUP_ROOT="$HOME/.local/share/cachyos-setup/kde-backups"
KDE_FILES=(
    plasma-org.kde.plasma.desktop-appletsrc
    plasmashellrc
    plasmarc
    kdeglobals
)
if contains kwin "${KDE_OPTIONS[@]}"; then
    KDE_FILES+=(kwinrc kwinrulesrc)
fi
if contains shortcuts "${KDE_OPTIONS[@]}"; then
    KDE_FILES+=(kglobalshortcutsrc)
fi

if contains kde_backup "${SELECTED[@]}"; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    destination="$KDE_BACKUP_ROOT/plasma-$timestamp"
    mkdir -p "$destination"
    copied=0
    for file in "${KDE_FILES[@]}"; do
        if [[ -f "$HOME/.config/$file" ]]; then
            cp -a "$HOME/.config/$file" "$destination/"
            ((copied+=1))
        fi
    done
    if (( copied > 0 )); then
        tar -czf "$destination.tar.gz" -C "$KDE_BACKUP_ROOT" "plasma-$timestamp"
        log "KDE backup created: $destination.tar.gz"
    else
        log "No recognized Plasma configuration files were found."
    fi
fi

if contains kde_restore "${SELECTED[@]}"; then
    mkdir -p "$KDE_BACKUP_ROOT"
    mapfile -t backups < <(find "$KDE_BACKUP_ROOT" -maxdepth 1 -type f -name 'plasma-*.tar.gz' -printf '%f\n' | sort -r)
    if (("${#backups[@]}" == 0)); then
        ui_message "No KDE backups were found in:\n$KDE_BACKUP_ROOT"
    else
        choices=()
        for backup in "${backups[@]}"; do choices+=("$backup" "Plasma configuration backup"); done
        chosen="$(ui_menu "Choose a KDE backup to restore:" "${choices[@]}")" || chosen=""
        if [[ -n "$chosen" ]] && ui_confirm "Restore $chosen? Existing configuration files will first be backed up."; then
            restore_dir="$KDE_BACKUP_ROOT/restore-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$restore_dir"
            for file in "${KDE_FILES[@]}"; do
                [[ -f "$HOME/.config/$file" ]] && cp -a "$HOME/.config/$file" "$restore_dir/"
            done
            tar -xzf "$KDE_BACKUP_ROOT/$chosen" -C "$KDE_BACKUP_ROOT"
            source_dir="$KDE_BACKUP_ROOT/${chosen%.tar.gz}"
            for file in "$source_dir"/*; do
                [[ -f "$file" ]] && cp -a "$file" "$HOME/.config/"
            done
            log "Restored KDE settings from $chosen. Log out and back in to fully apply panel changes."
        fi
    fi
fi

log "Setup run finished."
ui_message "CachyOS setup run finished.\n\nLog file:\n$LOG_FILE\n\nReview warnings before rebooting."
