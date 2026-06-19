#!/bin/bash

: "${ARM64_SYSROOT:?ARM64_SYSROOT is not set}"

echo "Updating DNS configuration in sysroot..."
mkdir -p "${ARM64_SYSROOT}/etc"
sudo cp /etc/resolv.conf "${ARM64_SYSROOT}/etc/resolv.conf" 2>/dev/null || echo "[WARN] Could not update DNS in sysroot."
echo "DNS updated in sysroot."

TOOLCHAIN_DIR="${TOOLCHAINS_WS:-/home/ubuntu/toolchains}"

if [ -d "$TOOLCHAIN_DIR/.git" ]; then
  cd "$TOOLCHAIN_DIR"
  git remote add origin https://github.com/renesas-rdk/ubuntu_xbuild_toolchains.git 2>/dev/null || true
  if git remote get-url origin >/dev/null 2>&1 && timeout 10 git fetch origin main >/dev/null 2>&1 && git rev-parse origin/main >/dev/null 2>&1; then
    if ! git diff --quiet HEAD 2>/dev/null; then
      echo "[WARN] Local toolchain has uncommitted changes — skipping auto-update."
      echo "[WARN] Container will continue normally — user must resolve manually."
    else
      echo "[INFO] Toolchain updates found. Applying..."
      rm -f /tmp/settings.json.bak
      [ -f .vscode/settings.json ] && cp .vscode/settings.json /tmp/settings.json.bak
      git archive origin/main | tar xf - --overwrite -C "$TOOLCHAIN_DIR" --exclude=sysroot-fix-append.yaml
      if [ -f /tmp/settings.json.bak ]; then
        TOOLCHAIN_DIR="$TOOLCHAIN_DIR" python3 -c '
import json, os
path = os.path.join(os.environ["TOOLCHAIN_DIR"], ".vscode", "settings.json")
with open("/tmp/settings.json.bak") as f: old = json.load(f)
if os.path.isfile(path):
    with open(path) as f: new = json.load(f)
else:
    new = {}
PRESERVED = ["TARGET_IP","TARGET_GDB_PORT","TARGET_USER","TARGET_PASSWORD",
             "TARGET_ROS2_WS","NODE_PACKAGE_NAME","NODE_EXECUTABLE_NAME",
             "LAUNCH_PACKAGE_NAME","LAUNCH_FILE_NAME"]
for k in PRESERVED:
    if k in old: new[k] = old[k]
with open(path, "w") as f: json.dump(new, f, indent=4)
'
        rm /tmp/settings.json.bak
      fi
      grep -qxF "sysroot-fix-append.yaml" .gitignore 2>/dev/null || echo "sysroot-fix-append.yaml" >> .gitignore
      git add -A
      git commit -m "snapshot $(date +%Y%m%d-%H%M%S)" --allow-empty
      product="${PRODUCT:-V2H}"
      case "$product" in
        V2H) [ -f v2h_cross.cmake ] && mv -f v2h_cross.cmake cross.cmake; rm -f v4h_cross.cmake ;;
        V4H) [ -f v4h_cross.cmake ] && mv -f v4h_cross.cmake cross.cmake; rm -f v2h_cross.cmake ;;
      esac
      echo "[INFO] Toolchain synchronized."
      /usr/local/bin/sysroot-fix || echo "[WARN] sysroot-fix failed, skipping."
    fi
  fi
fi

# Symlink helper scripts to /usr/local/bin (auto-update via toolchain changes)
for pair in \
  "arm64-chroot.sh:arm64-chroot" \
  "sysroot-rosdep-install.sh:sysroot-rosdep-install" \
  "sysroot-fix.py:sysroot-fix" \
  "cross-colcon-build.sh:cross-colcon-build"; do
  src="$TOOLCHAIN_DIR/${pair%:*}"
  dst="/usr/local/bin/${pair#*:}"
  [ -f "$src" ] && sudo ln -sf "$src" "$dst"
done

# Symlink agent skill files from toolchain to ros2_ws (auto-update, no duplication)
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
