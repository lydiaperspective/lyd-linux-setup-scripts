# Linux Setup Managers

Interactive post-install setup scripts for several Linux distributions. Each script is distribution-specific and should be run as the normal desktop/server user; it requests `sudo` only for system-level changes.

## Scripts

| Distribution | Script |
|---|---|
| CachyOS | [cachyos-setup.sh](./cachyos-setup.sh) |
| Fedora KDE 45 | [fedora-kde-setup.sh](./fedora-kde-setup.sh) |
| Debian 13 (Trixie) | [debian-13-setup.sh](./debian-13-setup.sh) |
| CentOS Stream 10 | [centos-stream-10-setup.sh](./centos-stream-10-setup.sh) |

## Quick start

Install Git and the dialog dependency for your distribution, clone this repository, and run the script for your system:

```bash
# Debian 13
sudo apt install -y git whiptail
git clone https://github.com/lydiaperspective/lyd-linux-setup-scripts.git
cd lyd-linux-setup-scripts
bash ./debian-13-setup.sh
```

For Fedora/CentOS, install `git` and `newt` with DNF. For CachyOS, install `git` and `libnewt` with pacman. Run the matching script from the cloned directory.

## Common behavior

- Whiptail-based task selection and confirmation before applying changes.
- Reusable selection profiles stored under `~/.config/<distribution>-setup/profiles/`.
- Timestamped run logs stored alongside the profiles.
- Scripts are intended to be rerun; selected tasks are applied only when chosen.
- No script automatically reboots the machine.
- Snapshot tools are installed without automatically changing disk/subvolume layouts.

## NVIDIA driver notes

- Fedora KDE 45 and CentOS Stream 10 offer the proprietary NVIDIA 580xx legacy branch through RPM Fusion. It is intended only for GPUs supported by that legacy branch. Secure Boot may require akmods signing-key enrollment; the scripts do not disable Secure Boot.
- Debian 13's official Trixie repository currently provides the proprietary 550 branch, not 580. The Debian script therefore offers Debian's packaged proprietary driver rather than adding a Debian 12 repository or using NVIDIA's standalone installer.

## Important

These are post-install helpers, not unattended provisioning or recovery tools. Review each selected task, package-manager transaction, and log. Repository availability and package names can change. Test on a non-critical system before relying on any script. The Fedora script is an initial implementation and may need package-name adjustments on particular Fedora 45 spins.
