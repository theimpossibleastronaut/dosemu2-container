#!/bin/bash
# Run-time entrypoint for the :build-env image.
#
# Stats the working dir (typically /workspace, bind-mounted from the
# host) to find out which UID/GID owns the host source tree, then
# remaps the in-container `builder` user to match before dropping to
# it. Files written from inside the container land on the host with
# correct ownership without any --user flag or post-build chown.
#
# Override the auto-detection by exporting HOSTUID / HOSTGID before
# `docker run` (useful in CI matrices or when the workspace owner
# doesn't match the invoking user).
#
# Bypassed entirely when no bind mount is present or the workdir is
# already owned by builder — the image still works for ad-hoc shells.

set -e

current_uid=$(id -u builder)
current_gid=$(id -g builder)

detected_uid=${HOSTUID:-$(stat -c %u "$PWD" 2>/dev/null || echo "$current_uid")}
detected_gid=${HOSTGID:-$(stat -c %g "$PWD" 2>/dev/null || echo "$current_gid")}

if [ -n "$detected_uid" ] && [ "$detected_uid" != "0" ] && [ "$detected_uid" != "$current_uid" ]; then
  groupmod -g "$detected_gid" builder >/dev/null 2>&1 || true
  usermod -u "$detected_uid" -g "$detected_gid" builder >/dev/null 2>&1 || true
  # The home dir's ownership wasn't recursively chowned by usermod;
  # fix it so caches (paru, cargo) are writable by the new IDs.
  chown -R "$detected_uid:$detected_gid" /home/builder
fi

# No args → interactive shell.
if [ $# -eq 0 ]; then
  set -- bash
fi

exec runuser -u builder -- "$@"
