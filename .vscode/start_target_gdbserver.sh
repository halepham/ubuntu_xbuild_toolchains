#!/bin/bash

# This script synchronizes the compiled program to the remote target and executes it.

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NONE='\033[0m'

function print_usage() {
  echo -e "\n${GREEN}Usage${NONE}:"
  echo -e "  ${BOLD}./start_target_gdbserver.sh${NONE} run TARGET_IP TARGET_USER SSHPASS DEST_PATH PACKAGE EXECUTABLE_NAME SYSROOT PORT_NUMBER [ARGS...]                      # debug single node"
  echo -e "  ${BOLD}./start_target_gdbserver.sh${NONE} launch TARGET_IP TARGET_USER SSHPASS DEST_PATH PACKAGE LAUNCH_FILE SYSROOT DEBUG_EXECUTABLE PORT_NUMBER [ARGS...]      # for ros2 launch"
  echo -e "\n${GREEN}TARGET_IP${NONE}:"
  echo -e "  ${NONE}IP address of remote target board."
  echo -e "\n${GREEN}TARGET_USER${NONE}:"
  echo -e "  ${NONE}User name."
  echo -e "\n${GREEN}SSHPASS${NONE}:"
  echo -e "  ${NONE}Password for ${TARGET_USER} user."
  echo -e "\n${GREEN}DEST_PATH${NONE}:"
  echo -e "  ${NONE}Workspace path on target where the install folder is deployed."
  echo -e "\n${GREEN}PACKAGE${NONE}:"
  echo -e "  ${NONE}Run a ROS2 node. Requires PACKAGE and EXECUTABLE. Use with ros2 run/launch."
  echo -e "\n${GREEN}EXECUTABLE_NAME${NONE}:"
  echo -e "  ${NONE}Launch a ROS2 launch file. Requires LAUNCH_FILE. Use with ros2 run."
  echo -e "\n${GREEN}LAUNCH_FILE${NONE}:"
  echo -e "  ${NONE}Launch a ROS2 launch file. Requires LAUNCH_FILE. Use with ros2 launch."
  echo -e "\n${GREEN}PORT_NUMBER${NONE}:"
  echo -e "  ${NONE}Port number for gdbserver."
  echo -e "\n${GREEN}ARGS${NONE}:"
  echo -e "  ${NONE}Additional arguments to pass to the ROS2 application."
}

# Function to get ROS-related environment variables from target's bashrc
function get_target_ros_env() {
  local target_ip=$1
  local target_user=$2
  local sshpass=$3

  sshpass -p "${sshpass}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new ${target_user}@${target_ip} \
    "grep -E '^export (ROS_|RMW_|FASTRTPS_|CYCLONEDDS_|DDS_|RCUTILS_|SPDLOG_)' ~/.bashrc 2>/dev/null" 2>/dev/null | \
    sort
}

# Check minimum arguments (at least mode + 2 more to determine what mode)
if [ $# -lt 1 ]; then
  echo -e "${RED}[Host] No mode specified.${NONE}"
  print_usage
  exit 1
fi

# Determine mode and check appropriate number of arguments
if [ "$1" = "run" ]; then
  if [ $# -lt 8 ]; then
    echo -e "${RED}[Host] Not enough arguments for 'run' mode. Expected at least 8, got $#.${NONE}"
    print_usage
    exit 1
  fi
  PORT_NUMBER=$9
  MODE="run"
  ROS2_MODE_CMD="ros2 run --prefix 'gdbserver :${PORT_NUMBER}'"
elif [ "$1" = "launch" ]; then
  if [ $# -lt 9 ]; then
    echo -e "${RED}[Host] Not enough arguments for 'launch' mode. Expected at least 9, got $#.${NONE}"
    print_usage
    exit 1
  fi
  DEBUG_EXECUTABLE=$9
  PORT_NUMBER=${10}
  MODE="launch"
  ROS2_MODE_CMD="ros2 launch --launch-prefix 'gdbserver localhost:${PORT_NUMBER}' --launch-prefix-filter '${DEBUG_EXECUTABLE}'"
else
  echo -e "${RED}[Host] Invalid mode: '$1'. Use 'run' or 'launch'.${NONE}"
  print_usage
  exit 1
fi

TARGET_IP=$2
TARGET_USER=$3
SSHPASS=$4
DEST_PATH=$5
PACKAGE=$6
EXECUTABLE=$7
SDK_SYSROOT=$8

# Shift arguments based on mode
if [ "$MODE" = "run" ]; then
  shift 9
else  # launch mode
  shift 10
fi

ARGS=$@

# Check ssh connection
if ! sshpass -p "${SSHPASS}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new ${TARGET_USER}@${TARGET_IP} "exit"; then
  echo -e "${RED}[Host] SSH connection to ${TARGET_USER}@${TARGET_IP} failed. Please check the IP address and password.${NONE}"
  exit 1
fi

# Check if install folder exists relative to the script location and copy it to remote ${DEST_PATH} if it does
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}/../install"
DEST_INSTALL="${DEST_PATH}/install"

if sshpass -p "${SSHPASS}" ssh ${TARGET_USER}@${TARGET_IP} "[ ! -d '${DEST_INSTALL}' ]"; then
  echo -e "${GREEN}[Host] '${DEST_INSTALL}' not found on target. Deploying...${NONE}"
  if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${RED}[Host] '$INSTALL_DIR' folder not found on host. Cannot deploy.${NONE}"
    exit 1
  fi
  if ! bash "${SCRIPT_DIR}/deploy.sh" "${TARGET_IP}" "${TARGET_USER}" "${SSHPASS}" "${INSTALL_DIR}" "${DEST_PATH}"; then
    echo -e "${RED}[Host] Deployment failed.${NONE}"
    exit 1
  fi
fi

# "-h"/"--help" switches to interactive collection: suggest the available
# arguments and keep asking until the user enters a blank line. Any other value
# (including empty) is passed through to the application as-is.
if [ "$ARGS" = "-h" ] || [ "$ARGS" = "--help" ]; then
  source "${SCRIPT_DIR}/prompt_app_args.sh"
  prompt_app_args "$MODE" "$TARGET_IP" "$TARGET_USER" "$SSHPASS" "$PACKAGE" "$EXECUTABLE"
  ARGS="$APP_ARGS"
fi
ROS2_APP_CMD="$ROS2_MODE_CMD $PACKAGE $EXECUTABLE $ARGS"

# Synchronize libraries
echo -e "${GREEN}[Host] Synchronizing libraries...${NONE}"

### Synchronize Install libraries
echo -e "${GREEN}[Host] Synchronizing install libraries...${NONE}"
sudo rsync -az --delete-during "$INSTALL_DIR/" "${SDK_SYSROOT}${DEST_INSTALL}/"

# Get ROS environment from target
echo -e "${GREEN}[Host] Fetching ROS environment from target...${NONE}"
TARGET_ENV_EXPORTS=$(get_target_ros_env ${TARGET_IP} ${TARGET_USER} ${SSHPASS})
# Convert multiline exports to single line
TARGET_ENV_SINGLE_LINE=$(echo "${TARGET_ENV_EXPORTS}" | tr '\n' ';' | sed 's/;$//')

if [ -n "${TARGET_ENV_EXPORTS}" ]; then
  echo -e "${GREEN}[Host] Detected environment on target:${NONE}"
  echo "${TARGET_ENV_EXPORTS}"
else
  echo -e "${BLUE}[Host] No custom ROS environment found on target${NONE}"
fi

# Build remote command first to avoid syntax issues when TARGET_ENV_SINGLE_LINE is empty
REMOTE_CMD="stty -echo;"

if [ -n "${TARGET_ENV_SINGLE_LINE}" ]; then
  REMOTE_CMD="${REMOTE_CMD} ${TARGET_ENV_SINGLE_LINE};"
fi

REMOTE_CMD="${REMOTE_CMD}
echo -e \"\n${BLUE}[Target] Welcome to ${TARGET_IP}!${NONE}\";
echo -e \"\n${BLUE}[Target] Running: ${BOLD}${ROS2_APP_CMD}${NONE}${BLUE}...${NONE}\n\";
if [ ! -f /opt/ros/jazzy/setup.bash ]; then
  echo -e \"${RED}[Target] /opt/ros/jazzy/setup.bash not found. Exiting.${NONE}\";
  exit 1;
fi;
source /opt/ros/jazzy/setup.bash;
if [ ! -f ${DEST_INSTALL}/setup.bash ]; then
  echo -e \"${RED}[Target] ${DEST_INSTALL}/setup.bash not found. Exiting.${NONE}\";
  exit 1;
fi;
source ${DEST_INSTALL}/setup.bash;
${ROS2_APP_CMD};"

# Connect to target board (Use option -tt to force tty allocation)
echo -e "${GREEN}\n[Host] Trying to login ${TARGET_USER}@${TARGET_IP}...${NONE}"
sshpass -p "${SSHPASS}" ssh -tt ${TARGET_USER}@${TARGET_IP} "${REMOTE_CMD}"
