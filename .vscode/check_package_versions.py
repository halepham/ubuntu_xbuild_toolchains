#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# Description:
#   Check (and optionally synchronise) the versions of the ROS 2 "community"
#   packages that this workspace depends on, between two independent places that
#   must stay ABI-compatible:
#
#     1. TARGET_LOCAL_SYSROOT  - the ARM64 cross-compile sysroot
#        (default /opt/arm64_sysroot), queried through `arm64-chroot`.
#        This is what the host links against at build time.
#     2. The target board      - Ubuntu 24.04 ARM64 running ROS 2 Jazzy natively
#        as `ros-jazzy-*` debs, queried over SSH.
#        This is what the binaries actually run against at runtime.
#
#   "Community" packages are every dependency declared in src/*/package.xml
#   (third-party deps installed as debs), EXCLUDING the workspace's own packages
#   (which are built from source). Only packages that appear in a package.xml AND
#   are installed on BOTH sides with DIFFERING versions are treated as a
#   "version mismatch". On confirmation, BOTH the sysroot AND the board are
#   upgraded to the LATEST available version of every mismatched package, so the
#   two converge at the newest release (not merely at whichever side was ahead).
#
# Usage:
#   check_package_versions.py IP USER PASSWORD SYSROOT [SRC_DIR] [--check-only] [--yes]
#
#   --check-only  Report only; never modify either side (always safe / read-only).
#   --yes         Skip the interactive [y/N] gate and apply updates directly.
#
# Notes:
#   * All sysroot reads are batched into a single `arm64-chroot` call because the
#     wrapper holds a global lock and runs under QEMU emulation.
#   * The target board is shared lab hardware: reads are always safe, but writes
#     (apt upgrades) only ever happen after an explicit confirmation.
# -----------------------------------------------------------------------------

import argparse
import glob
import os
import shlex
import subprocess
import sys
import xml.etree.ElementTree as ET

# SSH options mirror the rest of the workspace tooling (deploy.sh / run_program.sh).
# The board is shared lab hardware whose first (cold) connection can be slow, so
# allow a slightly longer connect timeout and retry transient failures.
SSH_OPTS = [
    "-o", "ConnectTimeout=8",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
]
SSH_RETRIES = 3

# Every dependency tag we treat as a "community" dependency declaration.
DEP_TAGS = (
    "depend",
    "build_depend",
    "build_export_depend",
    "exec_depend",
    "test_depend",
    "buildtool_depend",
    "run_depend",  # package.xml format 1 spelling
)

# Fallback hints for abstract rosdep keys whose apt package name is NOT
# ros-jazzy-<name> and is NOT already an apt name. Most community deps either
# follow the ros-jazzy-<name> convention or are already written as apt names in
# package.xml, so only these few abstract system keys need an explicit hint.
SYSTEM_KEY_MAP = {
    "eigen": ["libeigen3-dev"],
    "opencv": ["libopencv-dev"],
    "boost": ["libboost-dev"],
    "fmt": ["libfmt-dev"],
    "spdlog": ["libspdlog-dev"],
    "yaml-cpp": ["libyaml-cpp-dev"],
    "yaml_cpp": ["libyaml-cpp-dev"],
}

_USE_COLOR = sys.stdout.isatty()


def _c(code, text):
    return f"\033[{code}m{text}\033[0m" if _USE_COLOR else text


def info(msg):
    print(f"{_c('0;34', '[INFO]')} {msg}")


def warn(msg):
    print(f"{_c('1;33', '[WARN]')} {msg}")


def err(msg):
    print(f"{_c('0;31', '[ERROR]')} {msg}", file=sys.stderr)


def ok(msg):
    print(f"{_c('0;32', '[OK]')} {msg}")


def step(msg):
    print(f"\n{_c('1;36', '=== ' + msg + ' ===')}")


def die(msg, code=1):
    err(msg)
    sys.exit(code)


# -----------------------------------------------------------------------------
# 1. Enumerate community dependencies from src/*/package.xml
# -----------------------------------------------------------------------------
def enumerate_community(src_dir):
    """Return (own_names, community_deps) parsed from all package.xml files under src_dir."""
    xml_files = sorted(
        glob.glob(os.path.join(src_dir, "**", "package.xml"), recursive=True)
    )

    if not xml_files:
        die(f"No package.xml found under {src_dir}")

    own_names = set()
    dep_names = set()

    for path in xml_files:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            warn(f"Skipping unparseable {path}: {exc}")
            continue

        name_el = root.find("name")
        if name_el is not None and name_el.text:
            own_names.add(name_el.text.strip())

        for tag in DEP_TAGS:
            for el in root.iter(tag):
                if el.text and el.text.strip():
                    dep_names.add(el.text.strip())

    community = dep_names - own_names

    info(
        f"Parsed {len(xml_files)} package.xml file(s): "
        f"{len(own_names)} workspace package(s), "
        f"{len(community)} community dependency name(s)."
    )

    return own_names, community


# -----------------------------------------------------------------------------
# 2. Read installed versions from the sysroot and the board
# -----------------------------------------------------------------------------
def _parse_dump(text):
    """Parse `dpkg-query -W -f='${Package}\\t${Version}\\n'` output into a dict.

    Tolerates extra non-package lines (e.g. arm64-chroot banner output) by only
    accepting lines of the exact form `name<TAB>version`.
    """
    versions = {}
    for line in text.splitlines():
        if "\t" not in line:
            continue
        name, _, ver = line.partition("\t")
        name, ver = name.strip(), ver.strip()
        if name and ver and " " not in name:
            versions[name] = ver
    return versions


def sysroot_dump(sysroot):
    """Query all installed packages inside the sysroot via a single chroot call."""
    env = dict(os.environ, ARM64_SYSROOT=sysroot)
    snippet = r"dpkg-query -W -f='${Package}\t${Version}\n'"
    res = subprocess.run(
        ["arm64-chroot", "bash", "-c", snippet],
        capture_output=True, text=True, env=env,
    )
    versions = _parse_dump(res.stdout)
    if not versions:
        die("Could not read any package versions from the sysroot via "
            f"arm64-chroot.\n{res.stderr.strip()}")
    info(f"Sysroot: {len(versions)} installed package(s).")
    return versions


def _ssh(ip, user, password, remote, retries=SSH_RETRIES):
    """Run a remote command over SSH, retrying transient connection failures.

    Returns the last CompletedProcess. Read-only callers should treat a non-zero
    return code as "unreachable"; the board is shared hardware whose first
    connection can time out.
    """
    res = None
    for _ in range(retries):
        res = subprocess.run(
            ["sshpass", "-p", password, "ssh", *SSH_OPTS, f"{user}@{ip}", remote],
            capture_output=True, text=True,
        )
        if res.returncode == 0:
            return res
    return res


def board_probe(ip, user, password):
    res = _ssh(ip, user, password, "echo OK")
    return res is not None and res.returncode == 0 and "OK" in res.stdout


def board_dump(ip, user, password):
    """Query all installed packages on the board over SSH (read-only)."""
    snippet = r"dpkg-query -W -f='${Package}\t${Version}\n'"
    res = _ssh(ip, user, password, snippet)
    versions = _parse_dump(res.stdout if res else "")
    if not versions:
        die("Could not read any package versions from the board.\n"
            f"{res.stderr.strip() if res else ''}")
    info(f"Board {ip}: {len(versions)} installed package(s).")
    return versions


# -----------------------------------------------------------------------------
# 3. Map a package.xml dependency name to its apt package name
# -----------------------------------------------------------------------------
def candidate_apt_names(key):
    """Ordered candidate apt names for a package.xml dependency key."""
    dashed = key.replace("_", "-")
    cands = list(SYSTEM_KEY_MAP.get(key, []))
    cands += [f"ros-jazzy-{dashed}", key, dashed]
    seen, out = set(), []
    for c in cands:
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


def resolve_key(key, known):
    """Pick the first candidate apt name that is actually installed somewhere."""
    for cand in candidate_apt_names(key):
        if cand in known:
            return cand
    return None


def rosdep_resolve(keys, sysroot):
    """Best-effort fallback: resolve keys via rosdep inside the sysroot.

    Only invoked for keys that the cheap transform could not place. Uses a
    labelled loop so each key's output is unambiguous. Returns {key: [apt,...]}.
    """
    if not keys:
        return {}
    env = dict(os.environ, ARM64_SYSROOT=sysroot)
    key_list = " ".join(shlex.quote(k) for k in keys)
    snippet = (
        f'for k in {key_list}; do '
        f'echo "ROSDEP_KEY=$k"; '
        f'rosdep resolve "$k" 2>/dev/null || true; '
        f'done'
    )
    res = subprocess.run(
        ["arm64-chroot", "bash", "-c", snippet],
        capture_output=True, text=True, env=env,
    )
    mapping, current = {}, None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.startswith("ROSDEP_KEY="):
            current = line[len("ROSDEP_KEY="):]
            mapping[current] = []
        elif current and line and not line.startswith("#"):
            mapping[current].extend(line.split())
    return {k: v for k, v in mapping.items() if v}


# -----------------------------------------------------------------------------
# 4. Compare versions (Debian version semantics, via host dpkg)
# -----------------------------------------------------------------------------
def deb_compare(a, b):
    """-1 if a < b, 0 if equal, 1 if a > b, using `dpkg --compare-versions`."""
    if a == b:
        return 0
    if subprocess.run(["dpkg", "--compare-versions", a, "eq", b]).returncode == 0:
        return 0
    if subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0:
        return -1
    return 1


def compare(community, sysroot_v, board_v):
    """Map each community key to an installed apt name.

    Returns (resolved, stragglers): `resolved` is {key: apt_name} for keys whose
    apt package is installed on at least one side; `stragglers` are keys with no
    installed apt match (not installed anywhere -> cannot be version-mismatched).
    """
    known = set(sysroot_v) | set(board_v)

    # Resolve names; collect stragglers for the optional rosdep fallback.
    resolved, stragglers = {}, []
    for key in sorted(community):
        apt = resolve_key(key, known)
        if apt is None:
            stragglers.append(key)
        else:
            resolved[key] = apt
    return resolved, stragglers


def build_report(resolved, sysroot_v, board_v):
    matched, mismatches, missing, absent = [], [], [], []
    for key, apt in sorted(resolved.items()):
        sv, bv = sysroot_v.get(apt), board_v.get(apt)
        if sv and bv:
            cmp = deb_compare(sv, bv)
            if cmp == 0:
                matched.append((key, apt, sv))
            else:
                outdated = "sysroot" if cmp < 0 else "board"
                target = bv if cmp < 0 else sv
                mismatches.append({
                    "key": key, "apt": apt, "sysroot": sv, "board": bv,
                    "outdated": outdated, "target": target,
                })
        elif sv and not bv:
            missing.append((key, apt, "board", sv))
        elif bv and not sv:
            missing.append((key, apt, "sysroot", bv))
        else:
            absent.append((key, apt))
    return matched, mismatches, missing, absent


# -----------------------------------------------------------------------------
# 5. Reporting
# -----------------------------------------------------------------------------
def print_report(matched, mismatches, missing, absent, stragglers):
    step("Version comparison")

    if mismatches:
        name_w = max([len(m["apt"]) for m in mismatches] + [len("PACKAGE")])
        sv_w = max([len(m["sysroot"]) for m in mismatches] + [len("SYSROOT")])
        bv_w = max([len(m["board"]) for m in mismatches] + [len("BOARD")])
        vd_w = len("SYSROOT OUTDATED")
        warn(f"{len(mismatches)} version mismatch(es) found:")
        print()
        print("    " + _c("1", f"{'PACKAGE':<{name_w}}  {'SYSROOT':<{sv_w}}  "
                                f"{'BOARD':<{bv_w}}  VERDICT"))
        print("    " + "  ".join(["-" * name_w, "-" * sv_w, "-" * bv_w, "-" * vd_w]))
        for m in mismatches:
            verdict = ("SYSROOT OUTDATED" if m["outdated"] == "sysroot"
                       else "BOARD OUTDATED")
            print(f"    {m['apt']:<{name_w}}  {m['sysroot']:<{sv_w}}  "
                  f"{m['board']:<{bv_w}}  {_c('1;33', verdict)}")
        print()
    else:
        ok("No version mismatches between the sysroot and the board.")

    # The "one side only" and "not comparable" buckets are expected and noisy,
    # so they are intentionally not listed in detail — only their counts appear
    # in the summary below.
    not_comparable = [a[0] for a in absent] + list(stragglers)

    step("Summary")
    print(f"  {_c('0;32', 'in sync')}        : {len(matched)}")
    print(f"  {_c('1;33', 'mismatched')}     : {len(mismatches)}")
    print(f"  one side only  : {len(missing)}")
    print(f"  not comparable : {len(not_comparable)}")


# -----------------------------------------------------------------------------
# 6. Confirmation + update
# -----------------------------------------------------------------------------
def confirm(prompt):
    """Read a [y/N] answer from the controlling terminal."""
    try:
        with open("/dev/tty", "r") as tty:
            sys.stdout.write(prompt)
            sys.stdout.flush()
            return tty.readline().strip().lower() in ("y", "yes")
    except OSError:
        warn("No interactive terminal available; assuming 'no'. "
             "Re-run with --yes to apply updates non-interactively.")
        return False


def update_sysroot(sysroot, names):
    """Upgrade the given packages to the LATEST available version inside the
    sysroot. `names` is a list of apt package names. Single chroot call."""
    env = dict(os.environ, ARM64_SYSROOT=sysroot)
    joined = " ".join(names)
    snippet = f"apt-get update && apt-get install -y --only-upgrade {joined}"
    info(f"Sysroot command: arm64-chroot bash -c \"{snippet}\"")
    res = subprocess.run(["arm64-chroot", "bash", "-c", snippet], env=env)
    return res.returncode == 0


def fix_sysroot(sysroot):
    """Re-run `sysroot-fix` after a successful apt upgrade in the sysroot.

    An apt upgrade reinstalls each package's exported CMake target files with
    hardcoded absolute paths, so the relativisation applied at image-build time
    (see sysroot-rosdep-install.sh) must be re-applied or cross builds resolve
    the wrong prefixes. Runs the same `sysroot-fix` wrapper with ARM64_SYSROOT
    pointed at this sysroot; a missing wrapper is a warning, not a hard failure.
    """
    env = dict(os.environ, ARM64_SYSROOT=sysroot)
    info("Sysroot command: sysroot-fix")
    try:
        res = subprocess.run(["sysroot-fix"], env=env)
    except FileNotFoundError:
        warn("`sysroot-fix` not found on PATH; skipping CMake path fixups. "
             "Cross builds may resolve absolute paths from the sysroot.")
        return False
    return res.returncode == 0


def update_board(ip, user, password, names):
    """Upgrade the given packages to the LATEST available version on the board.
    `names` is a list of apt package names. Single SSH call. SHARED HARDWARE."""
    q = shlex.quote(password)
    joined = " ".join(names)
    remote = (f"echo {q} | sudo -S apt-get update && "
              f"echo {q} | sudo -S apt-get install -y --only-upgrade {joined}")
    info(f"Board command: ssh {user}@{ip} "
         f"'<sudo apt-get install -y --only-upgrade {joined}>'")
    res = subprocess.run(
        ["sshpass", "-p", password, "ssh", *SSH_OPTS, f"{user}@{ip}", remote]
    )
    return res.returncode == 0


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Check/sync ROS 2 community-package versions between the "
                    "ARM64 sysroot and the target board.")
    ap.add_argument("ip")
    ap.add_argument("user")
    ap.add_argument("password")
    ap.add_argument("sysroot", nargs="?", default="")
    ap.add_argument("src_dir", nargs="?", default="")
    ap.add_argument("--check-only", action="store_true",
                    help="Report only; never modify either side.")
    ap.add_argument("--yes", action="store_true",
                    help="Apply updates without the interactive [y/N] gate.")
    ap.add_argument("--rosdep", action="store_true",
                    help="For dependencies with no installed apt match, fall back "
                         "to `rosdep resolve` inside the sysroot. Slow under QEMU "
                         "and only useful for abstract system keys; off by default "
                         "because unmatched deps are not installed on either side "
                         "and thus cannot be version-mismatched anyway.")
    args = ap.parse_args()

    sysroot = args.sysroot
    if not sysroot or sysroot.startswith("${"):
        sysroot = os.environ.get("ARM64_SYSROOT", "")
    if not sysroot or not os.path.isdir(sysroot):
        die(f"Sysroot directory not found: {sysroot!r} "
            "(pass it as arg 4 or export ARM64_SYSROOT).")

    src_dir = args.src_dir
    if not src_dir:
        # Default to <workspace>/src relative to this script (.vscode/..).
        src_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")
    if not os.path.isdir(src_dir):
        die(f"Source directory not found: {src_dir}")

    step("Enumerating community dependencies")
    info(f"Sysroot : {sysroot}")
    info(f"Board   : {args.user}@{args.ip}")
    info(f"Source  : {src_dir}")
    _own, community = enumerate_community(src_dir)

    step("Probing target board")
    if not board_probe(args.ip, args.user, args.password):
        die(f"Cannot reach board {args.user}@{args.ip} (SSH probe failed).")
    ok("Board reachable.")

    step("Reading installed package versions")
    board_v = board_dump(args.ip, args.user, args.password)
    sysroot_v = sysroot_dump(sysroot)

    resolved, stragglers = compare(community, sysroot_v, board_v)
    if stragglers and args.rosdep:
        info(f"Resolving {len(stragglers)} unmapped dependency(ies) via rosdep "
             "(slow under QEMU)...")
        extra = rosdep_resolve(stragglers, sysroot)
        known = set(sysroot_v) | set(board_v)
        still = []
        for key in stragglers:
            apt_names = extra.get(key, [])
            chosen = next((a for a in apt_names if a in known), None)
            if chosen:
                resolved[key] = chosen
            else:
                still.append(key)
        stragglers = still

    matched, mismatches, missing, absent = build_report(resolved, sysroot_v, board_v)
    print_report(matched, mismatches, missing, absent, stragglers)

    if not mismatches:
        ok("All community packages are in sync between the sysroot and the board.")
        return 0

    if args.check_only:
        warn(f"{len(mismatches)} version mismatch(es) found (--check-only: no "
             "changes made).")
        return 2

    # On any mismatch, bring BOTH the sysroot AND the board up to the latest
    # available version of each mismatched package, so they converge at the
    # newest release. The side that is already current is a harmless no-op.
    update_pkgs = sorted({m["apt"] for m in mismatches})

    step("Proposed updates")
    warn(f"{len(update_pkgs)} mismatched package(s) will be upgraded to the "
         "LATEST available version on BOTH the sysroot AND the board "
         "(board is SHARED LAB HARDWARE):")
    for m in mismatches:
        behind = "sysroot behind" if m["outdated"] == "sysroot" else "board behind"
        print(f"    {m['apt']}  (sysroot={m['sysroot']}, board={m['board']}; "
              f"{behind} -> latest)")

    if not args.yes and not confirm(
            _c("1;33", "\nApply these updates? [y/N] ")):
        warn("Aborted by user. No changes made.")
        return 2

    step("Updating sysroot")
    if update_sysroot(sysroot, update_pkgs):
        # Only relativise CMake paths once the upgrade actually succeeded; a
        # failed/partial apt run leaves nothing new to fix.
        step("Fixing sysroot (sysroot-fix)")
        if not fix_sysroot(sysroot):
            warn("sysroot-fix reported a failure; check CMake paths manually.")
    else:
        err("Sysroot update reported a failure.")
    step("Updating board")
    if not update_board(args.ip, args.user, args.password, update_pkgs):
        err("Board update reported a failure.")

    # Re-read and reconcile.
    step("Re-checking after update")
    board_v = board_dump(args.ip, args.user, args.password)
    sysroot_v = sysroot_dump(sysroot)
    _matched2, mismatches2, _missing2, _absent2 = build_report(
        resolved, sysroot_v, board_v)
    if mismatches2:
        warn(f"{len(mismatches2)} package(s) still mismatched after update:")
        for m in mismatches2:
            print(f"    {m['apt']}: sysroot={m['sysroot']} board={m['board']}")
        return 1
    ok("All previously mismatched packages are now in sync.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
