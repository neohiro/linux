# lib/

Shared bash helpers sourced by the top-level scripts. See the header of
each file for the API contract.

- `color.sh` — `USE_COLOR` gate, `_c <code> <text>`, and the
  `bold / warn / err / ok / info / msg` print helpers. Honors
  `[-t 1]`, `NO_COLOR`, and `TERM=dumb`. Same logic in every script.
- `temp.sh` — `TMP_DIR` mktemp, `_TMP_FILES` tracking, `_tmpfile` helper.
  EXIT trap cleans everything. ERR trap in STRICT_RUN / CI mode logs
  the failing command to `NEOHIRO_DEBUG_LOG` (default
  `/var/log/neohiro-debug.log`).
- `updater.sh` — the comprehensive cross-distro update engine
  (`_run_all_updates` plus one `_update_*` per tool). Sourceable and
  runnable standalone (`sudo bash lib/updater.sh`).
- `apt-https.sh` — repository transport guard. `apt_https_guard` is
  called by every package entry point so no repo is ever fetched over
  plaintext HTTP. Installs `/etc/apt/apt.conf.d/99neohiro-force-https`
  (refuses HTTPS→HTTP downgrade redirects), rewrites `http://` repo URLs
  to `https://` in `sources.list`, `sources.list.d/*.list` and DEB822
  `*.sources`, backs every original up to
  `/var/backups/neohiro-apt-https/`, and auto-reverts if a mirror does
  not speak TLS. Audits (never blindly rewrites) dnf/yum/zypper/pacman
  and flatpak remotes. API: `apt_https_guard`, `apt_https_enforce`,
  `apt_https_report`, `apt_https_revert`; also runnable standalone.
  Tests relocate the whole tree via `NEOHIRO_APT_ETC_DIR` /
  `NEOHIRO_APT_BACKUP_DIR`, so nothing touches the real `/etc`.
- `sync-inline.sh`, `color-gate.sh` — shared inline-fallback sources
  consumed by the `curl | bash` path of the top-level scripts.

Top-level scripts (`linuxinstall.sh`, `restore_ssh.sh`,
`DeepClean.sh`, `OptimizeLinuxASR.sh`) source these automatically
when run from a clone. When run via `curl ... | bash`, the lib
directory is not on disk, so each script falls back to inline
definitions of the same helpers.

To regenerate the inline fallbacks, copy the body of each lib file
into the `else` branch in the top-level script. Keep the public
function names identical — `tests/test_apt_https.sh` asserts that
`linuxinstall.sh`'s inline fallback and `lib/apt-https.sh` expose the
same API, and that both guard before the first package command in
every `pkg_*` helper.
