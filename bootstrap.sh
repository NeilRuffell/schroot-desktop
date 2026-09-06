#!/bin/bash
set -euo pipefail

PROGRAM=${0##*/}
REPO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
COMMAND=plan
DESKTOP=both
APPLY=false
INSTALL_HOST_PACKAGES=false
TARGET_USER=${SUDO_USER:-${USER:-}}
MATE_ROOT=/srv/xenial
UNITY_ROOT=/srv/xenial-unity
MIRROR=http://archive.ubuntu.com/ubuntu/
TARGET_LOCALE=en_US.UTF-8

usage() {
    cat <<EOF
Usage: $PROGRAM [plan|create] [OPTIONS]

Bootstrap fresh Ubuntu 16.04 MATE and/or Unity roots. Existing roots are never
overwritten. Run install.sh afterward to deploy host integration.

Options:
  --apply                    Required with create
  --target-user USER         Desktop account (default: SUDO_USER/current user)
  --desktop CHOICE           mate, unity, or both (default: both)
  --mate-root PATH           New MATE root (default: /srv/xenial)
  --unity-root PATH          New Unity root (default: /srv/xenial-unity)
  --mirror URL               Xenial archive mirror
  --locale LOCALE            Root locale (default: en_US.UTF-8)
  --install-host-packages    Install debootstrap/Ubuntu keyring if missing
  -h, --help                 Show this help
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

read_manifest() {
    local manifest=$1 array_name=$2 line
    local -n destination=$array_name
    [[ -r $manifest ]] || die "package manifest is missing: $manifest"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        read -r line <<<"$line"
        [[ -n $line ]] && destination+=("$line")
    done <"$manifest"
}

while (($#)); do
    case $1 in
        plan|create)
            COMMAND=$1
            ;;
        --apply)
            APPLY=true
            ;;
        --install-host-packages)
            INSTALL_HOST_PACKAGES=true
            ;;
        --target-user)
            (($# >= 2)) || die "--target-user requires a value"
            TARGET_USER=$2
            shift
            ;;
        --desktop)
            (($# >= 2)) || die "--desktop requires a value"
            DESKTOP=$2
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
        --mirror)
            (($# >= 2)) || die "--mirror requires a value"
            MIRROR=$2
            shift
            ;;
        --locale)
            (($# >= 2)) || die "--locale requires a value"
            TARGET_LOCALE=$2
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

[[ $TARGET_USER =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] ||
    die "unsupported target-user syntax: $TARGET_USER"
[[ $DESKTOP == mate || $DESKTOP == unity || $DESKTOP == both ]] ||
    die "--desktop must be mate, unity, or both"
WANT_MATE=false
WANT_UNITY=false
if [[ $DESKTOP == mate || $DESKTOP == both ]]; then
    WANT_MATE=true
fi
if [[ $DESKTOP == unity || $DESKTOP == both ]]; then
    WANT_UNITY=true
fi
[[ $MATE_ROOT = /* && $MATE_ROOT != / ]] || die "invalid MATE root"
[[ $UNITY_ROOT = /* && $UNITY_ROOT != / ]] || die "invalid Unity root"
[[ $MATE_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die "unsupported MATE root path"
[[ $UNITY_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die "unsupported Unity root path"
[[ $MATE_ROOT != "$UNITY_ROOT" ]] || die "MATE and Unity roots must differ"
[[ $MIRROR =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || die "unsupported mirror URL"
[[ $TARGET_LOCALE =~ ^[A-Za-z_]+\.UTF-8$ ]] || die "unsupported locale syntax"

USER_RECORD=$(getent passwd "$TARGET_USER") || die "unknown user: $TARGET_USER"
IFS=: read -r _ _ TARGET_UID TARGET_GID _ TARGET_HOME _ <<<"$USER_RECORD"
[[ $TARGET_UID != 0 ]] || die "target user must not be root"
[[ $TARGET_HOME = /* && $TARGET_HOME != / ]] || die "unsafe target home"

# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] ||
    die "root bootstrap is currently supported only on Debian 13"
[[ $(dpkg --print-architecture) == amd64 ]] || die "only amd64 is tested"

COMMON_PACKAGES=()
MATE_PACKAGES=()
UNITY_PACKAGES=()
UNITY_ESSENTIALS=()
read_manifest "$REPO_DIR/packages/chroot-common.txt" COMMON_PACKAGES
read_manifest "$REPO_DIR/packages/mate-core.txt" MATE_PACKAGES
read_manifest "$REPO_DIR/packages/unity-core.txt" UNITY_PACKAGES
read_manifest "$REPO_DIR/packages/unity-essentials.txt" UNITY_ESSENTIALS

show_plan() {
    cat <<EOF
Schroot Desktop bootstrap plan
  target user: $TARGET_USER ($TARGET_UID:$TARGET_GID)
  desktop:     $DESKTOP
  shared home: $TARGET_HOME
EOF
    if [[ $WANT_MATE == true ]]; then
        printf '  MATE root:   %s\n' "$MATE_ROOT"
    fi
    if [[ $WANT_UNITY == true ]]; then
        printf '  Unity root:  %s\n' "$UNITY_ROOT"
    fi
    cat <<EOF
  mirror:      $MIRROR
  locale:      $TARGET_LOCALE
  architecture: amd64

The operation creates the selected fresh root(s) and never overwrites an existing path.
Package counts:
  common:           ${#COMMON_PACKAGES[@]}
EOF
    if [[ $WANT_MATE == true ]]; then
        printf '  MATE:             %s\n' "${#MATE_PACKAGES[@]}"
    fi
    if [[ $WANT_UNITY == true ]]; then
        printf '  Unity core:       %s\n' "${#UNITY_PACKAGES[@]}"
        printf '  Unity essentials: %s\n' "${#UNITY_ESSENTIALS[@]}"
    fi
    local roots=()
    if [[ $WANT_MATE == true ]]; then
        roots+=("$MATE_ROOT")
    fi
    if [[ $WANT_UNITY == true ]]; then
        roots+=("$UNITY_ROOT")
    fi
    for root in "${roots[@]}"; do
        if [[ -e $root ]]; then
            echo "  BLOCKED existing path: $root"
        else
            echo "  READY new path: $root"
        fi
    done
}

show_plan
[[ $COMMAND == create ]] || exit 0
[[ $APPLY == true ]] || die "create is disabled unless --apply is supplied"
[[ $EUID == 0 ]] || die "create must be run as root"
if [[ $WANT_MATE == true ]]; then
    [[ ! -e $MATE_ROOT ]] || die "refusing existing MATE root: $MATE_ROOT"
fi
if [[ $WANT_UNITY == true ]]; then
    [[ ! -e $UNITY_ROOT ]] || die "refusing existing Unity root: $UNITY_ROOT"
fi

BOOTSTRAP_HOST_MISSING=()
for package in debootstrap ubuntu-keyring; do
    if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null |
        grep -qx installed; then
        BOOTSTRAP_HOST_MISSING+=("$package")
    fi
done
if ((${#BOOTSTRAP_HOST_MISSING[@]})); then
    [[ $INSTALL_HOST_PACKAGES == true ]] ||
        die "bootstrap dependencies are missing; use --install-host-packages"
    apt-get update
    apt-get install -y "${BOOTSTRAP_HOST_MISSING[@]}"
fi
UBUNTU_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
[[ -r $UBUNTU_KEYRING ]] || die "Ubuntu archive keyring is missing"
command -v wget >/dev/null || die "wget is required to validate the mirror"
RELEASE_URL=${MIRROR%/}/dists/xenial/Release
wget --spider --quiet "$RELEASE_URL" ||
    die "Xenial release file is unavailable: $RELEASE_URL"

create_account() {
    local root=$1 group_name existing_user
    group_name=$(awk -F: -v gid="$TARGET_GID" '$3 == gid {print $1; exit}' \
        "$root/etc/group")
    if [[ -z $group_name ]]; then
        /usr/sbin/chroot "$root" groupadd --gid "$TARGET_GID" "$TARGET_USER"
    fi
    existing_user=$(awk -F: -v user="$TARGET_USER" '$1 == user {print $3 ":" $4}' \
        "$root/etc/passwd")
    if [[ -n $existing_user && $existing_user != "$TARGET_UID:$TARGET_GID" ]]; then
        die "$TARGET_USER already has the wrong UID/GID in $root"
    fi
    if [[ -z $existing_user ]]; then
        /usr/sbin/chroot "$root" useradd --no-create-home --uid "$TARGET_UID" \
            --gid "$TARGET_GID" --home-dir "$TARGET_HOME" \
            --shell /bin/bash "$TARGET_USER"
        /usr/sbin/chroot "$root" passwd --lock "$TARGET_USER"
    fi
}

configure_root() {
    local root=$1 desktop=$2
    shift 2
    local packages=("$@")

    printf '%s\n' \
        "deb $MIRROR xenial main restricted universe multiverse" \
        "deb $MIRROR xenial-updates main restricted universe multiverse" \
        "deb $MIRROR xenial-security main restricted universe multiverse" \
        >"$root/etc/apt/sources.list"
    printf '%s\n' '#!/bin/sh' 'exit 101' >"$root/usr/sbin/policy-rc.d"
    chmod 0755 "$root/usr/sbin/policy-rc.d"

    /usr/sbin/chroot "$root" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get update
    /usr/sbin/chroot "$root" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "${packages[@]}"

    /usr/sbin/chroot "$root" locale-gen "$TARGET_LOCALE"
    printf 'LANG=%s\n' "$TARGET_LOCALE" >"$root/etc/default/locale"
    create_account "$root"
    /usr/sbin/chroot "$root" dbus-uuidgen --ensure=/etc/machine-id

    if [[ -e $root/etc/xdg/autostart/update-notifier.desktop ]]; then
        /usr/sbin/chroot "$root" dpkg-divert --local --rename --add \
            /etc/xdg/autostart/update-notifier.desktop
    fi
    echo "Configured $desktop root: $root"
}

if [[ $WANT_MATE == true ]]; then
    echo "Bootstrapping MATE root..."
    debootstrap --arch=amd64 --keyring="$UBUNTU_KEYRING" \
        xenial "$MATE_ROOT" "$MIRROR"
    configure_root "$MATE_ROOT" MATE \
        "${COMMON_PACKAGES[@]}" "${MATE_PACKAGES[@]}"
fi

if [[ $WANT_UNITY == true ]]; then
    echo "Bootstrapping Unity root..."
    debootstrap --arch=amd64 --keyring="$UBUNTU_KEYRING" \
        xenial "$UNITY_ROOT" "$MIRROR"
    configure_root "$UNITY_ROOT" Unity \
        "${COMMON_PACKAGES[@]}" "${UNITY_PACKAGES[@]}" "${UNITY_ESSENTIALS[@]}"
fi

cat <<EOF

Bootstrap complete. The roots are not active yet.
Next run:
  sudo $REPO_DIR/install.sh install --desktop $DESKTOP --target-user $TARGET_USER --install-packages
EOF
