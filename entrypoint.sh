#!/bin/bash
set -uo pipefail

# Require ARM64_SYSROOT to be set (prevents accidental writes)
: "${ARM64_SYSROOT:?ARM64_SYSROOT is not set}"

echo "Updating DNS configuration in sysroot..."
mkdir -p "${ARM64_SYSROOT}/etc"
if ! sudo cp /etc/resolv.conf "${ARM64_SYSROOT}/etc/resolv.conf" 2>/dev/null; then
    echo "[WARN] Could not update DNS in sysroot."
fi
echo "DNS updated in sysroot."

# Toolchain auto-update: the GitHub repo root IS the toolchains directory.
# Uses git archive to overlay the entire remote tree locally.
# Detection uses git diff-tree between remote origin/main and local HEAD,
# excluding sysroot-fix-append.yaml (gitignored locally).
# Note: Failure here is non-fatal — container continues normally.
TOOLCHAIN_DIR="${TOOLCHAINS_WS:-/home/ubuntu/toolchains}"
if [ -d "$TOOLCHAIN_DIR/.git" ]; then
    cd "$TOOLCHAIN_DIR"

    # Public GitHub repo — no token needed.
    git remote add origin https://github.com/renesas-rdk/ubuntu-xbuild-toolchains.git 2>/dev/null || true

    if git remote get-url origin >/dev/null 2>&1; then
        echo "[INFO] Checking for toolchain updates..."
        if timeout 10 git fetch origin main >/dev/null 2>&1; then
            # Use git diff-tree to list files changed between remote and local,
            # excluding sysroot-fix-append.yaml (gitignored locally).
            if git diff-tree --no-commit-id -r origin/main HEAD: 2>/dev/null | \
                awk '{print $NF}' | grep -v -x 'sysroot-fix-append.yaml' | grep -q .; then
                    echo "[INFO] Toolchain updates found. Applying..."
                    # Overlay entire remote tree. Exclude append file so user
                    # custom entries survive updates.
                    git archive origin/main | tar xf - \
                        -C "$TOOLCHAIN_DIR" --exclude=sysroot-fix-append.yaml
                    # Re-apply local-only .gitignore entry (overlay may overwrite it)
                    grep -qxF "sysroot-fix-append.yaml" .gitignore 2>/dev/null || \
                        echo "sysroot-fix-append.yaml" >> .gitignore
                    # Create new snapshot commit so subsequent diff-tree comparisons
                    # correctly reflect the already-applied state.
                    git add -A
                    git commit -m "snapshot $(date +%Y%m%d-%H%M%S)" --allow-empty
                    echo "[INFO] Toolchain synchronized."
                    sudo /usr/local/bin/sysroot-rosdep-install || echo "[WARN] sysroot-rosdep-install failed, skipping."
            else
                if git rev-parse origin/main >/dev/null 2>&1; then
                    echo "[INFO] Toolchain is up to date."
                else
                    echo "[INFO] Remote does not contain toolchains/ path. Skipping."
                fi
            fi
        else
            echo "[WARN] Could not fetch updates from remote (timeout 10s)."
        fi
    else
        echo "[INFO] No git remote configured. Auto-update disabled."
    fi
fi

echo "--- Startup Complete ---"

exec "$@"
