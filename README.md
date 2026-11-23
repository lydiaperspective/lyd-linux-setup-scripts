# Linux Setup Managers

Interactive post-install setup managers for CachyOS, Fedora KDE, Debian 13, and CentOS Stream 10. The unified launcher lives at the repository root; individual distribution managers are kept in `scripts/`.

## Unified launcher (recommended)

The unified launcher asks which distribution you want to configure, then starts that distribution's setup manager:

```bash
git clone https://github.com/lydiaperspective/lyd-linux-setup-scripts.git
cd lyd-linux-setup-scripts
bash ./lyd-linux-setup.sh
```

The launcher can also import a profile file from another computer or export a saved profile to copy elsewhere. It installs the small `whiptail` menu dependency only after asking permission if it is missing.

## Individual setup managers

You can also run a manager directly:

| Distribution | Script |
|---|---|
| CachyOS | [cachyos-setup.sh](./scripts/cachyos-setup.sh) |
| Fedora KDE | [fedora-kde-setup.sh](./scripts/fedora-kde-setup.sh) |
| Debian 13 (Trixie) | [debian-13-setup.sh](./scripts/debian-13-setup.sh) |
| CentOS Stream 10 | [centos-stream-10-setup.sh](./scripts/centos-stream-10-setup.sh) |

Run the matching script with Bash as your normal user, not with `sudo`. Each manager requests elevated privileges when needed.

## Shared, portable profiles

All four managers now use the same profile directory:

```
~/.config/lyd-linux-setup/profiles/
```

- A profile saved by any manager is visible to the other managers on that computer.
- Use **Import a profile** in the unified launcher to copy a `.conf` profile from another computer into the shared directory.
- Use **Export a profile** to copy a saved profile to a USB drive, network share, or another location.
- Profiles are plain data files; the scripts parse them and never execute or source them as shell code.
- Common task IDs carry across distributions, and the managers translate a few equivalent names (for example, CachyOS `sshd` to the other managers' `ssh`, and CachyOS QEMU/libvirt selections to the other managers' `virtualization` task). Options without a meaningful equivalent are ignored. CachyOS also stores additional nested component choices, which are only meaningful to its own manager.
- Existing profiles in the older per-distro directories are not automatically moved. Copy any old `.conf` files you want to keep into the shared directory, or import them with the launcher.

A profile stores selections, not a complete system image. Package names, services, drivers, desktop environments, and supported features differ by distribution; always review the target manager's selections before applying them.

## Common behavior

- Whiptail-based task selection and confirmation before applying changes.
- Timestamped logs stored alongside each manager's profile directory.
- Scripts are intended to be rerun; selected tasks are applied only when chosen.
- No manager automatically reboots the machine.
- Snapshot tools are installed without automatically changing disk/subvolume layouts.
- Debian 13 also has an optional **Gaming tweaks** task. It installs GameMode, MangoHud and vkBasalt, creates a conservative per-user MangoHud configuration without overwriting an existing one, and records opt-in Steam launch options. It does not force CPU governors, overclock hardware, or apply global kernel/security changes.
- Debian 13 also offers an optional **lydhelp** command reference. It installs a local terminal help command with beginner-friendly topics for files, folders, searching, permissions, storage, processes, networking, APT and archives.
- Debian 13 also offers an optional **Btrfs mount tweaks** task. It detects whether `/` is Btrfs, backs up `/etc/fstab`, adds `noatime` and `compress=zstd:3` to the Btrfs root entry, remounts and verifies the options, and restores the backup if verification fails. It does not partition disks or create subvolumes.


## NVIDIA driver notes


- Fedora KDE and CentOS Stream 10 offer the proprietary NVIDIA 580xx legacy branch through RPM Fusion. It is intended only for GPUs supported by that legacy branch. Secure Boot may require akmods signing-key enrollment; the scripts do not disable Secure Boot.
- Debian 13's official Trixie repository provides the proprietary 550 branch, not 580. The Debian manager therefore offers Debian's packaged proprietary driver rather than adding a mismatched Debian 12 repository or using NVIDIA's standalone installer.

## Important

These are post-install helpers, not unattended provisioning or recovery tools. Review each selected task, package-manager transaction, and log. Repository availability and package names can change. Test on a non-critical system before relying on them. The Fedora script is an initial implementation and may need package-name adjustments on particular Fedora spins.
