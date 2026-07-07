#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# entrypoint.sh — auto-update / restart resilience tests.
#
# entrypoint.sh checks out the latest vX.Y.Z release tag on every container
# start (`git fetch --tags` + `git checkout` the highest version) so a restart
# picks up a new release without an image rebuild. The contract these tests lock
# in is: that auto-update must NEVER wedge the container. Offline, a fetch
# timeout, a remote with no release tag, or a failing post-update step must all
# fall through to a warning and let startup complete with the toolchain wrappers
# on PATH.
#
# The entrypoint is driven DIRECTLY (not through a built image) against a
# throwaway toolchain checkout wired to a local bare git remote, so the
# auto-update outcomes that need a controllable remote — a real release tag,
# version-sort selection, offline, no-tag — are reproduced with real git and
# asserted deterministically. The happy path on the real released image is
# covered by tests/integration_image_test.sh.
#
# Runs as root inside a container (see .github/workflows/test.yml) so the
# entrypoint's `sudo` calls and its `/usr/local/bin` symlinks work without a
# password. `sudo` is shimmed to a plain exec so the test needs no real
# privilege escalation.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$HERE/lib/assert.sh"

if [ ! -w /usr/local/bin ]; then
    echo "SKIP: /usr/local/bin is not writable — run this test as root (e.g. inside the CI container)." >&2
    exit 0
fi

# --- sudo shim: run the command directly (we are already root) ----------------
SHIM_DIR="$(mktemp -d)"
cat >"$SHIM_DIR/sudo" <<'SHIM'
#!/bin/sh
# drop any leading `-E`/options the callers pass, then exec the real command
while [ "$#" -gt 0 ]; do case "$1" in -*) shift;; *) break;; esac; done
exec "$@"
SHIM
chmod +x "$SHIM_DIR/sudo"

SANDBOXES=()
cleanup() { rm -rf "$SHIM_DIR" "${SANDBOXES[@]}"; }
trap cleanup EXIT

GIT_ID=(-c user.email=ci@test -c user.name=CI)

# make_sandbox — create a throwaway toolchain checkout tracking a local bare
# remote, seeded with the entrypoint + wrappers from this repo. Prints the base
# dir (which holds ./toolchains and ./remote.git).
make_sandbox() {
    local base tc remote
    base="$(mktemp -d)"; SANDBOXES+=("$base")
    tc="$base/toolchains"; remote="$base/remote.git"

    git init -q --bare --initial-branch=main "$remote"
    git clone -q "$remote" "$tc" 2>/dev/null || true
    ( cd "$tc" && git checkout -q -b main 2>/dev/null || true )

    cp "$REPO/entrypoint.sh" "$tc/"
    cp "$REPO/arm64-chroot.sh" "$REPO/sysroot-rosdep-install.sh" \
       "$REPO/cross-colcon-build.sh" "$tc/" 2>/dev/null || true
    # sysroot-fix runs only on the success path; stub it to exit 0 so the test
    # does not depend on PyYAML or a populated sysroot. Its failure-is-tolerated
    # guard (`|| echo WARN`) is covered explicitly by the "failing sub-step" case.
    printf '#!/bin/sh\nexit 0\n' >"$tc/sysroot-fix.py"
    chmod +x "$tc/sysroot-fix.py"
    mkdir -p "$tc/.vscode"
    cp "$REPO/.vscode/settings.template.json" "$tc/.vscode/" 2>/dev/null || true

    ( cd "$tc" || exit 1
      git add -A >/dev/null
      git "${GIT_ID[@]}" commit -qm init
      git push -q -u origin main >/dev/null 2>&1 )
    echo "$base"
}

# tag_remote BASE TAG MSG — push a new commit AND a release tag onto the bare
# remote (via a second clone) so the sandbox's next fetch sees a release to
# check out.
tag_remote() {
    local base="$1" tag="$2" msg="$3" work
    work="$(mktemp -d)"; SANDBOXES+=("$work")
    git clone -q --branch main "$base/remote.git" "$work/c"
    ( cd "$work/c" || exit 1
      printf '%s\n' "$msg" >>RELEASE_CHANGE
      git add -A >/dev/null
      git "${GIT_ID[@]}" commit -qm "$msg"
      git tag "$tag"
      git push -q origin HEAD:main >/dev/null 2>&1
      git push -q origin "refs/tags/$tag" >/dev/null 2>&1 )
}

# run_entry BASE [CMD...] — run the entrypoint from the sandbox with a hermetic
# env, ending in CMD (default: print a startup sentinel). Captures stdout+stderr.
run_entry() {
    local base="$1"; shift
    local tc="$base/toolchains"
    [ "$#" -gt 0 ] || set -- /bin/echo "CMD_SENTINEL"
    env -i \
        HOME=/root \
        PATH="$SHIM_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        ARM64_SYSROOT="$base/sysroot" \
        TOOLCHAINS_WS="$tc" \
        ROS2_WS="$base/no_ros2_ws" \
        PRODUCT="V2H" \
        bash "$tc/entrypoint.sh" "$@" 2>&1
}

# NOTE: plain first-start / restart / wrapper-symlink cases used to live here;
# they are covered on the REAL released image by tests/integration_image_test.sh
# (and every case below asserts "Startup Complete" in the sandbox anyway).
# Only the git edge cases that need a controllable local remote remain.

# =============================================================================
# 1. The latest release tag is checked out on start
# =============================================================================
base="$(make_sandbox)"
tag_remote "$base" "v1.0.0" "release-one"
before="$(git -C "$base/toolchains" rev-parse HEAD)"

it "1.1 latest release tag is checked out and startup completes"
out="$(run_entry "$base")"
assert_contains "$out" "checked out release v1.0.0"
assert_contains "$out" "--- Startup Complete ---"
after="$(git -C "$base/toolchains" rev-parse HEAD)"
it "1.2 local HEAD actually advanced to the tagged commit"
[ "$before" != "$after" ] && _pass "$CURRENT_TEST" \
    || _fail "$CURRENT_TEST" "HEAD did not move: still $after"

# =============================================================================
# 2. The HIGHEST version tag wins — version sort, not lexical
# =============================================================================
base="$(make_sandbox)"
tag_remote "$base" "v1.9.0"  "release-1.9"
tag_remote "$base" "v1.10.0" "release-1.10"      # lexically < v1.9.0, numerically >

it "2.1 v1.10.0 is preferred over v1.9.0 (sort -V)"
out="$(run_entry "$base")"
assert_contains "$out" "checked out release v1.10.0"
assert_contains "$out" "--- Startup Complete ---"

# =============================================================================
# 3. Offline / unreachable remote must NOT wedge the container
# =============================================================================
base="$(make_sandbox)"
git -C "$base/toolchains" remote set-url origin https://127.0.0.1:1/nope.git

it "3.1 unreachable remote -> auto-update skipped, container still starts"
out="$(run_entry "$base" /bin/echo STILL_ALIVE)"
assert_contains "$out" "Auto-update skipped"
assert_contains "$out" "--- Startup Complete ---"
assert_contains "$out" "STILL_ALIVE"

# =============================================================================
# 4. A remote with no release tag falls back to the local toolchain
# =============================================================================
base="$(make_sandbox)"                           # make_sandbox pushes no tags
before="$(git -C "$base/toolchains" rev-parse HEAD)"

it "4.1 no release tag -> fetch ok but nothing checked out, container starts"
out="$(run_entry "$base" /bin/echo NO_TAG_OK)"
assert_contains "$out" "No release tag found"
assert_contains "$out" "--- Startup Complete ---"
assert_contains "$out" "NO_TAG_OK"
after="$(git -C "$base/toolchains" rev-parse HEAD)"
it "4.2 HEAD stays put when there is no release to check out"
[ "$before" = "$after" ] && _pass "$CURRENT_TEST" \
    || _fail "$CURRENT_TEST" "HEAD moved with no release: $after"

# =============================================================================
# 5. A failing post-update step (sysroot-fix) degrades gracefully
# =============================================================================
base="$(make_sandbox)"
# Publish a release whose sysroot-fix fails, so the success path runs it and
# must survive the non-zero exit.
work="$(mktemp -d)"; SANDBOXES+=("$work")
git clone -q --branch main "$base/remote.git" "$work/c"
( cd "$work/c" || exit 1
  printf '#!/bin/sh\nexit 1\n' >sysroot-fix.py           # break it in the release
  git add -A >/dev/null
  git "${GIT_ID[@]}" commit -qm break-sysroot-fix
  git tag v1.0.0
  git push -q origin HEAD:main >/dev/null 2>&1
  git push -q origin refs/tags/v1.0.0 >/dev/null 2>&1 )

it "5.1 failing sysroot-fix is warned about but does not abort startup"
out="$(run_entry "$base" /bin/echo SURVIVED)"
assert_contains "$out" "sysroot-fix failed"
assert_contains "$out" "--- Startup Complete ---"
assert_contains "$out" "SURVIVED"

finish
