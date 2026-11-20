#!/bin/sh
# Sets up the admin key, then runs the command (gitd serve by default).
#
# GITD_ADMIN_KEY set: that key is added (from stdin, never argv); a deployment chooses it.
# Otherwise: on first start a key is made and written to GITD_ADMIN_KEY_FILE
# (default /data/admin-key, mode 0600).
set -eu
if [ -n "${GITD_ADMIN_KEY:-}" ]; then
  printf '%s' "$GITD_ADMIN_KEY" | gitd admin add-key --data "$GITD_DATA"
  unset GITD_ADMIN_KEY
else
  key_file="${GITD_ADMIN_KEY_FILE:-$GITD_DATA/admin-key}"
  if [ ! -s "$key_file" ]; then
    umask 077
    gitd admin create-key --data "$GITD_DATA" >"$key_file.tmp"
    mv "$key_file.tmp" "$key_file"
    echo "gitd: wrote a new admin key to $key_file" >&2
  fi
fi
exec "$@"
