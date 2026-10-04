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

### Package transport

Every package download, update, and upgrade is preceded by
`apt_https_guard` (see `lib/apt-https.sh`), which forces repository
traffic over TLS:

* On apt it installs `/etc/apt/apt.conf.d/99neohiro-force-https` and
  rewrites `http://` repo URLs to `https://` in `sources.list`,
  `sources.list.d/*.list`, and DEB822 `*.sources`.
* The policy file sets `Acquire::http::AllowRedirect "false"` so an
  `https://` mirror cannot silently downgrade a fetch to plaintext HTTP.
* Every file it edits is backed up to `/var/backups/neohiro-apt-https/`
  first and logged to `/var/log/linux-install-rollback.log`.
* If the rewritten sources fail a verification `apt-get update`, the
  rewrite is rolled back automatically.

Escape hatches and audit tooling:

```bash
sudo bash linuxinstall.sh --apt-https-audit   # read-only, exit 1 if plaintext remains
sudo bash linuxinstall.sh --apt-https-off     # restore backups, remove the drop-in
NEOHIRO_APT_HTTPS=0                           # disable the guard for one run
```

The optional `NEOHIRO_APT_BLOCK_PORT80=1` adds `ufw deny out 80/tcp`.
It is off by default because a blanket outbound block also affects
unrelated plaintext protocols.

---

Maintained by **[neohiro](https://github.com/neohiro)**.
