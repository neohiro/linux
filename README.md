# neohiro/linux
[![Platform](https://img.shields.io/badge/platform-Linux-lightgray.svg)](https://github.com/)
[![Supported distros](https://img.shields.io/badge/distros-Ubuntu%20%7C%20Debian%20%7C%20RHEL%20%7C%20Fedora%20%7C%20SUSE%20%7C%20Arch%20%7C%20Amazon%20Linux-blue.svg)](#supported-distributions)
[![CI](https://github.com/neohiro/linux/actions/workflows/tests.yml/badge.svg)](.github/workflows/tests.yml)

> **One script. Every distro. Safe to run over SSH.**
>
> Auto-detects Ubuntu, Debian, RHEL, AlmaLinux, Rocky, CentOS, Fedora,
> Amazon Linux, openSUSE, SLES, Arch, and Manjaro from `/etc/os-release` —
> then picks the right package manager, firewall, MAC system, and service
> unit for that family. Same prompt, same outcome, on any box you own.

## Why it exists

A fresh server or VPS comes with a long list of defaults that are **wrong
for anything exposed to the internet** — password SSH, no firewall,
unattended-upgrades off, no MAC, the running kernel from the install ISO,
no log rotation. Fixing that by hand means reading 7 manpages and getting
the package name right per distro. This script:

- **One-liner, zero install.** `curl | bash` with no prerequisites; the
  script fetches its own helpers on demand.
- **Resumable over SSH.** Auto-wraps itself in a detached `tmux` session
  on the first prompt, so a dropped connection never aborts a long
  `dnf upgrade`. Reattach with `tmux attach -t linux-setup`.
- **Refuses to lock you out.** SSH hardening will not touch
  `PasswordAuthentication` until a fresh ed25519 key has been validated,
  and it never changes the port. A self-heal watchdog (systemd timer or
  cron) re-opens the port and re-enables password auth if sshd ever dies.
- **Rollback log per file.** Every config it edits is backed up to a
  timestamped copy; the index lives at `/var/log/linux-install-rollback.log`
  and is one `cp` away from a full undo.
- **HTTPS-only package transport, enforced before every download.** A
  plaintext `http://` mirror lets anyone on the path swap a `.deb`/`.rpm`/wheel
  for their own. The guard audits **every** app store on the box — apt, dnf,
  yum, zypper, pacman, apk, flatpak, snap, docker, brew, pip, npm, cargo,
  gem, nix, fwupd — rewrites apt automatically with rollback if a mirror
  can't speak TLS, and reports the rest. See
  [Package transport security](#package-transport-security-https).
- **Three security profiles + a 21-tool maintenance suite.** From
  "Recommended" (firewall + updates, 6 steps, no SSH risk) to "Full"
  (Tor + IPv6 disable + ASR + deep clean, 12 steps). Maintenance menu
  re-runs any step on a live box without re-hardening.

## At a glance

| What you get | How |
|---|---|
| Firewall (UFW on apt, firewalld everywhere else) | Default-deny incoming; opens SSH only if you say so |
| Kernel + full system update | `apt full-upgrade` / `dnf upgrade` / `zypper update` / `pacman -Syu` — auto-detected |
| Old-kernel prune | Keeps running kernel + one spare; prints names before removing |
| SSH hardening | `PasswordAuthentication no` gated on validated pubkey; port never changed |
| Fail2ban, sysctl profile, AppArmor/SELinux check | per-distro package names |
| Tor, dnscrypt-proxy, unattended-upgrades, DeepClean | optional per profile |
| **HTTPS-only package transport** | enforced before every `apt`/`dnf`/`yum`/`zypper`/`pacman`/`apk`/`pip`/`npm`/… download — `--apt-https` |
| **Rollback log** | `/var/log/linux-install-rollback.log` — `original\tbackup` per file |
| **SSH self-heal** | `--install-self-heal` — systemd timer or cron, every 60s |
| **21-tool maintenance suite** | Re-runs any step, lists keys, tails logs, dumps config |

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/linuxinstall.sh | sudo bash -s --
```

> Read it first:
> `curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/linuxinstall.sh | less`

The script prompts you per category. **Full profile on a server runs in
auto mode** — SSH hardening is applied without the interactive lockout-
prone prompts (it never disables `PasswordAuthentication` unless it
detects a working pubkey, and it never changes the port), so the only
way to get locked out is the OpenSSH config breaking — in which case
the in-script `restore_ssh` routine or Tailscale SSH gets you back in.

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

### Package transport security (HTTPS)

A plaintext `http://` mirror means anyone who can intercept the route — a
hostile Wi-Fi, a compromised router, an upstream CDN node — can swap the
`.deb` / `.rpm` / `.pkgz` / wheel you just downloaded for one of theirs.
Signature checks catch *forged* packages, but they do not stop a
*downgrade* to an older, genuinely-signed, vulnerable build. Only TLS on
the transport closes that gap.

So every entry point in this repo runs a guard **before** anything is
fetched. It is the first workflow step (on every profile, including
Custom), it runs once per process, and it is idempotent, so re-runs and
`--auto` are cheap.

```bash
# Apply it on its own (normally automatic)
sudo bash linuxinstall.sh --apt-https

# Report only; never modifies anything. Exit 1 if anything is plaintext.
sudo bash linuxinstall.sh --apt-https-audit

# Undo: restore every backup and remove the policy drop-in.
sudo bash linuxinstall.sh --apt-https-off

# Or standalone, no installer needed:
sudo bash lib/apt-https.sh            # enforce
sudo bash lib/apt-https.sh --report   # audit
sudo bash lib/apt-https.sh --revert   # undo
```

#### What is checked

This is **not** apt-specific. Every distro and language has its own "app
store", and several ship plaintext HTTP by default. The audit spans all of
them and only lists the ones actually installed:

| Store | Where the transport is configured |
|---|---|
| `apt` | `/etc/apt/sources.list`, `sources.list.d/*.list`, DEB822 `*.sources` |
| `dnf` / `yum` | `/etc/yum.repos.d/*.repo` (`baseurl`, `metalink`, `mirrorlist`, `gpgkey`) |
| `zypper` | `/etc/zypp/repos.d/*.repo` |
| `pacman` | `/etc/pacman.d/*` (`Server=`) |
| `apk` (Alpine) | `/etc/apk/repositories` — **plaintext `http://` by default on many images** |
| `flatpak` | `flatpak remotes` |
| `snap` | store is snapd-managed; no operator-configurable transport |
| `docker` | `/etc/docker/daemon.json` (`registry-mirrors`, `insecure-registries`) |
| `brew` | `HOMEBREW_BREW_GIT_REMOTE`, `HOMEBREW_API_DOMAIN`, … |
| `pip` | `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`, `pip.conf` |
| `npm` | `NPM_CONFIG_REGISTRY`, `.npmrc` |
| `cargo` | `CARGO_REGISTRIES_CRATES_IO_INDEX`, `~/.cargo/config.toml` |
| `gem` | `GEM_SOURCE`, `.gemrc` |
| `nix` | `nix.conf` (`substituters`, `channel`) |
| `fwupd` | `/etc/fwupd/remotes.d/*.conf` (LVFS `UpdateURI`) |

Detection is deliberately format-agnostic: **any non-comment line carrying an
`http://` URL** is reported. A per-dialect key list would miss `gpgkey=`,
`metalink=`, and whatever the next release adds — and a miss is exactly the
failure this is meant to prevent. The one exception is JSON, which has no
comment syntax: there, `http://` must sit at the start of a JSON string, so a
`"_comment": "see http://docs.internal"` note is not mistaken for a registry.

`--apt-https-audit` prints a per-store verdict:

```
━━━ App-store transport security (HTTPS) ━━━
  Package manager:                   apt
  [x] apt policy drop-in active: /etc/apt/apt.conf.d/99neohiro-force-https

  Store                           Result
  apt (Debian/Ubuntu/Mint/Pop!/Kali) https only
  apk (Alpine)                   2 plaintext endpoint(s)
      /etc/apk/repositories:1: http://dl-cdn.alpinelinux.org/alpine/v3.19/main
  pip index                      1 plaintext endpoint(s)
      /etc/pip.conf:2: index-url = http://pypi.internal/simple
```

#### What is changed automatically

Only **apt** is rewritten unattended, because it is the one store where the
result can be *verified*: after rewriting, a real `apt-get update` runs, and if
a mirror turns out not to serve the same paths over TLS the rewrite is **rolled
back automatically**. You are never left with a broken package manager.

1. Installs `/etc/apt/apt.conf.d/99neohiro-force-https`:

   ```text
   Acquire::https::AllowRedirect "true";   // https -> https redirects are fine
   Acquire::http::AllowRedirect  "false";  // https -> http  is REFUSED, not followed
   Acquire::https::Verify-Peer  "true";
   Acquire::https::Verify-Host  "true";
   Acquire::Retries             "3";
   ```

   The anti-downgrade line is the important one: without it, an
   `https://` mirror can silently bounce you down to `http://`.

2. Rewrites `http://` → `https://` on active lines in
   `/etc/apt/sources.list`, `sources.list.d/*.list` (classic) and
   `sources.list.d/*.sources` (DEB822 `URIs:` field only).
   Commented-out lines and DEB822 structural fields (`Suites:`,
   `Components:`, `Signed-By:`) are left byte-identical.

3. Backs every file up to `/var/backups/neohiro-apt-https/` **before** the
   first edit and records each in the rollback log, so
   `bash linuxinstall.sh --rollback --apply` can undo it too.

4. Applies each change with a **staging file in the same directory followed by
   `rename(2)`**, not `cp` into place. `cp` truncates first, so a crash
   mid-copy leaves a truncated `sources.list`; a rename is atomic, so a reader
   sees either the whole old file or the whole new one. Original mode and
   ownership are preserved.

5. Warns if no CA trust store is present, since HTTPS verification is
   worthless without one.

#### Changing the others

For every other store the guard **reports but does not rewrite**. Whether
`https://<same host><same path>` actually exists cannot be known without a
network round trip, and silently breaking a working mirror is worse than the
threat it prevents. Two options:

```bash
# Repoint the endpoint at an https-capable mirror (recommended), or
NEOHIRO_APT_HTTPS_REWRITE=1 sudo bash linuxinstall.sh --apt-https
```

The opt-in sweeps **every** installed store (apk, pip, npm, cargo, gem, nix,
docker, fwupd, and the RPM/Arch/SUSE repo formats) in one pass, backing each
up and honouring the same atomic replace. Re-audit afterwards, because some
mirrors genuinely do not serve the same paths over TLS. Stores whose tool is
not installed are left alone.

`NEOHIRO_APT_HTTPS_STRICT=1` turns any leftover plaintext endpoint into a
hard error, which is what you want in CI.

#### Where it is wired in

`pkg_update` / `pkg_install` / `pkg_upgrade` / `pkg_autoremove`,
`update_system`, `update_kernel`, `updates_only_mode`, `restore_ssh.sh`
(before installing `openssh-server`), `DeepClean.sh` (before
`apt-get autoremove --purge`), the **Maintenance** submenu option 1, the
`--step apt_https` mode, and the `--apt-https*` flags.

In `lib/updater.sh` it guards the `_run_all_updates` dispatcher plus every
sub-step that touches the network: `_update_apt`, `_update_dnf`,
`_update_yum`, `_update_zypper`, `_update_pacman`, `_update_snap`,
`_update_flatpak`, `_update_docker`, `_update_brew`, `_update_firmware`,
`_update_geoip`, `_update_pihole`. (`_update_virsh`, `_update_suse_snapper`
and `_update_btrfs_balance` only read or write local state, so they are
deliberately not guarded.)

Two subtleties worth knowing:

- **Fetched subscripts get the guard too.** `run_remote_script` pulls
  `DeepClean.sh` / `OptimizeLinuxASR.sh` into a temp directory, and a script
  resolves its helpers relative to its own location — so without help it
  would find no `lib/`, and its `apt-get autoremove --purge` would run
  unguarded even though the parent had already enforced. The installer
  therefore prefetches `lib/apt-https.sh` next to the subscript. If a
  subscript is `curl | bash`'d entirely on its own and finds no library, it
  says so out loud rather than skipping the precaution silently.
- **`GEOIP_URL` must be `https://`.** It is the one operator-supplied
  download target in the update engine, and a GeoIP database decides which
  country a packet counts as being in — a tampered copy is a
  traffic-tunneling primitive. An `http://` value is refused outright.

`OptimizeLinuxASR.sh` does not download packages, so it needs no guard.

#### Under `curl | sudo bash`

`curl ... | sudo bash` has no `lib/` directory next to it. Rather than carry
a second copy of this logic (which is how fixes silently fail to reach the
most common install path), the script resolves `lib/apt-https.sh` from disk
if present, otherwise fetches it from the same raw base it already trusts for
`DeepClean.sh`, and sources that. If neither is possible it says so loudly
and runs with the guard inactive — it never pretends to be enforcing.

| Variable | Effect |
|---|---|
| `NEOHIRO_APT_HTTPS=1` | enforce (default) |
| `NEOHIRO_APT_HTTPS=audit` | report only, never modify |
| `NEOHIRO_APT_HTTPS=0` | disable the guard entirely |
| `NEOHIRO_APT_HTTPS_REWRITE=1` | also rewrite the non-apt stores |
| `NEOHIRO_APT_HTTPS_NOVERIFY=1` | skip the post-rewrite `apt-get update` check |
| `NEOHIRO_APT_HTTPS_STRICT=1` | treat leftover plaintext as a hard error |
| `NEOHIRO_APT_BLOCK_PORT80=1` | also `ufw deny out 80/tcp` (opt-in, see below) |
| `NEOHIRO_APT_FAMILY=apt\|dnf\|yum\|zypper\|pacman\|none` | pin the detected family (CI containers, testing) |

### Optional: block port 80 entirely

If you want belt-and-braces so that *no* process can open an unencrypted
package connection, add an outbound deny rule:

```bash
sudo bash linuxinstall.sh --apt-https      # make sure every repo is https first
sudo ufw deny out 80/tcp && sudo ufw reload
# or: NEOHIRO_APT_BLOCK_PORT80=1 sudo bash linuxinstall.sh --apt-https
```

This is **opt-in** because a blanket outbound block also breaks unrelated
plaintext protocols (local registries, metrics endpoints, captive-portal
checks). The guard refuses to add the rule while any plaintext repo is
still configured, since that would only break those repos.

Verify:

```bash
sudo ufw status | grep -E '80/tcp|Status'     # outbound DENY present
sudo bash linuxinstall.sh --apt-https-audit   # exit 0 = no plaintext repos left
```

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
curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/restore_ssh.sh | sudo bash -s --
# or, equivalently, via the main script's first-class menu entry
curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/linuxinstall.sh | sudo bash -s -- --restore-ssh

# 2. Or undo every config change the script made (dry-run):
curl -fsSL https://raw.githubusercontent.com/neohiro/linux/main/linuxinstall.sh | sudo bash -s -- --rollback

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
| 1 | Force HTTPS for package repos | Enforces TLS for every repo before any download; prints the resulting state |
| 2–14 | system / dns / firewall / tor / ssh / fail2ban / unattended / ipv6 / sysctl / apparmor / pam / OptimizeLinuxASR / DeepClean | Re-run any step on demand |
| 15 | SSH diagnostics & lockout fix | Same routine as `--restore-ssh` |
| 16 | Authorized keys | List all keys in every user's `authorized_keys` |
| 17 | SSH config review | Print every key directive from `sshd_config` and drop-ins |
| 18 | SSH self-heal guard | Install / remove / status of the per-minute watchdog |
| 19 | Logs | Tail `/var/log/linux-install-rollback.log` and `/var/log/neohiro-ssh-watchdog.log` |
| 20 | System info | Uptime, load, memory, disk, CPU, listening ports |
| 21 | Back to main menu | — |

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

### Testing

```bash
bash tests/run-all.sh                  # every suite, with a summary
bash tests/test_linuxinstall.sh        # 67 tests: parse, logic, UX coverage, snapshot
bash tests/test_apt_https.sh           # 247 tests: transport guard + encoding hygiene
bash tests/test_updater.sh             # 45 tests: dispatcher, race safety, version floor
shellcheck -S warning *.sh lib/*.sh tests/*.sh   # lint
```

`test_apt_https.sh` is hermetic: it relocates the whole `/etc` tree into a
temp sandbox, stubs `sudo`/`ufw`/`apk` on `PATH`, and never makes a network
call. It also enforces repository encoding hygiene (valid UTF-8, no
double-encoding artifacts, LF endings), because these scripts are full of
box-drawing characters and a silent re-encode is otherwise invisible until a
snapshot diff catches it.

To regenerate snapshot fixtures after a deliberate UX change:
```bash
bash tests/gen_snapshots.sh   # re-captures print_welcome + print_metrics_summary
```

The snapshot test normalises host-specific lines (hostname, OS, kernel, arch) before comparison so fixtures are portable.  On macOS (bash 3.2 default) the `lib/updater.sh` version guard fires cleanly — this is verified by the CI matrix entry `bash:3.2-alpine3.18`.

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
- 🎬 [FrenzyPenguin Media](https://frenzypenguin-media.github.io/) — video deep-dives
- 🧬 [transhumanists](https://transhumanists.github.io/) — companion dashboard for human progress

[![Visitors](https://api.visitorbadge.io/api/visitors?path=github.com/neohiro/linux&label=Visitors&countColor=%23263759)](https://visitorbadge.io/status?path=github.com/neohiro/linux)
