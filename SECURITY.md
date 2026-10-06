# Security Policy

## Supported versions

Only the latest release available on the [Releases](../../releases) page
is supported with security updates.

## Reporting a vulnerability

Please report security issues **privately**:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability** (private vulnerability reporting).
3. Describe the issue, impact, and steps to reproduce.


For issues that cannot use GitHub Security Advisories, email `security@neohiro.io` (PGP key on request). All reports get an acknowledgement within 72 hours.

Do **not** open a public issue for anything you believe is exploitable.

You can expect an initial response within 7 days. Please allow a
reasonable time for a fix before any public disclosure.

## Hardening notes

This tool intentionally modifies system or network configuration across
multiple distribution families (Debian, RHEL/Fedora, SUSE, Arch). Always
review what will be applied, keep backups/restoration points, and test
on non-critical systems first.

### Package and app-store transport

Every package download, update, and upgrade is preceded by
`apt_https_guard` (see `lib/apt-https.sh`). The audit spans every app
store on the host, not just the distro package manager:

`apt`, `dnf`, `yum`, `zypper`, `pacman`, `apk`, `flatpak`, `snap`,
`docker`, `brew`, `pip`, `npm`, `cargo`, `gem`, `nix`, `fwupd`.

Detection is format-agnostic: any non-comment line carrying an `http://`
URL in a store's configuration, or a plaintext transport URL exported in
the environment, is reported. Signature verification catches *forged*
packages; only TLS prevents a *downgrade* to an older, genuinely-signed,
vulnerable build.

On apt the guard:

* installs `/etc/apt/apt.conf.d/99neohiro-force-https`, whose
  `Acquire::http::AllowRedirect "false"` prevents an `https://` mirror
  from silently downgrading a fetch to plaintext HTTP;
* rewrites `http://` repo URLs to `https://` in `sources.list`,
  `sources.list.d/*.list`, and DEB822 `*.sources`;
* backs every file up to `/var/backups/neohiro-apt-https/` first and logs
  it to `/var/log/linux-install-rollback.log`;
* applies each change by staging in the target's own directory and
  `rename(2)`, so an interrupted run cannot leave a truncated repo file;
* runs a verification `apt-get update` and rolls the rewrite back
  automatically if a mirror does not serve the same paths over HTTPS.

Other stores are reported rather than rewritten, because whether
`https://<same host><same path>` exists is not knowable offline and
silently breaking a working mirror is worse than the threat. Opt in with
`NEOHIRO_APT_HTTPS_REWRITE=1`.

Escape hatches and audit tooling:

```bash
sudo bash linuxinstall.sh --apt-https-audit   # read-only, exit 1 if plaintext remains
sudo bash linuxinstall.sh --apt-https-off     # restore backups, remove the drop-in
NEOHIRO_APT_HTTPS=0                           # disable the guard for one run
```

The optional `NEOHIRO_APT_BLOCK_PORT80=1` adds `ufw deny out 80/tcp`.
It is off by default because a blanket outbound block also affects
unrelated plaintext protocols, and the guard declines to add it while
any plaintext endpoint is still configured.

Under `curl | sudo bash` the guard is loaded from `lib/apt-https.sh`
(fetched from the same base the script already trusts) rather than
duplicated inline, so there is one implementation to audit. If it cannot
be loaded the script says so and runs with the guard inactive — it never
reports success for a precaution that is not running.

---

Maintained by **[neohiro](https://github.com/neohiro)**.
