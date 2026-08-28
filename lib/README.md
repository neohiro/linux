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

Top-level scripts (`linuxinstall.sh`, `restore_ssh.sh`,
`DeepClean.sh`, `OptimizeLinuxASR.sh`) source these automatically
when run from a clone. When run via `curl ... | bash`, the lib
directory is not on disk, so each script falls back to inline
definitions of the same helpers.

To regenerate the inline fallbacks, copy the body of each lib file
into the `else` branch in the top-level script.
