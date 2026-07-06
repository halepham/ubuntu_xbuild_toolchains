#!/bin/bash

# This script lists the arguments that the selected launch file accepts (queried from the
# target over SSH), then lets the user pick from them and type the arguments
# manually on a single line. The result is returned in the global variable
# APP_ARGS (blank means no arguments).
#
# Usage (source this file, then call):
#   prompt_app_args MODE TARGET_IP TARGET_USER SSHPASS PACKAGE FILE_OR_EXEC

prompt_app_args() {
  local mode="$1" ip="$2" user="$3" pass="$4" pkg="$5" target="$6"

  local CY='\033[0;36m' GR='\033[0;32m' DIM='\033[2m' NC='\033[0m'
  local ssh_base="sshpass -p ${pass} ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new ${user}@${ip}"

  echo -e "\n${GR}[Host] Fetching available arguments for ${pkg} ${target}...${NC}"

  # Launch files declare their arguments, so we can list them. Plain executables
  # do not, so we fall back to generic ROS argument hints below.
  local hints=""
  if [ "${mode}" = "launch" ]; then
    hints=$(${ssh_base} \
      "source /opt/ros/jazzy/setup.bash 2>/dev/null; source /tmp/install/setup.bash 2>/dev/null; ros2 launch ${pkg} ${target} -s 2>/dev/null" \
      2>/dev/null)
  fi

  if [ -n "${hints}" ]; then
    echo -e "${CY}Available launch arguments (pass as name:=value):${NC}"
    echo "${hints}"
  else
    echo -e "${DIM}No declared launch arguments found. You can still pass ROS args, e.g.:${NC}"
    echo -e "${DIM}  --ros-args -p param_name:=value     (set a parameter)${NC}"
    echo -e "${DIM}  --ros-args -r from:=to              (remap a topic)${NC}"
  fi

  echo -e "${DIM}Pick from the above and type the arguments on one line, separated by spaces.${NC}"
  echo -e "${DIM}Press ENTER on an empty line for no arguments.${NC}"

  read -r -e -p "$(echo -e "  args: ")" APP_ARGS
  if [ -n "${APP_ARGS}" ]; then
    echo -e "${GR}[Host] Using arguments:${NC} ${APP_ARGS}"
  else
    echo -e "${DIM}[Host] No arguments provided.${NC}"
  fi
}
