#!/bin/bash

# Align the container's `ubuntu` to the host owner of the bind-mounted ros2_ws
# so it's editable from both sides without chmod (root-owned -> hand to ubuntu;
# other UID -> re-map ubuntu to it). Done in one sudo that ends by dropping back
# to ubuntu via setpriv and re-running this script, so `docker exec` still lands
# as ubuntu (a usermod + second sudo would crash on the now-stale caller UID).
ROS2_WS_DIR="${ROS2_WS:-/home/ubuntu/ros2_ws}"
if [ -d "$ROS2_WS_DIR" ]; then
    ws_uid="$(stat -c %u "$ROS2_WS_DIR" 2>/dev/null || echo -1)"
    ws_gid="$(stat -c %g "$ROS2_WS_DIR" 2>/dev/null || echo -1)"
    if [ "$ws_uid" != "-1" ] && { [ "$ws_uid" != "$(id -u)" ] || [ "$ws_gid" != "$(id -g)" ]; }; then
        echo "[INFO] Reconciling 'ubuntu' with workspace owner ${ws_uid}:${ws_gid}..."
        exec sudo bash -c '
            set -u
            ws_uid=$1; ws_gid=$2; cur_uid=$3; cur_gid=$4; ws=$5; self=$6; shift 6
            if [ "$ws_uid" = 0 ]; then
                chown "$cur_uid:$cur_gid" "$ws" 2>/dev/null || true
                drop_uid=$cur_uid; drop_gid=$cur_gid
            else
                groupmod -o -g "$ws_gid" ubuntu 2>/dev/null || true
                usermod  -o -u "$ws_uid" -g "$ws_gid" ubuntu 2>/dev/null || true
                # -xdev keeps re-owning on the home filesystem and never descends
                # into the ros2_ws bind mount (a separate device).
                find /home/ubuntu -xdev \( -uid "$cur_uid" -o -gid "$cur_gid" \) \
                    -exec chown -h "$ws_uid:$ws_gid" {} + 2>/dev/null || true
                drop_uid=$ws_uid; drop_gid=$ws_gid
            fi
            exec setpriv --reuid "$drop_uid" --regid "$drop_gid" --init-groups -- "$self" "$@"
        ' bash "$ws_uid" "$ws_gid" "$(id -u)" "$(id -g)" "$ROS2_WS_DIR" "$0" "$@"
    fi
fi

# Require ARM64_SYSROOT to be set (prevents accidental writes)
: "${ARM64_SYSROOT:?ARM64_SYSROOT is not set}"

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
if [ -d "$ROS2_WS_DIR" ] && [ "$ROS2_WS_DIR" != "$TOOLCHAIN_DIR" ]; then
  ln -sfn "$TOOLCHAIN_DIR/.vscode"       "$ROS2_WS_DIR/.vscode"
  ln -sfn "$TOOLCHAIN_DIR/.github"       "$ROS2_WS_DIR/.github"
  ln -sfn "$TOOLCHAIN_DIR/.claude"       "$ROS2_WS_DIR/.claude"
  ln -sfn "$TOOLCHAIN_DIR/AGENTS.md"     "$ROS2_WS_DIR/AGENTS.md"
  ln -sfn "$TOOLCHAIN_DIR/.clang-format" "$ROS2_WS_DIR/.clang-format"
  echo "[INFO] Agent skill files symlinked to $ROS2_WS_DIR."
fi

echo "--- Startup Complete ---"
exec "$@"
