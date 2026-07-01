# Change Log

## [1.1.0] - 2026-05-11

### Added

- Added support for Claude Code and Codex skills for building, deployment, debugging, and organization management.
- Enhanced deployment and debugging skills.

### Updated

- Updated the `cross-colcon-build` script to enhance the build process and improve error handling.
- Changed the `rzv2h-chroot` command to `arm64-chroot` for better generality and consistency with other architectures.

### Fixed

- Fixed an issue where the `cross-colcon-build` script did not properly handle certain build configurations, which caused all packages to rebuild instead of only the changed ones.

## [1.0.1] - 2026-04-16

### Added

- Added Copilot AI agent skills for building, deployment, debugging, and organization management.

### Fixed

- Fixed a build issue for the `controller_interface` package caused by newer package versions in `sysroot-fix.yaml`.
- Fixed an issue where remote debugging did not work if no ROS environment variable (such as `ROS_DOMAIN_ID`) was set in `~/.bashrc`.

## [1.0.0] - 2026-03-31

### Added

- Initial release of the RZ/V2H Ubuntu XBuild system, providing a robust and efficient build environment for ROS 2-based projects.