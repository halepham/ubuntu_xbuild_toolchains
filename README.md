# ubuntu-xbuild-toolchains

## Overview

Ubuntu XBuild is a Docker-based cross-build environment for ROS 2 applications
targeting ARM64 (aarch64) boards. It is designed to simplify the workflow for
building, deploying, and debugging software from an Ubuntu host system.

This repository holds the toolchain files that drive that environment. They run
inside the cross-build Docker container, where this repo is checked out at
`/home/ubuntu/toolchains` and updated to the latest tagged release on container start.

The project is intended for developers who need a practical and reproducible
environment for ARM64 application development, especially for robotics and edge
AI use cases.

### Supported boards

| Board | Core | Toolchain file | `PRODUCT` |
| --- | --- | --- | --- |
| **RZ/V2H RDK** | Cortex-A55 | `v2h_cross.cmake` | `V2H` (default) |
| **RCar/V4H Sparrow Hawk** | Cortex-A76 | `v4h_cross.cmake` | `V4H` |

The container selects the active board from the `PRODUCT` environment variable
(defaults to `V2H`). On start, the entrypoint copies the matching
`*_cross.cmake` to `cross.cmake`, which the build wrapper then uses.

## Quick Start

To get started with Ubuntu XBuild:

- Run the setup script on an Ubuntu 24.04 x86_64 host machine to create the
  Docker-based cross-compilation environment.

  ```bash
  wget https://github.com/renesas-rdk/ros2_demo_workspace/raw/refs/heads/main/common_utils/setup_rdk_docker.sh
  chmod +x setup_rdk_docker.sh
  ./setup_rdk_docker.sh
  ```

- Follow the instructions provided by the script to build the Docker image and
  set up the workspace.

After setup is complete, you can use the environment to cross-build and develop
applications for the target board.

## Contents

| File | Purpose |
| --- | --- |
| `v2h_cross.cmake`, `v4h_cross.cmake` | CMake toolchain files (per-board compiler flags, sysroot, `rpath-link` fixups). One is copied to `cross.cmake` based on `PRODUCT`. |
| `cross-colcon-build.sh` | `colcon build` wrapper that injects the toolchain + Python paths into `--cmake-args`. Installed as `cross-colcon-build`. |
| `arm64-chroot.sh` | Enters the ARM64 sysroot via QEMU + `chroot` (used to run `rosdep`/`apt` against the target). |
| `sysroot-rosdep-install.sh` | Copies the ROS 2 workspace into the sysroot and installs build-time dependencies with `rosdep`. |
| `sysroot-fix.py` + `sysroot-fix.yaml` | Relocate hardcoded absolute paths in the sysroot's exported CMake target files so cross builds resolve correctly. |
| `sysroot-fix-append.yaml` | User-local sysroot fixups; gitignored, never overwritten by auto-update. |
| `entrypoint.sh` | Container entrypoint: refreshes sysroot DNS, selects the board toolchain from `PRODUCT`, and auto-updates the toolchain to the latest `vX.Y.Z` release tag on start. |
| `env.conf` | Bash tab-completion for `colcon` and `cross-colcon-build`. |

## Documentation

For full setup and development instructions, see the
[Application Development Guide](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-4/development_guide/development_guide.html).

> Note: the hosted guides above are written for the RZ/V2H RDK. The
> cross-build workflow is the same for the RCar/V4H Sparrow Hawk; set
> `PRODUCT=V4H` and use the `v4h_cross.cmake` toolchain.

## Troubleshooting

For common cross-compilation issues, see the
[Cross-compilation FAQ](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-4/development_guide/cross_build_faq.html).

## Limitations

For known limitations, see
[Non-Relocatable Sysroot CMake Paths](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-4/development_guide/cross_build_know_issue.html).

## Change Log

See [CHANGELOG](./CHANGELOG.md).

## License

See [LICENSE](LICENSE).
