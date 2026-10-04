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
- `apt-https.sh` — repository/app-store transport guard. `apt_https_guard`
  is called by every package entry point so nothing is ever fetched over
  plaintext HTTP. It audits **every** app store, not just apt: `apt`, `dnf`,
  `yum`, `zypper`, `pacman`, `apk`, `flatpak`, `snap`, `docker`, `brew`,
  `pip`, `npm`, `cargo`, `gem`, `nix`, `fwupd` (see `_apt_https_source_ids`).
  Detection is format-agnostic — any non-comment line carrying an `http://`
  URL — so a new key in a new distro release cannot silently slip past.
  On apt it installs `/etc/apt/apt.conf.d/99neohiro-force-https` (refusing
  HTTPS→HTTP downgrade redirects), rewrites `http://` to `https://` across
  `sources.list`, `sources.list.d/*.list` and DEB822 `*.sources`, verifies
  with a real `apt-get update`, and rolls the rewrite back if a mirror does
  not speak TLS. Every write is a same-directory staging file plus
  `rename(2)`, so a crash cannot leave a truncated repo file. Other stores
  are reported, and rewritten only on `NEOHIRO_APT_HTTPS_REWRITE=1`,
  because whether `https://<same host><same path>` exists is not knowable
  offline. API: `apt_https_guard`, `apt_https_enforce`, `apt_https_report`,
  `apt_https_revert`, `apt_https_status_text`, `apt_https_plaintext_for`;
  also runnable standalone. `NEOHIRO_APT_ETC_DIR` / `NEOHIRO_APT_BACKUP_DIR`
  relocate the whole tree, so tests never touch the real `/etc`.
- `sync-inline.sh`, `color-gate.sh` — shared inline-fallback sources
  consumed by the `curl | bash` path of the top-level scripts.

Top-level scripts (`linuxinstall.sh`, `restore_ssh.sh`,
`DeepClean.sh`, `OptimizeLinuxASR.sh`) source these automatically
when run from a clone. When run via `curl ... | bash`, the lib
directory is not on disk, so each script falls back to inline
definitions of the same helpers.

`apt-https.sh` is the exception: it is never duplicated inline.
`linuxinstall.sh` resolves the canonical file — from disk, or by
fetching it from the same `REPO_RAW_BASE` it already trusts for
`DeepClean.sh` — and sources that, so there is exactly one
implementation. If it cannot be loaded the public entry points become
loud no-ops rather than undefined functions. `tests/test_apt_https.sh`
asserts both properties: the resolver is present, and no library
helper is redefined inline.

To regenerate the inline fallbacks for the other helpers, copy the body
of each lib file into the `else` branch in the top-level script.
