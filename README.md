# neohiro/linux
[![Platform](https://img.shields.io/badge/platform-Linux-lightgray.svg)](https://github.com/)
[![Supported distros](https://img.shields.io/badge/distros-Ubuntu%20%7C%20Debian%20%7C%20RHEL%20%7C%20Fedora%20%7C%20SUSE%20%7C%20Arch%20%7C%20Amazon%20Linux-blue.svg)](#supported-distributions)

Cross-distro general-purpose setup & hardening script. Auto-detects the
distribution and the package manager, and adapts every step accordingly —
package names, firewall tool, security tooling, kernel update path, and
unattended-upgrades availability.

Offers a more secure starting point for any new super user.

## Supported distributions

| Family       | Distros                                           | Package manager | Firewall    | Notes |
|--------------|---------------------------------------------------|----------------|-------------|-------|
| Debian       | Ubuntu (incl. 24.04 LTS, 22.04, 20.04), Debian 12/11 | `apt`      | `ufw`       | full feature set (unattended-upgrades, AppArmor) |
| RHEL         | RHEL 8/9, AlmaLinux 8/9, Rocky 8/9, CentOS Stream | `dnf`    | `firewalld` | AppArmor replaced by SELinux |
| Legacy RHEL  | CentOS 7, RHEL 7                                  | `yum`          | `firewalld` | legacy; no `dnf` |
| Amazon Linux | Amazon Linux 2023                                 | `dnf`          | `firewalld` | RHEL-compatible; SELinux enforcing by default |
| Fedora       | Fedora 39+                                       | `dnf`          | `firewalld` | AppArmor not on by default — uses SELinux |
| SUSE         | openSUSE Leap 15, SLES 15                       | `zypper`       | `firewalld` | AppArmor profile packages available |
| Arch         | Arch Linux, Manjaro                              | `pacman`       | `firewalld` | AppArmor / fail2ban via AUR |

> Distribution is detected from `/etc/os-release` (with `ID_LIKE` fallback).
> The package manager is then selected from the order `pacman → zypper → dnf
> → yum → apt`, so Arch derivatives pick `pacman`, SUSE picks `zypper`,
> RHEL/Fedora pick `dnf`, Debian/Ubuntu pick `apt`. No manual flag required.

## One-step automated setup

Run the general interactive script directly from the repo — it prompts you
per category (environment type, SSH lockout-prone steps, ambiguous DNS/Tor/
IPv6 choices, and the new helper scripts are fetched on-demand):

```bash
curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/linuxinstall.sh | sudo bash
```

> Review it first:
> `curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/linuxinstall.sh | less`

**Profiles:** the script asks which profile to apply — Recommended (safe),
Standard (full hardening + SSH), Full (everything including Tor/IPv6/ASR/
DeepClean), or Custom (you confirm every step). Risky actions (SSH
hardening, IPv6, DNS method, Tor, attack-surface reduction) always prompt
individually before touching anything.

**Full profile on a server runs in "auto" mode:** SSH hardening is applied
without the interactive lockout-prone prompts (it never disables
`PasswordAuthentication` unless it detects a working pubkey, and it never
changes the port), so the only way to get locked out is the OpenSSH config
breaking — in which case the in-script `restore_ssh` routine or Tailscale
SSH can get you back in.

**Progress checklist:** the script prints a colored bar chart (e.g.
`━━━ PROGRESS ████████████░░░░ 12/17 (70%) ━━━`) before every step, so you
always see what's already done and what's coming.

### Cross-distro kernel update

`linuxinstall.sh` auto-detects the package manager and updates the kernel
and all system packages in one pass. The mapping is:

| Family                          | Command                          |
|---------------------------------|----------------------------------|
| Debian / Ubuntu                 | `apt full-upgrade -y`            |
| RHEL 8+ / AlmaLinux 8/9 / Rocky | `dnf upgrade --refresh -y`       |
| Fedora                          | `dnf upgrade --refresh -y`       |
| Legacy CentOS 7 / RHEL 7        | `yum update -y`                  |
| openSUSE Leap 15 / SLES 15      | `zypper update -y`               |
| Arch / Manjaro                  | `pacman -Syu --noconfirm`        |

After updating, the script:

1. Runs the package manager's built-in autoremove/orphan cleanup.
2. On `apt` only: also runs `purge-old-kernels` (if present) and prunes
   the oldest installed `linux-image-*` / `linux-headers-*` packages,
   keeping the running kernel and one spare. Pruned package names are
   printed before removal so you can cancel by re-running with `N` to
   the prune prompt.
3. Compares the newest installed kernel in `/boot/vmlinuz-*` to
   `uname -r`; if they differ, sets `_KERNEL_UPDATE_PENDING=1`.
4. The end-of-run summary offers a reboot (never auto-reboots mid-run).

No HWE, no mainline, no edge kernels. The script does not change the
running kernel — a reboot is the user's choice.

### Run summary and rollback

At the end of the run the script prints a colored bar-chart summary of
what it actually did (packages upgraded/installed, services hardened,
sysctls applied, firewall rules, auth keys, Tor services, config files
backed up, approximate disk freed). Every config file it modifies is
copied to a timestamped backup and appended to a single log:

```bash
cat /var/log/linux-install-rollback.log
# format: original_path<TAB>backup_path
# restore any file with: sudo cp <backup_path> <original_path>
```

Before touching anything, the script also scans for existing SSH public
keys, prints a recovery ed25519 key it generates on the server (so you
can `scp` it to your laptop), and refuses to disable
`PasswordAuthentication` until a fresh key has been validated.

### Running over SSH (resumable)

If you launch the script over SSH, the very first thing it does is detect
the SSH session and automatically re-exec itself inside a detached `tmux`
session named `linux-setup`, so a transient network blip won't abort the
run.

**Before you do anything that might disconnect (dnf upgrade, firewalld
reload, SSH restart, etc.)** copy this line — you'll need it to re-attach
after a disconnect:

```bash
tmux attach -t linux-setup
```

If you were disconnected entirely, log back in over SSH and run
`tmux attach -t linux-setup` to rejoin the session. If you started the
one-liner from a local terminal (not over SSH), the tmux wrap is skipped
automatically and there's nothing to re-attach to. When the script
finishes successfully, the tmux session closes itself; if it fails, the
session is left intact for inspection.

## Reconnecting after a reboot or lockout

**Tailscale SSH bypasses OpenSSH settings** — it authenticates via the
Tailscale identity layer, so it works even when `PasswordAuthentication=no`
or the sshd service is down. Prefer Tailscale SSH for recovery.

**Automatic recovery (SSH self-heal guard):** the script can install a
self-heal guard that runs at every boot and every 60 seconds. If sshd
ever becomes unreachable, the guard:
- re-validates `sshd -t`
- re-opens the SSH port in firewalld / UFW if it was dropped
- restarts sshd if it stopped
- re-enables `PasswordAuthentication yes` if a lockout is detected
  (only when no pubkeys are installed)

It is offered automatically at the end of `harden_ssh` when you answer
"yes" to the "use remote SSH?" prompt. You can also install it
standalone, remove it, or trigger a check manually:

```bash
sudo bash linuxinstall.sh --install-self-heal  # install
sudo bash linuxinstall.sh --self-heal          # trigger now (used by cron)
sudo bash linuxinstall.sh --no-self-heal       # remove
```

On systemd systems the guard is a `systemd` timer (`neohiro-ssh-watchdog.timer`)
that fires 30s after boot and every 60s thereafter. On systems without
systemd (e.g. some minimal images) it installs as a `cron.d` job with
`@reboot` and `* * * * *` entries. Every action is logged to
`/var/log/neohiro-ssh-watchdog.log`.

**Quick recovery (from any working session — console, Tailscale SSH, or
out-of-band):**

```bash
# 1. Diagnose and auto-fix most lockout causes
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/restore_ssh.sh)"
# or, equivalently, via the main script's first-class menu entry
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/linuxinstall.sh)" --restore-ssh

# 2. Or undo every config change the script made (dry-run):
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/linuxinstall.sh)" --rollback

# 3. Or do it manually — re-enable password auth, restart sshd
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart sshd
```

> Package names differ by distro: `apt` uses `openssh-server`, `dnf`/`yum`
> also use `openssh-server`, but `zypper` and `pacman` use `openssh`.
> The script's `restore_ssh` routine handles this automatically.

**Specific causes and fixes:**

| Symptom | Likely cause | Fix |
|---|---|---|
| `Connection refused` after reboot | sshd not running or listening on wrong port | `sudo systemctl restart sshd; sudo ss -tulnp \| grep sshd` |
| `No route to host` | firewalld / UFW blocking | `sudo firewall-cmd --add-service=ssh --permanent && sudo firewall-cmd --reload` (RHEL/Fedora) — or `sudo ufw allow ssh` (Debian/Ubuntu) |
| `Permission denied (publickey)` | Port changed to non-22 | `ssh -p 2222 user@host` |
| OpenSSH lockout (no pubkey, PasswordAuth=no) | Only possible if you have Tailscale SSH or console access | `restore_ssh` routine above, or out-of-band console |

**Out-of-band console only (no SSH at all):** boot cloud provider rescue
ISO or use Hetzner/DO/Vultr recovery console, mount root, then:
```bash
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /mnt/etc/ssh/sshd_config
sed -i 's/^Port .*/Port 22/' /mnt/etc/ssh/sshd_config
# or restore a backup: ls /mnt/etc/ssh/sshd_config.bak.* && cp <latest> /mnt/etc/ssh/sshd_config
```

## Maintenance suite and SSH self-heal

The script's `main()` tree offers a **Maintenance suite** (distinctive
magenta header) and a **Restore SSH** entry (above Maintenance). The
Restore-SSH entry calls the same diagnostic routine that the
`--restore-ssh` flag and the standalone `restore_ssh.sh` script use.

The Maintenance suite itself is expanded to include:

| # | Option | What it does |
|---|---|---|
| 1–13 | system / dns / firewall / tor / ssh / fail2ban / unattended / ipv6 / sysctl / apparmor / pam / OptimizeLinuxASR / DeepClean | Re-run any step on demand |
| 14 | SSH diagnostics & lockout fix | Same routine as `--restore-ssh` |
| 15 | Authorized keys | List all keys in every user's `authorized_keys` |
| 16 | SSH config review | Print every key directive from `sshd_config` and drop-ins |
| 17 | SSH self-heal guard | Install / remove / status of the per-minute watchdog |
| 18 | Logs | Tail `/var/log/linux-install-rollback.log` and `/var/log/neohiro-ssh-watchdog.log` |
| 19 | System info | Uptime, load, memory, disk, CPU, listening ports |
| 20 | Back to main menu | — |

The self-heal guard runs as root via `systemd` or cron and **never
modifies `authorized_keys` or any credentials** — it only fixes config
and service state, so it cannot open the system to a new attacker.

## Manual steps (cross-distro)

The interactive script covers everything below, but the equivalent
commands per distribution family are listed for reference.

### Kernel + system update (manual)

Same logic as `update_kernel` inside `linuxinstall.sh`. Auto-detects the
package manager and updates kernel + system packages, then prunes old
kernels (keeps 2 newest on apt).

Debian / Ubuntu:
```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove --purge -y
```

RHEL 8+ / AlmaLinux / Rocky / Fedora:
```bash
sudo dnf upgrade --refresh -y
sudo dnf autoremove -y
```

Legacy CentOS 7 / RHEL 7:
```bash
sudo yum update -y
sudo yum autoremove -y
```

openSUSE Leap 15 / SLES 15:
```bash
sudo zypper refresh
sudo zypper update -y
```

Arch / Manjaro:
```bash
sudo pacman -Syu
sudo pacman -Qdtq | xargs -r sudo pacman -Rns
```

Verify and reboot (if kernel changed):
```bash
uname -r
# verify per-family:
dpkg -l 'linux-image-*' | grep '^ii'        # apt
rpm -q kernel                                # dnf / yum
rpm -q kernel-default                        # zypper
pacman -Q linux                              # pacman
sudo systemctl reboot
```

### Firewall

Debian / Ubuntu (UFW):
```bash
sudo apt install ufw -y
sudo ufw default allow outgoing
sudo ufw default deny incoming
sudo ufw allow ssh        # for servers
sudo ufw enable
sudo ufw status verbose
```

RHEL / Fedora / SUSE / Arch (firewalld):
```bash
sudo dnf install firewalld -y        # or yum / zypper / pacman
sudo systemctl enable --now firewalld
sudo firewall-cmd --add-service=ssh --permanent
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

### DNS-over-HTTPS (dnscrypt-proxy)

Install:
```bash
# apt
sudo apt install dnscrypt-proxy -y
# dnf / yum
sudo dnf install dnscrypt-proxy -y
# zypper
sudo zypper install dnscrypt-proxy
# pacman
sudo pacman -S dnscrypt-proxy
```

Point your system resolver at `127.0.0.2:53` (the listen address the
script writes). This is intentional — it avoids the systemd-resolved
stub on `127.0.0.53:53` and direct queries on `127.0.0.1`.

### Tor

```bash
# apt / dnf / yum / zypper
sudo <pkgmgr> install -y tor
# pacman (not in core — build from AUR)
yay -S tor
sudo systemctl enable --now tor
```

### Automatic security updates

Apt-based distros (Ubuntu / Debian):
```bash
sudo apt install unattended-upgrades -y
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

RHEL / Fedora / AlmaLinux / Rocky:
```bash
sudo dnf install dnf-automatic -y
sudo systemctl enable --now dnf-automatic.timer
# or dnf-automatic-install.timer for install-only
```

openSUSE:
```bash
sudo zypper install yast2-online-update-configuration
# configure: YaST2 → Online Update Configuration
```

Arch:
```bash
yay -S aur-auto-update    # AUR helper
```

> `linuxinstall.sh` installs and configures `unattended-upgrades` only on
> apt-based distros. On other families it prints a one-line suggestion
> and skips.

### Firmware, Secure Boot & Disk Encryption

```bash
sudo fwupdmgr refresh && sudo fwupdmgr update   # LVFS firmware
mokutil --sb-state                              # Secure Boot state
```

Full-disk encryption (LUKS) must be chosen at install time — on the next
reinstall tick it; it protects all data when the machine is powered off
or stolen. Verify clock sync:
```bash
timedatectl status
```

### Kernel Hardening (sysctl)

Save as `/etc/sysctl.d/99-hardening.conf` (identical on every distro):
```
# information disclosure
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.yama.ptrace_scope=1
kernel.kexec_load_disabled=1
kernel.sysrq=0
kernel.randomize_va_space=2
fs.suid_dumpable=0
fs.protected_symlinks=1
fs.protected_hardlinks=1
fs.protected_fifos=2
fs.protected_regular=2

# network stack
net.ipv4.ip_forward=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.tcp_syncookies=1
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
```

Apply:
```bash
sudo sysctl --system
```

### Mandatory Access Control: AppArmor vs SELinux

| Family                 | MAC system   | Status              | Script action |
|------------------------|--------------|---------------------|---------------|
| Debian / Ubuntu        | AppArmor     | default on          | install apparmor + apparmor-utils, enable service |
| openSUSE Leap / SLES   | AppArmor     | profiles available  | install apparmor-profiles + apparmor-utils, enable service |
| Arch / Manjaro         | AppArmor     | AUR                 | print AUR hint (`yay -S apparmor apparmor-utils`) |
| RHEL / Fedora / Alma / Rocky / CentOS | SELinux | default enforcing | skip AppArmor; check `getenforce` is `Enforcing` |

On RHEL/Fedora, set permissive → enforcing with:
```bash
sudo setenforce 1
# permanent: /etc/selinux/config  ->  SELINUX=enforcing  (then reboot)
```

Check AppArmor profiles:
```bash
sudo aa-status
sudo aa-enforce /etc/apparmor.d/<profile>
```

### SSH Hardening

Prefer keys over passwords:
```bash
ssh-keygen -t ed25519
```

Then in `/etc/ssh/sshd_config`:
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30s
X11Forwarding no
AllowUsers <youruser>
```

Validate before you disconnect:
```bash
sudo sshd -t && sudo systemctl restart sshd
```

> The service unit is `ssh` on Debian/Ubuntu and `sshd` on RHEL/Fedora/
> SUSE/Arch. The script detects both.

### Passwords, lockouts & sessions

Stronger password quality — the script installs the right package per
distro (`libpam-pwquality` on apt, `libpwquality` on dnf/yum/zypper/
pacman). Then in `/etc/security/pwquality.conf`:
```
minlen = 14
minclass = 3
maxrepeat = 3
```

Lock accounts after failed logins — `/etc/security/faillock.conf`:
```
deny = 5
unlock_time = 900
```

Auto-close idle shells — `/etc/profile.d/99-tmout.sh`:
```bash
TMOUT=900; readonly TMOUT; export TMOUT
```

Tighten default umask (`UMASK 027` in `/etc/login.defs`) and forbid core
dumps — add to `/etc/security/limits.conf`:
```
* hard core 0
```

### Verify & maintain

```bash
sudo ufw status verbose                                # apt
sudo firewall-cmd --list-all                            # everything else
sudo rkhunter --check                                   # rootkit sweep
sudo aide --check                                       # file integrity
ss -tulnp                                               # re-check listeners
```

## Additional helpers

- **[Corrade.md](Corrade.md)** — Docker-based IR bot gateway (Docker required; works on all distros with `docker` installed).
- **[DNSPROXY.md](DNSPROXY.md)** — AdGuard dnsproxy in Docker, with cross-distro firewall commands (UFW for apt, firewalld for dnf/yum/zypper/pacman).
- **[SHADOWSOCKS-LIBEV.md](SHADOWSOCKS-LIBEV.md)** — Shadowsocks-libev SOCKS5 proxy, with cross-distro package names and firewall commands.

⭐ Stargaze to help others secure their Linux install

🔗 [frenzypenguin.media](https://linktr.ee/frenzypenguin.media)

---

<p align="center">
  <a href="https://github.com/sponsors/neohiro"><img src="https://img.shields.io/badge/Sponsor%20on%20GitHub-%E2%9D%A4-EA4AAA?logo=githubsponsors&style=for-the-badge" alt="GitHub Sponsors"></a>&nbsp;&nbsp;
  <a href="https://www.patreon.com/frenzypenguin_media"><img src="https://img.shields.io/badge/Patreon-frenzypenguin__media-F96854?logo=patreon&style=for-the-badge" alt="Support on Patreon"></a>
</p>



---

## 🔗 Related & Sponsorship

- 💖 [Sponsor neohiro on GitHub](https://github.com/sponsors/neohiro) — covers API + hosting costs
- 🌐 [neohiro.github.io](https://neohiro.github.io/) — main site
- 🎬 [FrenzyPenguin Media](https://neohiro.github.io/frenzypenguin-media/) — video deep-dives
- 🧬 [transhumanists](https://transhumanists.github.io/) — companion dashboard for human progress
