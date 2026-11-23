#!/usr/bin/env bash
# Unified entry point for the lyd Linux Setup Managers.
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$HOME/.config/lyd-linux-setup/profiles"
mkdir -p "$PROFILE_DIR"

ensure_whiptail() {
    command -v whiptail >/dev/null 2>&1 && return 0
    local os_id=""
    [[ -r /etc/os-release ]] && . /etc/os-release && os_id="${ID:-}"
    local install_cmd=""
    case "$os_id" in
        debian|ubuntu) install_cmd="sudo apt-get update && sudo apt-get install -y whiptail" ;;
        fedora|centos|rhel) install_cmd="sudo dnf install -y newt" ;;
        cachyos|arch|endeavouros|manjaro) install_cmd="sudo pacman -Sy --needed libnewt" ;;
        *) printf 'whiptail is required. Install the dialog package for your distribution first.\n' >&2; return 1 ;;
    esac
    printf 'The menu dependency (whiptail) is missing. Install it with:\n  %s\n' "$install_cmd"
    read -r -p "Install it now? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 1
    case "$os_id" in
        debian|ubuntu) sudo apt-get update && sudo apt-get install -y whiptail ;;
        fedora|centos|rhel) sudo dnf install -y newt ;;
        cachyos|arch|endeavouros|manjaro) sudo pacman -Sy --needed libnewt ;;
    esac
    command -v whiptail >/dev/null 2>&1
}

ensure_whiptail || exit 1

ui_menu() { whiptail --title "Lyd Linux Setup" --menu "$1" 20 82 12 "${@:2}" 3>&1 1>&2 2>&3; }
ui_msg() { whiptail --title "Lyd Linux Setup" --msgbox "$1" 14 82; }
ui_confirm() { whiptail --title "Lyd Linux Setup" --yesno "$1" 14 82; }

validate_profile() {
    local file="$1"
    [[ -f "$file" && -r "$file" ]] || return 1
    # Profiles are data files, never shell scripts. Only accept the known
    # simple key=value format used by the setup managers.
    grep -Eq '^version=[0-9]+$' "$file" || return 1
    grep -Eq '^selected=[A-Za-z0-9_,.-]*$' "$file" || return 1
    awk '
        /^[[:space:]]*$/ || /^#/ { next }
        /^[A-Za-z][A-Za-z0-9_]*=[A-Za-z0-9_,.-]*$/ { next }
        { exit 1 }
    ' "$file"
}

import_profile() {
    local source name destination
    source="$(whiptail --title "Import setup profile" --inputbox "Enter the full path to a profile .conf file:" 10 82 "$HOME/" 3>&1 1>&2 2>&3)" || return 0
    [[ -n "$source" ]] || return 0
    [[ "$source" == "~/"* ]] && source="$HOME/${source#~/}"
    if ! validate_profile "$source"; then
        ui_msg "That file is not a supported setup profile. Nothing was copied."
        return 1
    fi
    name="$(basename "$source")"
    [[ "$name" == *.conf ]] || { ui_msg "Profile files must use the .conf extension."; return 1; }
    destination="$PROFILE_DIR/$name"
    if [[ -e "$destination" ]] && ! ui_confirm "A profile named $name already exists. Overwrite it?"; then
        return 0
    fi
    install -m 600 -- "$source" "$destination"
    ui_msg "Imported profile:\n$destination\n\nIt is now available to all four setup managers."
}

export_profile() {
    local -a files=() choices=()
    local file choice destination
    mapfile -t files < <(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | sort)
    if (("${#files[@]}" == 0)); then
        ui_msg "No saved profiles were found in:\n$PROFILE_DIR"
        return 0
    fi
    for file in "${files[@]}"; do choices+=("$file" "Saved setup profile"); done
    choice="$(ui_menu "Choose a profile to copy out:" "${choices[@]}")" || return 0
    destination="$(whiptail --title "Export setup profile" --inputbox "Copy $choice to this path:" 10 82 "$HOME/$choice" 3>&1 1>&2 2>&3)" || return 0
    [[ -n "$destination" ]] || return 0
    [[ "$destination" == "~/"* ]] && destination="$HOME/${destination#~/}"
    if [[ -e "$destination" ]] && ! ui_confirm "The destination already exists. Overwrite it?"; then return 0; fi
    mkdir -p -- "$(dirname -- "$destination")"
    install -m 600 -- "$PROFILE_DIR/$choice" "$destination"
    ui_msg "Profile copied to:\n$destination"
}

while true; do
    distro="$(ui_menu "First, choose the distribution setup manager:" \
        cachyos "CachyOS" \
        fedora "Fedora KDE" \
        debian "Debian 13 (Trixie)" \
        centos "CentOS Stream 10" \
        quit "Exit")" || exit 0
    [[ "$distro" == quit ]] && exit 0

    case "$distro" in
        cachyos) script="cachyos-setup.sh"; label="CachyOS" ;;
        fedora) script="fedora-kde-setup.sh"; label="Fedora KDE" ;;
        debian) script="debian-13-setup.sh"; label="Debian 13" ;;
        centos) script="centos-stream-10-setup.sh"; label="CentOS Stream 10" ;;
    esac

    while true; do
        action="$(ui_menu "Selected: $label\n\nProfiles are shared between all setup managers." \
            run "Launch $label setup manager" \
            import "Import a profile from another system" \
            export "Copy a saved profile to another system" \
            back "Choose a different distribution" \
            quit "Exit")" || break
        case "$action" in
            run)
                [[ -f "$REPO_DIR/scripts/$script" ]] || { ui_msg "Could not find $REPO_DIR/scripts/$script"; continue; }
                exec bash "$REPO_DIR/scripts/$script"
                ;;
            import) import_profile ;;
            export) export_profile ;;
            back) break ;;
            quit) exit 0 ;;
        esac
    done
done
