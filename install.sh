#!/bin/bash
set -euo pipefail

PROGRAM=${0##*/}
REPO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
COMMAND=check
TARGET_USER=${SUDO_USER:-${USER:-}}
MATE_ROOT=/srv/xenial
UNITY_ROOT=/srv/xenial-unity
DRY_RUN=false
INSTALL_PACKAGES=false
BACKUP_DIR=
TEMP_DIR=

HOST_PACKAGES=(
    schroot lightdm dbus-x11 python3 python3-gi
    appmenu-gtk3-module gir1.2-dbusmenu-glib-0.4
    gir1.2-dbusmenu-gtk3-0.4 gir1.2-gtk-3.0
    x11-utils desktop-file-utils mate-polkit blueman
    caja gvfs gvfs-backends gvfs-fuse lxappearance
)

usage() {
    cat <<EOF
Usage: $PROGRAM [check|install] [OPTIONS]

Install the documented Schroot Desktop integration into existing Xenial roots.
This installer does not bootstrap the Xenial root filesystems.

Options:
  --target-user USER       Desktop account (default: SUDO_USER/current user)
  --mate-root PATH         Existing MATE root (default: /srv/xenial)
  --unity-root PATH        Existing Unity root (default: /srv/xenial-unity)
  --dry-run                Show install actions without changing the system
  --install-packages       Install missing Debian host dependencies with APT
  -h, --help               Show this help
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

note() {
    echo "$*"
}

cleanup() {
    if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT

while (($#)); do
    case $1 in
        check|install)
            COMMAND=$1
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
        --dry-run)
            DRY_RUN=true
            ;;
        --install-packages)
            INSTALL_PACKAGES=true
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

[[ -n $TARGET_USER ]] || die "target user is required"
[[ $TARGET_USER =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] ||
    die "unsupported target-user syntax: $TARGET_USER"
[[ $MATE_ROOT = /* && $MATE_ROOT != / ]] || die "invalid MATE root: $MATE_ROOT"
[[ $UNITY_ROOT = /* && $UNITY_ROOT != / ]] || die "invalid Unity root: $UNITY_ROOT"
[[ $MATE_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die "unsupported MATE root path"
[[ $UNITY_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die "unsupported Unity root path"
[[ $MATE_ROOT != "$UNITY_ROOT" ]] || die "MATE and Unity roots must be different"

command -v getent >/dev/null || die "getent is required"
USER_RECORD=$(getent passwd "$TARGET_USER") || die "unknown user: $TARGET_USER"
IFS=: read -r _ _ TARGET_UID TARGET_GID _ TARGET_HOME _ <<<"$USER_RECORD"
[[ $TARGET_UID != 0 ]] || die "target user must not be root"
[[ $TARGET_HOME = /* && $TARGET_HOME != / ]] || die "unsafe home: $TARGET_HOME"

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] ||
        die "supported host is Debian 13; found ${PRETTY_NAME:-unknown}"
else
    die "cannot identify host operating system"
fi
[[ $(dpkg --print-architecture) == amd64 ]] || die "only amd64 is currently tested"

validate_root() {
    local label=$1 root=$2 root_user
    [[ -d $root ]] || die "$label root does not exist: $root"
    [[ -r $root/etc/os-release ]] || die "$label root has no /etc/os-release"
    (
        # shellcheck disable=SC1090
        . "$root/etc/os-release"
        [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 16.04 ]]
    ) || die "$label root is not Ubuntu 16.04: $root"
    root_user=$(awk -F: -v user="$TARGET_USER" '$1 == user {print $3 ":" $4}' "$root/etc/passwd")
    [[ $root_user == "$TARGET_UID:$TARGET_GID" ]] ||
        die "$TARGET_USER must be UID:GID $TARGET_UID:$TARGET_GID in $label root"
}

validate_root MATE "$MATE_ROOT"
validate_root Unity "$UNITY_ROOT"

missing_packages=()
for package in "${HOST_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null |
        grep -qx installed; then
        missing_packages+=("$package")
    fi
done

TEMP_DIR=$(mktemp -d -t schroot-desktop-install.XXXXXXXX)

render() {
    local source=$1 destination=$2
    [[ $source = /* ]] || source=$REPO_DIR/$source
    sed \
        -e "s|@TARGET_USER@|$TARGET_USER|g" \
        -e "s|@UID@|$TARGET_UID|g" \
        -e "s|@MATE_ROOT@|$MATE_ROOT|g" \
        -e "s|@UNITY_ROOT@|$UNITY_ROOT|g" \
        "$source" >"$destination"
}

declare -a SOURCES DESTINATIONS MODES OWNERS

add_file() {
    SOURCES+=("$1")
    DESTINATIONS+=("$2")
    MODES+=("$3")
    OWNERS+=("$4")
}

file_matches() {
    local source=$1 destination=$2 mode=$3 owner=$4
    local wanted_mode=${mode#0} wanted_uid wanted_gid
    if [[ $owner == root:root ]]; then
        wanted_uid=0
        wanted_gid=0
    else
        wanted_uid=${owner%:*}
        wanted_gid=${owner#*:}
    fi
    [[ -f $destination && ! -L $destination ]] || return 1
    cmp -s "$source" "$destination" || return 1
    [[ $(stat -c %a "$destination") == "$wanted_mode" ]] || return 1
    [[ $(stat -c %u "$destination") == "$wanted_uid" ]] || return 1
    [[ $(stat -c %g "$destination") == "$wanted_gid" ]] || return 1
}

add_file payload/host/usr/local/bin/xenial-mate-session \
    /usr/local/bin/xenial-mate-session 0755 root:root
add_file payload/host/usr/local/bin/xenial-unity-session \
    /usr/local/bin/xenial-unity-session 0755 root:root
add_file payload/host/usr/local/bin/xenial-run \
    /usr/local/bin/xenial-run 0755 root:root
add_file payload/host/usr/local/libexec/maverick-host-launcher \
    /usr/local/libexec/maverick-host-launcher 0755 root:root
add_file payload/host/usr/local/libexec/maverick_unity_menu.py \
    /usr/local/libexec/maverick_unity_menu.py 0644 root:root
add_file payload/host/usr/local/libexec/maverick-unity-menu-bridge \
    /usr/local/libexec/maverick-unity-menu-bridge 0755 root:root
add_file payload/host/usr/local/sbin/maverick-sync-host-apps \
    /usr/local/sbin/maverick-sync-host-apps 0755 root:root
add_file payload/host/etc/systemd/system/maverick-host-app-sync.service \
    /etc/systemd/system/maverick-host-app-sync.service 0644 root:root
add_file payload/host/etc/systemd/system/maverick-host-app-sync.path \
    /etc/systemd/system/maverick-host-app-sync.path 0644 root:root
add_file payload/host/etc/systemd/user/maverick-host-launcher.service \
    /etc/systemd/user/maverick-host-launcher.service 0644 root:root
add_file payload/host/etc/X11/Xsession.d/90custom_maverick-host-services \
    /etc/X11/Xsession.d/90custom_maverick-host-services 0644 root:root
add_file payload/host/usr/share/xsessions/ubuntu-mate-xenial.desktop \
    /usr/share/xsessions/ubuntu-mate-xenial.desktop 0644 root:root
add_file payload/host/usr/share/xsessions/ubuntu-unity-xenial.desktop \
    /usr/share/xsessions/ubuntu-unity-xenial.desktop 0644 root:root
add_file payload/chroot/mate/usr/local/bin/host-run \
    "$MATE_ROOT/usr/local/bin/host-run" 0755 root:root
add_file payload/chroot/mate/usr/local/bin/caja \
    "$MATE_ROOT/usr/local/bin/caja" 0755 root:root
add_file payload/chroot/unity/usr/local/bin/host-run \
    "$UNITY_ROOT/usr/local/bin/host-run" 0755 root:root
add_file config/user/debian-caja-desktop.desktop \
    "$TARGET_HOME/.config/autostart/debian-caja-desktop.desktop" 0664 "$TARGET_UID:$TARGET_GID"

render config/schroot/xenial.conf.in "$TEMP_DIR/xenial.conf"
render config/schroot/xenial-unity.conf.in "$TEMP_DIR/xenial-unity.conf"
render config/schroot/xenial-desktop.fstab.in "$TEMP_DIR/fstab"
add_file "$TEMP_DIR/xenial.conf" /etc/schroot/chroot.d/xenial.conf 0644 root:root
add_file "$TEMP_DIR/xenial-unity.conf" /etc/schroot/chroot.d/xenial-unity.conf 0644 root:root
for profile in xenial-desktop xenial-unity-desktop; do
    add_file "$TEMP_DIR/fstab" "/etc/schroot/$profile/fstab" 0644 root:root
    add_file config/schroot/copyfiles "/etc/schroot/$profile/copyfiles" 0644 root:root
    : >"$TEMP_DIR/nssdatabases"
    add_file "$TEMP_DIR/nssdatabases" "/etc/schroot/$profile/nssdatabases" 0644 root:root
done

differences=0
for index in "${!SOURCES[@]}"; do
    source_path=$REPO_DIR/${SOURCES[$index]}
    [[ ${SOURCES[$index]} = /* ]] && source_path=${SOURCES[$index]}
    destination=${DESTINATIONS[$index]}
    [[ -f $source_path ]] || die "missing repository payload: $source_path"
    if ! file_matches "$source_path" "$destination" \
        "${MODES[$index]}" "${OWNERS[$index]}"; then
        printf 'DIFF  %s\n' "$destination"
        differences=$((differences + 1))
    else
        printf 'OK    %s\n' "$destination"
    fi
done

if ((${#missing_packages[@]})); then
    printf 'MISSING host packages:'
    printf ' %s' "${missing_packages[@]}"
    printf '\n'
    differences=$((differences + 1))
fi

if [[ $COMMAND == check ]]; then
    if ((differences)); then
        note "Check complete: $differences difference(s) found."
        exit 1
    fi
    note "Check complete: installed integration matches the repository."
    exit 0
fi

if [[ $DRY_RUN == true ]]; then
    note "Dry run complete: no changes made."
    exit 0
fi

[[ $EUID == 0 ]] || die "install must be run as root (or use --dry-run)"

if find /var/lib/schroot/session -maxdepth 1 -type f -print -quit 2>/dev/null |
    grep -q .; then
    die "schroot session records exist; log out and repair or end them before installation"
fi

if ((${#missing_packages[@]})); then
    [[ $INSTALL_PACKAGES == true ]] ||
        die "host dependencies are missing; rerun with --install-packages"
    apt-get update
    apt-get install -y "${missing_packages[@]}"
fi

BACKUP_DIR=/var/backups/schroot-desktop/installer-$(date +%Y%m%d-%H%M%S)

for index in "${!SOURCES[@]}"; do
    source_path=$REPO_DIR/${SOURCES[$index]}
    [[ ${SOURCES[$index]} = /* ]] && source_path=${SOURCES[$index]}
    destination=${DESTINATIONS[$index]}
    mode=${MODES[$index]}
    owner=${OWNERS[$index]}
    if file_matches "$source_path" "$destination" "$mode" "$owner"; then
        continue
    fi
    [[ ! -L $destination ]] || die "refusing symbolic-link destination: $destination"
    if [[ -e $destination ]]; then
        backup=$BACKUP_DIR$destination
        mkdir -p -- "${backup%/*}"
        cp -a -- "$destination" "$backup"
        note "BACKUP $destination -> $backup"
    fi
    install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" \
        "$source_path" "$destination"
    note "INSTALL $destination"
done

for root in "$MATE_ROOT" "$UNITY_ROOT"; do
    install -d -m 0755 "$root/host-xdg/applications" \
        "$root/host-xdg/icons" "$root/host-xdg/pixmaps" "$root/host-xdg/themes"
done
install -d -m 0755 /var/lib/maverick-host-apps/applications \
    /var/lib/maverick-host-apps/caja-xdg/applications

systemctl daemon-reload
systemctl enable --now maverick-host-app-sync.path
/usr/local/sbin/maverick-sync-host-apps

note "Installation complete. The host launcher user unit was not enabled permanently."
note "Log in to MATE and Unity separately and run '$PROGRAM check' after validation."
