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

configure_btrfs_mount_options() {
  local fstype tmp backup
  fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  if [[ "$fstype" != btrfs ]]; then
    msg "The currently mounted root filesystem is '$fstype', not Btrfs. No changes were made. This option only adjusts an existing Btrfs root filesystem."
    log "Skipped Btrfs mount tweaks: root filesystem is $fstype."
    return 0
  fi

  msg "This adds noatime and compress=zstd:3 to the Btrfs root entry in /etc/fstab. It preserves your UUID, subvolume settings and other mount options, and creates a timestamped backup first."
  confirm "Apply the Btrfs mount options to /?" || return 0

  tmp="$(mktemp)"
  backup="/etc/fstab.lyd-backup-$(date +%Y%m%d-%H%M%S)"
  if ! sudo cp -a /etc/fstab "$backup"; then
    rm -f "$tmp"
    die "Could not back up /etc/fstab. No changes were made."
  fi

  if ! awk '
    BEGIN { found=0 }
    /^[[:space:]]*#/ || NF < 4 { print; next }
    $2 == "/" && $3 == "btrfs" {
      found=1
      n=split($4, opts, ",")
      noatime=0
      compress=0
      rebuilt=""
      for (i=1; i<=n; i++) {
        if (opts[i] == "noatime") noatime=1
        if (opts[i] ~ /^compress=/) {
          if (!compress) {
            rebuilt = rebuilt (rebuilt == "" ? "" : ",") "compress=zstd:3"
            compress=1
          }
        } else {
          rebuilt = rebuilt (rebuilt == "" ? "" : ",") opts[i]
        }
      }
      if (!noatime) rebuilt = rebuilt (rebuilt == "" ? "" : ",") "noatime"
      if (!compress) rebuilt = rebuilt (rebuilt == "" ? "" : ",") "compress=zstd:3"
      $4=rebuilt
    }
    { print }
    END { if (!found) exit 3 }
  ' /etc/fstab > "$tmp"; then
    rm -f "$tmp"
    sudo rm -f "$backup"
    msg "No Btrfs root entry was found in /etc/fstab. No changes were made."
    log "Skipped Btrfs mount tweaks: no Btrfs root entry in /etc/fstab."
    return 0
  fi

  if ! sudo install -o root -g root -m 644 "$tmp" /etc/fstab; then
    rm -f "$tmp"
    msg "Could not update /etc/fstab. The backup is at $backup."
    return 1
  fi
  rm -f "$tmp"

  if ! sudo mount -o remount /; then
    sudo cp -a "$backup" /etc/fstab
    sudo mount -o remount / || true
    msg "The remount failed. The original /etc/fstab was restored from $backup."
    log "Btrfs mount tweak failed; restored original fstab."
    return 1
  fi

  if ! findmnt -n -o OPTIONS / | grep -q 'noatime' || ! findmnt -n -o OPTIONS / | grep -q 'compress=zstd:3'; then
    sudo cp -a "$backup" /etc/fstab
    sudo mount -o remount / || true
    msg "The requested options could not be verified as active. The original /etc/fstab was restored from $backup."
    log "Btrfs mount tweak verification failed; restored original fstab."
    return 1
  fi

  log "Enabled noatime and compress=zstd:3 for the Btrfs root mount. Backup: $backup"
  msg "Btrfs mount options configured successfully.\n\nActive options: noatime, compress=zstd:3\nBackup: $backup"
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
tasks=(system_update "Update all installed packages" desktop_tools "KDE/desktop utilities and media tools" gaming_tweaks "Install gaming performance tools and user MangoHud config" btrfs_tweaks "Configure noatime and zstd compression on Btrfs root" woman_alias "Add woman command as an alias for man" lydhelp "Install the lydhelp terminal command guide" flatpak "Install Flatpak and Flathub" podman "Install Podman and Compose" tuned "Install TuneD" snapper "Install Snapper" cockpit "Install Cockpit" ssh "Install OpenSSH server" tailscale "Install Tailscale" virtualization "Install QEMU/KVM and virt-manager" nvidia "Install Debian proprietary NVIDIA driver (550)" auto_updates "Configure scheduled automatic updates" headless "Convert KDE installation to headless")
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
    lydhelp)
      sudo tee /usr/local/bin/lydhelp >/dev/null <<'LYDHELP'
#!/bin/sh
# Beginner-friendly command reference installed by Lyd Linux Setup.
topic="${1:-help}"
case "$topic" in
  help|-h|--help)
    cat <<'HELP'
lydhelp - a beginner-friendly Linux terminal reference

Usage:
  lydhelp                 Show available topics
  lydhelp files           Work with files and learn common options
  lydhelp folders         Navigate and manage directories
  lydhelp search          Find files and search inside text
  lydhelp permissions     Understand permissions and ownership
  lydhelp storage         Check disks and available space
  lydhelp processes       Inspect and manage running programs
  lydhelp network         Check network connections
  lydhelp packages        Install, update and inspect Debian packages
  lydhelp archives        Create and extract common archives

Each topic explains what commands do, what common options mean, and
shows examples. These examples are references; read a command before
running it, especially if it changes or deletes files.
HELP
    ;;
  files)
    cat <<'FILES'
FILES: listing, inspecting, copying, moving and deleting files

  ls -lah
    List files in the current directory.
    -l  long format (permissions, owner, size, date)
    -a  include hidden names (those beginning with a dot)
    -h  human-readable sizes such as KiB and MiB

  file report.pdf
    Identify a file by its contents, not just its filename extension.

  stat report.pdf
    Show detailed metadata: size, permissions, owner and timestamps.

  cp source.txt backup.txt
    Copy a file. The first path is the source; the second is the destination.
  cp -av Documents/ backup/
    Copy a directory and its contents.
    -a  archive mode; preserve useful attributes and copy directories
    -v  verbose; print each item being copied

  mv old-name.txt new-name.txt
    Move or rename a file.
  mv -i file.txt Documents/
    -i  ask before overwriting an existing destination

  touch notes.txt
    Create an empty file, or update its modification timestamp.

  mkdir -p projects/demo
    Create a directory, including missing parent directories.
    -p  do not complain if the directory already exists

  ln -s /path/to/original shortcut
    Create a symbolic link (a pointer to another file or directory).
    -s  make a symbolic link rather than a hard link

  du -sh Documents/
    Show the total space used by a directory.
    -s  summary total rather than every item
    -h  human-readable sizes

  wc -l notes.txt
    Count lines in a text file.
    -l  count lines; -w counts words; -c counts bytes

  head -n 20 notes.txt
    Show the first 20 lines.
    -n  choose the number of lines

  tail -f application.log
    Show the end of a file and keep following new lines.
    -f  follow updates; Ctrl+C stops following

  less notes.txt
    Read a long text file one screen at a time. Press q to quit.

  nano notes.txt
    Open a simple terminal text editor.

  rm file.txt
    Delete a file. There is normally no recycle bin in the terminal.
  rm -r old-folder/
    Delete a directory and its contents. Be very careful.
    -r  recursive; -f forces removal and suppresses prompts.
    Avoid rm -rf unless you fully understand the exact path.

TIP: Quote paths containing spaces, for example:
  cp "my notes.txt" "my notes backup.txt"
FILES
    ;;
  folders)
    cat <<'FOLDERS'
FOLDERS: moving around the filesystem

  pwd
    Print the current working directory (where you are).

  ls
    List names in the current directory. Try ls -lah for details.

  cd Documents
    Enter a directory.
  cd ..
    Go to the parent directory.
  cd ~
    Go to your home directory.
  cd -
    Return to the previous directory.

  mkdir -p projects/demo
    Create nested directories if needed.

  tree -L 2
    Display a directory tree up to two levels deep (install tree if needed).

PATH NOTES:
  /       filesystem root
  ~       your home directory
  .       current directory
  ..      parent directory
  ./file  a file in the current directory
FOLDERS
    ;;
  search)
    cat <<'SEARCH'
SEARCH: find files and text

  find . -name "*.pdf"
    Find PDF-named files under the current directory.
    .          start here; use /path/to/folder to search elsewhere
    -name      match a filename (case-sensitive)
    "*.pdf"    quotes stop the shell expanding the wildcard too early

  find . -iname "*report*"
    Find names containing report, ignoring uppercase/lowercase.
    -iname     case-insensitive filename match

  grep -n "error" application.log
    Search text inside a file.
    -n         show matching line numbers
    -i         ignore letter case
    -r         search directories recursively
    -I         skip binary files

  grep -rnI "TODO" ./src
    Search recursively for TODO in text files under ./src.

  command -v python
    Show which executable would run for a command name.
SEARCH
    ;;
  permissions)
    cat <<'PERMISSIONS'
PERMISSIONS: read, write, execute and ownership

  ls -l file
    The first field shows permissions, for example -rw-r--r--.
    r = read, w = write, x = execute.
    The three groups are owner, group and everyone else.

  chmod u+x script.sh
    Add execute permission for the file owner.
    u  owner; g group; o others; a everyone
    +  add a permission; - remove; = set exactly
    r  read; w write; x execute

  chmod 644 file.txt
    Numeric permissions: 4=read, 2=write, 1=execute.
    644 means owner read/write; group and others read-only.

  chown user:group file
    Change the owner and group (normally requires sudo).

  umask
    Show the default permission mask used when creating files.

TIP: Avoid chmod 777 as a general fix. It grants everyone broad access.
PERMISSIONS
    ;;
  storage)
    cat <<'STORAGE'
STORAGE: disks, mounts and space

  df -h
    Show free and used space on mounted filesystems.
    -h  human-readable sizes

  du -sh ~/Downloads
    Show how much space a directory uses.
    -s  summary; -h human-readable

  lsblk -f
    List block devices, partitions, filesystems and mount points.
    -f  include filesystem details and labels

  findmnt
    Show mounted filesystems and where they are mounted.

  free -h
    Show memory and swap usage. This is RAM, not disk storage.

  sudo smartctl -a /dev/sdX
    Show drive health information (requires smartmontools).
    Replace /dev/sdX with the correct device; do not guess the device.
STORAGE
    ;;
  processes)
    cat <<'PROCESSES'
PROCESSES: running programs and system activity

  ps aux
    Show running processes.
    a  processes from all users; u user-oriented columns; x include services
      without a terminal

  top
    Interactive live view of CPU and memory use. Press q to quit.

  pgrep -a firefox
    Find processes by name and show their command lines.

  kill PID
    Ask a process to exit normally. Replace PID with its process ID.
  kill -TERM PID
    Send the normal termination signal explicitly.
  kill -KILL PID
    Force-stop a process; use only when normal termination fails.

  systemctl status service-name
    Inspect a system service.
  journalctl -u service-name
    Read logs for a system service.
PROCESSES
    ;;
  network)
    cat <<'NETWORK'
NETWORK: basic connection checks

  ip address
    Show network interfaces and their IP addresses.
  ip route
    Show routing information and the default gateway.
  ping -c 4 debian.org
    Send four test packets to check basic connectivity.
    -c 4  stop after four packets

  getent hosts debian.org
    Check whether a hostname resolves to an address.
  ss -tulpn
    Show listening TCP/UDP sockets and associated processes.
    -t TCP; -u UDP; -l listening; -p process; -n numeric addresses/ports
    sudo may be needed to see process details for all users.
NETWORK
    ;;
  packages)
    cat <<'PACKAGES'
PACKAGES: Debian APT basics

  apt search keyword
    Search package names and descriptions.
  apt show package-name
    Show package information and dependencies.
  sudo apt update
    Refresh the local package lists; this does not install upgrades.
  sudo apt upgrade
    Upgrade installed packages where possible.
  sudo apt install package-name
    Install a package.
  sudo apt remove package-name
    Remove a package but usually keep its configuration files.
  sudo apt purge package-name
    Remove a package and its system configuration files.
  sudo apt autoremove
    Offer to remove dependencies that are no longer needed.

TIP: Read APT's proposed changes before confirming, especially removals.
PACKAGES
    ;;
  archives)
    cat <<'ARCHIVES'
ARCHIVES: compressed files

  tar -tf archive.tar
    List the contents of a tar archive without extracting it.
    -t list; -f use the archive filename

  tar -xf archive.tar
    Extract a tar archive into the current directory.
    -x extract; -f use the archive filename

  tar -czf backup.tar.gz folder/
    Create a gzip-compressed tar archive.
    -c create; -z gzip compression; -f archive filename

  unzip archive.zip
    Extract a ZIP archive.
  unzip -l archive.zip
    List ZIP contents without extracting.

TIP: Inspect archive contents before extracting files you do not trust.
ARCHIVES
    ;;
  *)
    printf "Unknown topic: %s\n\n" "$topic" >&2
    printf "Run 'lydhelp' to see available topics.\n" >&2
    exit 2
    ;;
esac
LYDHELP
      sudo chmod 755 /usr/local/bin/lydhelp
      log "Installed /usr/local/bin/lydhelp."
      msg "Installed lydhelp. Try 'lydhelp', 'lydhelp files' or 'lydhelp search' in a terminal."
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
