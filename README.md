# ubuntu-xbuild-toolchains

Toolchain files for **cross-compiling workspaces for ARM64
(aarch64)**. Designed to run inside the
cross-build Docker container, where this repo is checked out at
`/home/ubuntu/toolchains` and kept in sync with upstream on container start.

Targets boards:

- **RZ/V2H RDK** - Cortex-A55 (`v2h_cross.cmake`)
- **RCar/V4H Sparrow Hawk** - Cortex-A76 (`v4h_cross.cmake`)

## Contents

| File | Purpose |
| --- | --- |
| `v2h_cross.cmake`, `v4h_cross.cmake` | CMake toolchain files (per-board compiler flags, sysroot, `rpath-link` fixups). One is symlinked to `cross.cmake`. |
| `cross-colcon-build.sh` | `colcon build` wrapper that injects the toolchain + Python paths into `--cmake-args`. Installed as `cross-colcon-build`. |
| `arm64-chroot.sh` | Enters the ARM64 sysroot via QEMU + `chroot` (used to run `rosdep`/`apt` against the target). |
| `sysroot-rosdep-install.sh` | Copies the ROS 2 workspace into the sysroot and installs build-time dependencies with `rosdep`. |
| `sysroot-fix.py` + `sysroot-fix.yaml` | Relocate hardcoded absolute paths in the sysroot's exported CMake target files so cross builds resolve correctly. |
| `sysroot-fix-append.yaml` | User-local sysroot fixups; gitignored, never overwritten by auto-update. |
| `entrypoint.sh` | Container entrypoint: refreshes sysroot DNS and auto-updates the toolchain from upstream. |
| `env.conf` | Bash tab-completion for `colcon` and `cross-colcon-build`. |

## License

See [LICENSE](LICENSE).
