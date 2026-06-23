#!/bin/bash

: "${ARM64_SYSROOT:?ARM64_SYSROOT is not set}"

# -----------------------------------------------------------------------------
# Reconcile workspace ownership with the host.
#
# ros2_ws is a bind mount from the host. Its ownership on the host depends on
# who ran the container-setup script:
#   * root (e.g. `sudo ... --build`)  -> mount is owned by root:root, and the
#     non-root `ubuntu` user inside the container cannot write to it.
#   * a normal host user whose UID/GID differ from this account's -> files are
#     co-owned by neither side cleanly.
#
# We derive the intended owner from the mount itself (no host UID needs to be
# passed in) and reconcile so the workspace is editable from both the host and
# the container without anyone running chmod/chown by hand:
#   * mount owned by root  -> hand it to this user (root on the host keeps full
#     access regardless, so both sides can still edit/copy).
#   * mount owned by a different non-root UID/GID -> re-map this account to that
#     UID/GID and re-own our home files, then re-exec so the rest of startup
#     runs under the corrected identity.
# Requires passwordless sudo, which the image already grants to this user.
WS="${ROS2_WS:-$HOME/ros2_ws}"
if [ -z "${XBUILD_WS_OWNERSHIP_DONE:-}" ] && [ -d "$WS" ]; then
    export XBUILD_WS_OWNERSHIP_DONE=1
    own_uid="$(stat -c %u "$WS" 2>/dev/null || echo -1)"
    own_gid="$(stat -c %g "$WS" 2>/dev/null || echo -1)"
    cur_uid="$(id -u)"
    cur_gid="$(id -g)"

    if [ "$own_uid" = "0" ]; then
        echo "[INFO] Workspace '$WS' is owned by root; taking ownership as $(id -un)..."
        sudo chown "$cur_uid:$cur_gid" "$WS" 2>/dev/null \
            || echo "[WARN] Could not chown '$WS'; it may not be writable."
    elif [ "$own_uid" != "-1" ] && { [ "$own_uid" != "$cur_uid" ] || [ "$own_gid" != "$cur_gid" ]; }; then
        uname="$(id -un)"
        gname="$(id -gn)"
        echo "[INFO] Aligning user '$uname' to workspace owner ${own_uid}:${own_gid} so host and container co-own ros2_ws..."
        sudo groupmod -o -g "$own_gid" "$gname" 2>/dev/null || true
        sudo usermod  -o -u "$own_uid" -g "$own_gid" "$uname" 2>/dev/null || true
        # Re-own files left behind under our home with the old UID/GID. -xdev
        # keeps this on the home filesystem and never descends into the ros2_ws
        # bind mount (a separate device), which the host already owns correctly.
        sudo find "$HOME" -xdev \( -uid "$cur_uid" -o -gid "$cur_gid" \) \
            -exec chown -h "$own_uid:$own_gid" {} + 2>/dev/null || true
        # Re-exec as the corrected identity so the toolchain auto-update below
        # (which writes to our home) runs with matching ownership.
        exec sudo -E -u "$uname" -- "$0" "$@"
    fi
fi

echo "Updating DNS configuration in sysroot..."
mkdir -p "${ARM64_SYSROOT}/etc"
sudo cp /etc/resolv.conf "${ARM64_SYSROOT}/etc/resolv.conf" 2>/dev/null || echo "[WARN] Could not update DNS in sysroot."
echo "DNS updated in sysroot."

TOOLCHAIN_DIR="${TOOLCHAINS_WS:-/home/ubuntu/toolchains}"

# === Symlink helper scripts (always, before auto-update) ===
for pair in \
  "arm64-chroot.sh:arm64-chroot" \
  "sysroot-rosdep-install.sh:sysroot-rosdep-install" \
  "sysroot-fix.py:sysroot-fix" \
  "cross-colcon-build.sh:cross-colcon-build"; do
  src="$TOOLCHAIN_DIR/${pair%:*}"
  dst="/usr/local/bin/${pair#*:}"
  [ -f "$src" ] && sudo ln -sf "$src" "$dst"
done

# === Auto-update: fast-forward only, never block container ===
if [ -d "$TOOLCHAIN_DIR/.git" ]; then
  cd "$TOOLCHAIN_DIR"
  git config user.email "container@local" 2>/dev/null || true
  git config user.name "Container" 2>/dev/null || true

  if timeout 10 git fetch origin main >/dev/null 2>&1 && \
     git pull --ff-only origin main >/dev/null 2>&1; then
    echo "[INFO] Toolchain fast-forwarded."

    # Normalize product cmake files
    product="${PRODUCT:-V2H}"
    case "$product" in
      V2H) [ -f v2h_cross.cmake ] && cp v2h_cross.cmake cross.cmake;;
      V4H) [ -f v4h_cross.cmake ] && cp v4h_cross.cmake cross.cmake;;
    esac

    echo "[INFO] Toolchain synchronized."
    /usr/local/bin/sysroot-fix || echo "[WARN] sysroot-fix failed, skipping."
  else
    # Timeout / offline / conflict — skip, container continues normally
    echo "[WARN] Auto-update skipped — using local toolchain."
  fi
fi

# === Symlink agent skill files ===
ROS2_WS_DIR="${ROS2_WS:-/home/ubuntu/ros2_ws}"
if [ -d "$ROS2_WS_DIR" ] && [ "$ROS2_WS_DIR" != "$TOOLCHAIN_DIR" ]; then
  ln -sfn "$TOOLCHAIN_DIR/.vscode"       "$ROS2_WS_DIR/.vscode"       2>/dev/null
  ln -sfn "$TOOLCHAIN_DIR/.github"       "$ROS2_WS_DIR/.github"       2>/dev/null
  ln -sfn "$TOOLCHAIN_DIR/.claude"       "$ROS2_WS_DIR/.claude"       2>/dev/null
  ln -sfn "$TOOLCHAIN_DIR/AGENTS.md"     "$ROS2_WS_DIR/AGENTS.md"     2>/dev/null
  ln -sfn "$TOOLCHAIN_DIR/.clang-format" "$ROS2_WS_DIR/.clang-format" 2>/dev/null
  echo "[INFO] Agent skill files symlinked to $ROS2_WS_DIR."
fi

echo "--- Startup Complete ---"
exec "$@"
