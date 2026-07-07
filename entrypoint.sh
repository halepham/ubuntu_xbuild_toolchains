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
                # Re-map ubuntu to the workspace owner (or create a new user if needed)
                sed -i -E "s/^(ubuntu:[^:]*:)[0-9]+:[0-9]+:/\1${ws_uid}:${ws_gid}:/" /etc/passwd 2>/dev/null || true
                sed -i -E "s/^(ubuntu:[^:]*:)[0-9]+:/\1${ws_gid}:/"                   /etc/group  2>/dev/null || true
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

# === Auto-update: check out the latest vX.Y.Z release tag; never block container ===
# Users track vetted releases, not the moving `main` branch. A bad commit on main
# no longer reaches containers on restart — only a maintainer-cut release does.
# Offline / no-tag / checkout failure is non-fatal: the container keeps the
# toolchain baked into the image (itself a valid release).
if [ -d "$TOOLCHAIN_DIR/.git" ]; then
  cd "$TOOLCHAIN_DIR"
  git config user.email "container@local" 2>/dev/null || true
  git config user.name "Container" 2>/dev/null || true

  updated=0
  if timeout 15 git fetch --tags --force origin >/dev/null 2>&1; then
    # Latest release by version sort; strict vX.Y.Z only (no pre-release tags).
    latest="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n1)"
    if [ -n "$latest" ] && git checkout -q -f "$latest" >/dev/null 2>&1; then
      echo "[INFO] Toolchain checked out release $latest."
      updated=1
    else
      echo "[WARN] No release tag found / checkout failed — using local toolchain."
    fi
  else
    # Timeout / offline — skip, container continues normally
    echo "[WARN] Auto-update skipped (offline) — using local toolchain."
  fi

  if [ "$updated" -eq 1 ]; then
    # Normalize product cmake files
    product="${PRODUCT:-V2H}"
    case "$product" in
      V2H) [ -f v2h_cross.cmake ] && cp v2h_cross.cmake cross.cmake;;
      V4H) [ -f v4h_cross.cmake ] && cp v4h_cross.cmake cross.cmake;;
    esac

    echo "[INFO] Toolchain synchronized."
    /usr/local/bin/sysroot-fix || echo "[WARN] sysroot-fix failed, skipping."
  fi
fi

# === Seed / merge per-user VS Code settings from the tracked template ===
# settings.json is gitignored so auto-update is never blocked by user edits and
# never clobbers them. The template is the source of truth for structure + new
# keys; we overlay the user-owned values back on top so target/project config
# survives every update.
VSCODE_DIR="$TOOLCHAIN_DIR/.vscode"
TEMPLATE="$VSCODE_DIR/settings.template.json"
SETTINGS="$VSCODE_DIR/settings.json"
if [ -f "$TEMPLATE" ]; then
  if [ ! -f "$SETTINGS" ]; then
    cp "$TEMPLATE" "$SETTINGS"
    echo "[INFO] Seeded .vscode/settings.json from template."
  elif command -v python3 >/dev/null 2>&1; then
    if python3 - "$TEMPLATE" "$SETTINGS" <<'PYMERGE'; then
import json, re, sys

USER_KEYS = ["TARGET_IP", "TARGET_GDB_PORT", "TARGET_USER", "TARGET_PASSWORD",
             "TARGET_ROS2_WS", "NODE_PACKAGE_NAME", "NODE_EXECUTABLE_NAME",
             "LAUNCH_PACKAGE_NAME", "LAUNCH_FILE_NAME"]

def load_jsonc(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    # tolerate VS Code JSONC: // line comments and trailing commas
    text = re.sub(r"(^|\s)//[^\n]*", r"\1", text)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return json.loads(text)

template, settings = sys.argv[1], sys.argv[2]
merged = load_jsonc(template)
user = load_jsonc(settings)
for k in USER_KEYS:
    if k in user:
        merged[k] = user[k]
with open(settings + ".tmp", "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=4, ensure_ascii=False)
    f.write("\n")
PYMERGE
      mv "$SETTINGS.tmp" "$SETTINGS"
      echo "[INFO] Merged template into .vscode/settings.json (user values preserved)."
    else
      rm -f "$SETTINGS.tmp"
      echo "[WARN] settings.json merge skipped (invalid JSON?) — kept user file as-is."
    fi
  else
    echo "[WARN] python3 not found — skipping settings.json template merge."
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
