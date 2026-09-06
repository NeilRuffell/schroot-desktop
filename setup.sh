#!/bin/bash
set -euo pipefail

PROGRAM=${0##*/}
REPO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DESKTOP=
TARGET_USER=${SUDO_USER:-}
MATE_ROOT=/srv/xenial
UNITY_ROOT=/srv/xenial-unity

usage() {
    cat <<EOF
Usage: sudo ./$PROGRAM [OPTIONS]

Create missing Xenial desktop roots and converge existing roots in one pass.

Options:
  --desktop CHOICE   mate, unity, or both (interactive when omitted)
  --target-user USER Debian desktop account (default: SUDO_USER)
  --mate-root PATH   MATE root (default: /srv/xenial)
  --unity-root PATH  Unity root (default: /srv/xenial-unity)
  -h, --help         Show this help
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

while (($#)); do
    case $1 in
        --desktop)
            (($# >= 2)) || die "--desktop requires a value"
            DESKTOP=$2
            shift
            ;;
        --target-user)
            (($# >= 2)) || die "--target-user requires a value"
            TARGET_USER=$2
            shift
            ;;
        --mate-root)
            (($# >= 2)) || die "--mate-root requires a value"
            MATE_ROOT=$2
            shift
            ;;
        --unity-root)
            (($# >= 2)) || die "--unity-root requires a value"
            UNITY_ROOT=$2
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

[[ $EUID == 0 ]] || die "run this setup with sudo"
[[ -n $TARGET_USER ]] ||
    die "cannot determine the desktop user; supply --target-user"
[[ $TARGET_USER =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] ||
    die "unsupported target-user syntax: $TARGET_USER"
getent passwd "$TARGET_USER" >/dev/null || die "unknown user: $TARGET_USER"
[[ $MATE_ROOT = /* && $MATE_ROOT != / && \
    $MATE_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid MATE root"
[[ $UNITY_ROOT = /* && $UNITY_ROOT != / && \
    $UNITY_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid Unity root"
[[ $MATE_ROOT != "$UNITY_ROOT" ]] || die "MATE and Unity roots must differ"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] ||
    die "setup is currently supported only on Debian 13"
[[ $(dpkg --print-architecture) == amd64 ]] || die "only amd64 is tested"

if [[ -z $DESKTOP ]]; then
    [[ -t 0 ]] || die "supply --desktop when input is not interactive"
    cat <<'EOF'
Select the Xenial desktop experience:
  1) Ubuntu Unity 16.04
  2) Ubuntu MATE 16.04
  3) Both (default)
EOF
    read -r -p "Choice [3]: " choice
    case ${choice:-3} in
        1|unity) DESKTOP=unity ;;
        2|mate) DESKTOP=mate ;;
        3|both) DESKTOP=both ;;
        *) die "invalid desktop choice" ;;
    esac
fi
[[ $DESKTOP == mate || $DESKTOP == unity || $DESKTOP == both ]] ||
    die "--desktop must be mate, unity, or both"

if find /var/lib/schroot/session -maxdepth 1 -type f -print -quit \
    2>/dev/null | grep -q .; then
    die "a schroot session is active; log out before setup or update"
fi

root_state() {
    local root=$1
    if [[ ! -e $root ]]; then
        echo missing
        return
    fi
    if [[ -r $root/etc/os-release ]] && (
        # shellcheck disable=SC1090
        . "$root/etc/os-release"
        [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 16.04 ]]
    ); then
        echo existing
        return
    fi
    die "$root exists but is not an Ubuntu 16.04 root; it was not modified"
}

MATE_STATE=unselected
UNITY_STATE=unselected
if [[ $DESKTOP == mate || $DESKTOP == both ]]; then
    MATE_STATE=$(root_state "$MATE_ROOT")
fi
if [[ $DESKTOP == unity || $DESKTOP == both ]]; then
    UNITY_STATE=$(root_state "$UNITY_ROOT")
fi

echo "Setup selection: $DESKTOP"
echo "  MATE:  $MATE_STATE"
echo "  Unity: $UNITY_STATE"

BOOTSTRAP_DESKTOP=
if [[ $MATE_STATE == missing && $UNITY_STATE == missing ]]; then
    BOOTSTRAP_DESKTOP=both
elif [[ $MATE_STATE == missing ]]; then
    BOOTSTRAP_DESKTOP=mate
elif [[ $UNITY_STATE == missing ]]; then
    BOOTSTRAP_DESKTOP=unity
fi

if [[ -n $BOOTSTRAP_DESKTOP ]]; then
    "$REPO_DIR/bootstrap.sh" create --apply --install-host-packages \
        --desktop "$BOOTSTRAP_DESKTOP" --target-user "$TARGET_USER" \
        --mate-root "$MATE_ROOT" --unity-root "$UNITY_ROOT"
fi

"$REPO_DIR/install.sh" update --install-packages \
    --desktop "$DESKTOP" --target-user "$TARGET_USER" \
    --mate-root "$MATE_ROOT" --unity-root "$UNITY_ROOT"
"$REPO_DIR/install.sh" check \
    --desktop "$DESKTOP" --target-user "$TARGET_USER" \
    --mate-root "$MATE_ROOT" --unity-root "$UNITY_ROOT"

echo
echo "Setup completed and passed the static installation check."
echo "Log in through LightDM and select the installed Xenial desktop."
