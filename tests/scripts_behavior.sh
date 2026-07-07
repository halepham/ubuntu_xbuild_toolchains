#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Behavior tests for the toolchain helper scripts. Drives only the cheap,
# deterministic decision branches (chroot lock, workspace validation,
# sysroot-fix config handling); each case bails out before any real chroot,
# mount, or cross build, which are covered by tests/integration_image_test.sh.
#
# Runs as root in a container (see .github/workflows/test.yml); `sudo` is
# shimmed to a plain exec so privileged calls need no password.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$HERE/lib/assert.sh"

# sudo shim: strip flags, exec the command directly (already root in CI).
SHIM_DIR="$(mktemp -d)"
cat >"$SHIM_DIR/sudo" <<'SHIM'
#!/bin/sh
while [ "$#" -gt 0 ]; do case "$1" in -*) shift;; *) break;; esac; done
exec "$@"
SHIM
chmod +x "$SHIM_DIR/sudo"
export PATH="$SHIM_DIR:$PATH"

TMPDIRS=()
mktmp() { local d; d="$(mktemp -d)"; TMPDIRS+=("$d"); echo "$d"; }
cleanup() { rm -rf "$SHIM_DIR" "${TMPDIRS[@]}"; rm -f /tmp/arm64-chroot.lock; }
trap cleanup EXIT

# =============================================================================
# arm64-chroot.sh — the single-instance lock
# =============================================================================
it "arm64-chroot: a live lock holder is rejected (no double-mount)"
sysdir="$(mktmp)"
sleep 300 & livepid=$!
printf '%s\n' "$livepid" >/tmp/arm64-chroot.lock
out="$(ARM64_SYSROOT="$sysdir" bash "$REPO/arm64-chroot.sh" true 2>&1)"; rc=$?
kill "$livepid" 2>/dev/null
rm -f /tmp/arm64-chroot.lock
assert_false "$rc"
assert_contains "$out" "Another arm64-chroot instance is running"

# =============================================================================
# sysroot-rosdep-install.sh — workspace validation
# =============================================================================
it "sysroot-rosdep-install: non-existent workspace is rejected"
out="$(ARM64_SYSROOT="$(mktmp)" bash "$REPO/sysroot-rosdep-install.sh" "/no/such/ws" 2>&1)"; rc=$?
assert_false "$rc"
assert_contains "$out" "No ROS2 workspace found"

it "sysroot-rosdep-install: workspace without a src/ folder is rejected"
ws="$(mktmp)"
out="$(ARM64_SYSROOT="$(mktmp)" bash "$REPO/sysroot-rosdep-install.sh" "$ws" 2>&1)"; rc=$?
assert_false "$rc"
assert_contains "$out" "'src' folder was not found"

# =============================================================================
# sysroot-fix.py — config listing and side-effect-free dry-run
# =============================================================================
# Needs real root: sysroot-fix re-execs via `sudo -E` when not root, which
# would loop forever under the same-uid shimmed sudo.
if [ "$(id -u)" -eq 0 ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    it "sysroot-fix: --list reads the YAML and lists packages"
    out="$(ARM64_SYSROOT="$(mktmp)" TOOLCHAINS_WS="$REPO" python3 "$REPO/sysroot-fix.py" --list 2>&1)"; rc=$?
    assert_true "$rc"
    assert_contains "$out" "Packages:"

    it "sysroot-fix: --dry-run reports intent and writes nothing to the sysroot"
    sysdir="$(mktmp)"
    out="$(ARM64_SYSROOT="$sysdir" TOOLCHAINS_WS="$REPO" python3 "$REPO/sysroot-fix.py" --dry-run 2>&1)"
    assert_contains "$out" "dry_run= True"
    n="$(find "$sysdir" -mindepth 1 | wc -l)"
    it "sysroot-fix: --dry-run left the sysroot untouched"
    assert_true "$([ "$n" -eq 0 ] && echo 0 || echo 1)"
else
    echo "  skip sysroot-fix cases (needs root + python3 + PyYAML)"
fi

finish
