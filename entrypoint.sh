#!/bin/bash

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

    grep -qxF "sysroot-fix-append.yaml" .gitignore 2>/dev/null || echo "sysroot-fix-append.yaml" >> .gitignore
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
