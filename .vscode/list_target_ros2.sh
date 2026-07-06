#!/bin/bash

# Lists ROS2 packages / executables / launch files that are available on the
# remote target board, so the "Tasks Shell Input" VS Code extension
# (augustocdias.tasks-shell-input) can populate task input dropdowns dynamically.
#
# Usage:
#   ./list_target_ros2.sh packages        TARGET_IP TARGET_USER SSHPASS DEST_PATH
#   ./list_target_ros2.sh executables     TARGET_IP TARGET_USER SSHPASS DEST_PATH PACKAGE
#   ./list_target_ros2.sh launch_packages TARGET_IP TARGET_USER SSHPASS DEST_PATH
#   ./list_target_ros2.sh launch_files    TARGET_IP TARGET_USER SSHPASS DEST_PATH PACKAGE

MODE="$1"
TARGET_IP="$2"
TARGET_USER="$3"
SSHPASS="$4"
DEST_PATH="$5"
PKG="${6:-}"

# Install folder on the target, as produced by deploy.sh.
DEST_INSTALL="${DEST_PATH}/install"

SSH=(sshpass -p "${SSHPASS}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${TARGET_USER}@${TARGET_IP}")

case "${MODE}" in
  packages)
    # Packages that ship at least one runnable executable (lib/<pkg>/...).
    REMOTE="for d in ${DEST_INSTALL}/*/; do p=\$(basename \"\$d\"); [ -n \"\$(ls -A \"${DEST_INSTALL}/\$p/lib/\$p\" 2>/dev/null)\" ] && echo \"\$p\"; done"
    ;;
  executables)
    # Executables registered for a package (second column of `ros2 pkg executables`).
    REMOTE="source /opt/ros/jazzy/setup.bash 2>/dev/null; source ${DEST_INSTALL}/setup.bash 2>/dev/null; ros2 pkg executables ${PKG} 2>/dev/null | awk '{print \$2}'"
    ;;
  launch_packages)
    # Packages that ship at least one launch file under share/<pkg>/launch.
    REMOTE="for d in ${DEST_INSTALL}/*/; do p=\$(basename \"\$d\"); ls ${DEST_INSTALL}/\$p/share/\$p/launch/*.launch.* >/dev/null 2>&1 && echo \"\$p\"; done"
    ;;
  launch_files)
    REMOTE="ls -1 ${DEST_INSTALL}/${PKG}/share/${PKG}/launch 2>/dev/null | grep -E '\\.launch\\.(py|xml|yaml)\$'"
    ;;
  *)
    echo "Unknown mode: ${MODE}" >&2
    exit 1
    ;;
esac

"${SSH[@]}" "${REMOTE}" 2>/dev/null | sort -u
