#!/bin/bash
set -euo pipefail

PROGRAM=${0##*/}
REPO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
COMMAND=check
DESKTOP=both
TARGET_USER=${SUDO_USER:-${USER:-}}
MATE_ROOT=/srv/xenial
UNITY_ROOT=/srv/xenial-unity
MIRROR=http://archive.ubuntu.com/ubuntu/
DRY_RUN=false
INSTALL_PACKAGES=false
FORCE_RESET_CHROOT_PASSWORD=false
BACKUP_DIR=
TEMP_DIR=
CHROOT_PASSWORD=
CHROOT_PASSWORD_READY=false

HOST_COMMON_PACKAGES=()
HOST_MATE_PACKAGES=()
HOST_UNITY_PACKAGES=()
HOST_PACKAGES=()
COMMON_PACKAGES=()
MATE_PACKAGES=()
UNITY_PACKAGES=()

read_packages() {
    local manifest=$1 array_name=$2 line
    local -n destination=$array_name
    [[ -r $manifest ]] || die "package manifest is missing: $manifest"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        read -r line <<<"$line"
        [[ -n $line ]] && destination+=("$line")
    done <"$manifest"
}

usage() {
    cat <<EOF
Usage: $PROGRAM [check|install|update] [OPTIONS]

Install the documented Schroot Desktop integration into existing Xenial roots.
This installer does not bootstrap the Xenial root filesystems.

Options:
  --target-user USER       Desktop account (default: SUDO_USER/current user)
  --desktop CHOICE         mate, unity, or both (default: both)
  --mate-root PATH         Existing MATE root (default: /srv/xenial)
  --unity-root PATH        Existing Unity root (default: /srv/xenial-unity)
  --mirror URL             Xenial archive mirror
  --dry-run                Show install actions without changing the system
  --install-packages       Install missing host and chroot packages with APT
  --reset-chroot-password  Prompt for and replace the selected roots' password
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
        update)
            COMMAND=install
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
        --dry-run)
            DRY_RUN=true
            ;;
        --install-packages)
            INSTALL_PACKAGES=true
            ;;
        --reset-chroot-password)
            FORCE_RESET_CHROOT_PASSWORD=true
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
[[ $MATE_ROOT = /* && $MATE_ROOT != / ]] || die "invalid MATE root: $MATE_ROOT"
[[ $UNITY_ROOT = /* && $UNITY_ROOT != / ]] || die "invalid Unity root: $UNITY_ROOT"
[[ $MATE_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die "unsupported MATE root path"
[[ $UNITY_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die "unsupported Unity root path"
[[ $MATE_ROOT != "$UNITY_ROOT" ]] || die "MATE and Unity roots must be different"
[[ $MIRROR =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || die "unsupported mirror URL"

read_packages "$REPO_DIR/packages/host-common.txt" HOST_COMMON_PACKAGES
read_packages "$REPO_DIR/packages/host-mate.txt" HOST_MATE_PACKAGES
read_packages "$REPO_DIR/packages/host-unity.txt" HOST_UNITY_PACKAGES
read_packages "$REPO_DIR/packages/chroot-common.txt" COMMON_PACKAGES
read_packages "$REPO_DIR/packages/mate-core.txt" MATE_PACKAGES
read_packages "$REPO_DIR/packages/unity-core.txt" UNITY_PACKAGES
read_packages "$REPO_DIR/packages/unity-essentials.txt" UNITY_PACKAGES
HOST_PACKAGES=("${HOST_COMMON_PACKAGES[@]}")
if [[ $WANT_MATE == true ]]; then
    HOST_PACKAGES+=("${HOST_MATE_PACKAGES[@]}")
fi
if [[ $WANT_UNITY == true ]]; then
    HOST_PACKAGES+=("${HOST_UNITY_PACKAGES[@]}")
fi

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
    local label=$1 root=$2 missing_name=$3 root_user
    local -n account_missing=$missing_name
    [[ -d $root ]] || die "$label root does not exist: $root"
    [[ -r $root/etc/os-release ]] || die "$label root has no /etc/os-release"
    (
        # shellcheck disable=SC1090
        . "$root/etc/os-release"
        [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 16.04 ]]
    ) || die "$label root is not Ubuntu 16.04: $root"
    root_user=$(awk -F: -v user="$TARGET_USER" '$1 == user {print $3 ":" $4}' "$root/etc/passwd")
    if [[ -z $root_user ]]; then
        account_missing=true
        return
    fi
    [[ $root_user == "$TARGET_UID:$TARGET_GID" ]] ||
        die "$TARGET_USER must be UID:GID $TARGET_UID:$TARGET_GID in $label root"
}

MATE_ACCOUNT_MISSING=false
UNITY_ACCOUNT_MISSING=false
[[ $WANT_MATE == false ]] || validate_root MATE "$MATE_ROOT" MATE_ACCOUNT_MISSING
[[ $WANT_UNITY == false ]] || validate_root Unity "$UNITY_ROOT" UNITY_ACCOUNT_MISSING

missing_packages=()
for package in "${HOST_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null |
        grep -qx installed; then
        missing_packages+=("$package")
    fi
done

missing_root_packages() {
    local root=$1 output_name=$2 package
    shift 2
    local -n output=$output_name
    for package in "$@"; do
        if ! dpkg-query --admindir="$root/var/lib/dpkg" \
            -W -f='${db:Status-Status}' "$package" 2>/dev/null |
            grep -qx installed; then
            output+=("$package")
        fi
    done
}

MATE_MISSING=()
UNITY_MISSING=()
if [[ $WANT_MATE == true ]]; then
    missing_root_packages "$MATE_ROOT" MATE_MISSING \
        "${COMMON_PACKAGES[@]}" "${MATE_PACKAGES[@]}"
fi

MATE_ADMIN_MISSING=false
UNITY_ADMIN_MISSING=false
MATE_AUTH_MISSING=false
UNITY_AUTH_MISSING=false
MATE_AUTOSTART_MISSING=()
UNITY_AUTOSTART_MISSING=()
HOST_SYNC_DISABLED=false
HOST_SYNAPTIC_MIRROR_MISSING=false
PERMANENT_LAUNCHER_LINKS=()
root_user_is_admin() {
    local root=$1 user_gid sudo_gid members
    user_gid=$(awk -F: -v user="$TARGET_USER" \
        '$1 == user {print $4}' "$root/etc/passwd")
    IFS=: read -r _ _ sudo_gid members < <(
        awk -F: '$1 == "sudo" {print; exit}' "$root/etc/group"
    )
    [[ -n ${sudo_gid:-} ]] || return 1
    [[ $user_gid == "$sudo_gid" ]] && return 0
    [[ ,${members:-}, == *,"$TARGET_USER",* ]]
}
if [[ $WANT_MATE == true && $MATE_ACCOUNT_MISSING == false ]] &&
    ! root_user_is_admin "$MATE_ROOT"; then
    MATE_ADMIN_MISSING=true
fi
if [[ $WANT_UNITY == true && $UNITY_ACCOUNT_MISSING == false ]] &&
    ! root_user_is_admin "$UNITY_ROOT"; then
    UNITY_ADMIN_MISSING=true
fi
root_password_needs_reset() {
    local root=$1 password_field
    password_field=$(awk -F: -v user="$TARGET_USER" \
        '$1 == user {print $2}' "$root/etc/shadow")
    case $password_field in
        ''|'!'*|'*'*|'$y$'*|'$gy$'*) return 0 ;;
        *) return 1 ;;
    esac
}
if ((EUID == 0)) && [[ $WANT_MATE == true && $MATE_ACCOUNT_MISSING == false ]] &&
    root_password_needs_reset "$MATE_ROOT"; then
    MATE_AUTH_MISSING=true
fi
if ((EUID == 0)) && [[ $WANT_UNITY == true && $UNITY_ACCOUNT_MISSING == false ]] &&
    root_password_needs_reset "$UNITY_ROOT"; then
    UNITY_AUTH_MISSING=true
fi
if [[ $WANT_MATE == true ]]; then
    for path in update-notifier.desktop blueman.desktop \
        polkit-mate-authentication-agent-1.desktop; do
        [[ ! -e $MATE_ROOT/etc/xdg/autostart/$path ]] ||
            MATE_AUTOSTART_MISSING+=("$path")
    done
fi
if [[ $WANT_UNITY == true && \
    -e $UNITY_ROOT/etc/xdg/autostart/update-notifier.desktop ]]; then
    UNITY_AUTOSTART_MISSING+=(update-notifier.desktop)
fi
if [[ $WANT_UNITY == true && \
    -e $UNITY_ROOT/etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop ]]; then
    UNITY_AUTOSTART_MISSING+=(polkit-gnome-authentication-agent-1.desktop)
fi
if [[ $WANT_UNITY == true ]]; then
    missing_root_packages "$UNITY_ROOT" UNITY_MISSING \
        "${COMMON_PACKAGES[@]}" "${UNITY_PACKAGES[@]}"
fi
if ! systemctl is-enabled --quiet maverick-host-app-sync.path 2>/dev/null; then
    HOST_SYNC_DISABLED=true
fi
if dpkg-query -W -f='${db:Status-Status}' synaptic 2>/dev/null |
    grep -qx installed; then
    [[ -f /var/lib/maverick-host-apps/applications/debian-synaptic.desktop ]] ||
        HOST_SYNAPTIC_MIRROR_MISSING=true
fi
for link in \
    /etc/systemd/user/default.target.wants/maverick-host-launcher.service \
    "$TARGET_HOME/.config/systemd/user/default.target.wants/maverick-host-launcher.service"; do
    [[ ! -e $link && ! -L $link ]] || PERMANENT_LAUNCHER_LINKS+=("$link")
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
        -e "s|@MIRROR@|$MIRROR|g" \
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

add_file payload/host/usr/local/libexec/maverick-host-launcher \
    /usr/local/libexec/maverick-host-launcher 0755 root:root
add_file payload/host/etc/systemd/system/maverick-host-app-sync.service \
    /etc/systemd/system/maverick-host-app-sync.service 0644 root:root
add_file payload/host/etc/systemd/system/maverick-host-app-sync.path \
    /etc/systemd/system/maverick-host-app-sync.path 0644 root:root
add_file payload/host/etc/systemd/user/maverick-host-launcher.service \
    /etc/systemd/user/maverick-host-launcher.service 0644 root:root
add_file payload/host/etc/X11/Xsession.d/90custom_maverick-host-services \
    /etc/X11/Xsession.d/90custom_maverick-host-services 0644 root:root

render config/schroot/xenial.conf.in "$TEMP_DIR/xenial.conf"
render config/schroot/xenial-unity.conf.in "$TEMP_DIR/xenial-unity.conf"
render config/schroot/xenial-desktop.fstab.in "$TEMP_DIR/fstab"
render config/chroot/xenial-sources.list.in "$TEMP_DIR/xenial-sources.list"
render payload/host/usr/local/sbin/maverick-sync-host-apps \
    "$TEMP_DIR/maverick-sync-host-apps"
add_file "$TEMP_DIR/maverick-sync-host-apps" \
    /usr/local/sbin/maverick-sync-host-apps 0755 root:root
: >"$TEMP_DIR/nssdatabases"

if [[ $WANT_MATE == true ]]; then
    add_file payload/host/usr/local/bin/xenial-mate-session \
        /usr/local/bin/xenial-mate-session 0755 root:root
    add_file payload/host/usr/local/bin/xenial-run \
        /usr/local/bin/xenial-run 0755 root:root
    add_file payload/host/usr/share/xsessions/ubuntu-mate-xenial.desktop \
        /usr/share/xsessions/ubuntu-mate-xenial.desktop 0644 root:root
    add_file payload/chroot/mate/usr/local/bin/host-run \
        "$MATE_ROOT/usr/local/bin/host-run" 0755 root:root
    add_file payload/chroot/mate/usr/local/bin/caja \
        "$MATE_ROOT/usr/local/bin/caja" 0755 root:root
    add_file config/chroot/mate/99-schroot-desktop.gschema.override \
        "$MATE_ROOT/usr/share/glib-2.0/schemas/99-schroot-desktop.gschema.override" \
        0644 root:root
    add_file config/chroot/policy-rc.d \
        "$MATE_ROOT/usr/sbin/policy-rc.d" 0755 root:root
    add_file config/user/debian-caja-desktop.desktop \
        "$TARGET_HOME/.config/autostart/debian-caja-desktop.desktop" 0664 "$TARGET_UID:$TARGET_GID"
    add_file "$TEMP_DIR/xenial.conf" /etc/schroot/chroot.d/xenial.conf 0644 root:root
    add_file "$TEMP_DIR/fstab" /etc/schroot/xenial-desktop/fstab 0644 root:root
    add_file config/schroot/copyfiles /etc/schroot/xenial-desktop/copyfiles 0644 root:root
    add_file "$TEMP_DIR/nssdatabases" /etc/schroot/xenial-desktop/nssdatabases 0644 root:root
    add_file "$TEMP_DIR/xenial-sources.list" \
        "$MATE_ROOT/etc/apt/sources.list.d/schroot-desktop.list" 0644 root:root
fi

if [[ $WANT_UNITY == true ]]; then
    add_file payload/host/usr/local/bin/xenial-unity-session \
        /usr/local/bin/xenial-unity-session 0755 root:root
    add_file payload/host/usr/local/libexec/maverick_unity_menu.py \
        /usr/local/libexec/maverick_unity_menu.py 0644 root:root
    add_file payload/host/usr/local/libexec/maverick-unity-menu-bridge \
        /usr/local/libexec/maverick-unity-menu-bridge 0755 root:root
    add_file payload/host/usr/share/xsessions/ubuntu-unity-xenial.desktop \
        /usr/share/xsessions/ubuntu-unity-xenial.desktop 0644 root:root
    add_file payload/chroot/unity/usr/local/bin/host-run \
        "$UNITY_ROOT/usr/local/bin/host-run" 0755 root:root
    add_file config/chroot/policy-rc.d \
        "$UNITY_ROOT/usr/sbin/policy-rc.d" 0755 root:root
    add_file "$TEMP_DIR/xenial-unity.conf" \
        /etc/schroot/chroot.d/xenial-unity.conf 0644 root:root
    add_file "$TEMP_DIR/fstab" /etc/schroot/xenial-unity-desktop/fstab 0644 root:root
    add_file config/schroot/copyfiles /etc/schroot/xenial-unity-desktop/copyfiles 0644 root:root
    add_file "$TEMP_DIR/nssdatabases" /etc/schroot/xenial-unity-desktop/nssdatabases 0644 root:root
    add_file "$TEMP_DIR/xenial-sources.list" \
        "$UNITY_ROOT/etc/apt/sources.list.d/schroot-desktop.list" 0644 root:root
fi

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
if ((${#MATE_MISSING[@]})); then
    printf 'MISSING MATE packages:'
    printf ' %s' "${MATE_MISSING[@]}"
    printf '\n'
    differences=$((differences + 1))
fi
if ((${#UNITY_MISSING[@]})); then
    printf 'MISSING Unity packages:'
    printf ' %s' "${UNITY_MISSING[@]}"
    printf '\n'
    differences=$((differences + 1))
fi
if [[ $MATE_ADMIN_MISSING == true ]]; then
    printf 'MISSING MATE admin membership: %s is not in sudo\n' "$TARGET_USER"
    differences=$((differences + 1))
fi
if [[ $UNITY_ADMIN_MISSING == true ]]; then
    printf 'MISSING Unity admin membership: %s is not in sudo\n' "$TARGET_USER"
    differences=$((differences + 1))
fi
if [[ $MATE_ACCOUNT_MISSING == true ]]; then
    printf 'MISSING MATE account: %s\n' "$TARGET_USER"
    differences=$((differences + 1))
fi
if [[ $UNITY_ACCOUNT_MISSING == true ]]; then
    printf 'MISSING Unity account: %s\n' "$TARGET_USER"
    differences=$((differences + 1))
fi
if [[ $MATE_AUTH_MISSING == true ]]; then
    printf 'MISSING MATE password: account is locked or incompatible\n'
    differences=$((differences + 1))
fi
if [[ $UNITY_AUTH_MISSING == true ]]; then
    printf 'MISSING Unity password: account is locked or incompatible\n'
    differences=$((differences + 1))
fi
if ((${#MATE_AUTOSTART_MISSING[@]})); then
    printf 'ACTIVE conflicting MATE autostarts:'
    printf ' %s' "${MATE_AUTOSTART_MISSING[@]}"
    printf '\n'
    differences=$((differences + 1))
fi
if ((${#UNITY_AUTOSTART_MISSING[@]})); then
    printf 'ACTIVE conflicting Unity autostarts:'
    printf ' %s' "${UNITY_AUTOSTART_MISSING[@]}"
    printf '\n'
    differences=$((differences + 1))
fi
if [[ $HOST_SYNC_DISABLED == true ]]; then
    printf 'DISABLED host application synchronization path unit\n'
    differences=$((differences + 1))
fi
if [[ $HOST_SYNAPTIC_MIRROR_MISSING == true ]]; then
    printf 'MISSING Synaptic Host launcher mirror\n'
    differences=$((differences + 1))
fi
if ((${#PERMANENT_LAUNCHER_LINKS[@]})); then
    printf 'ACTIVE permanently enabled host launcher:'
    printf ' %s' "${PERMANENT_LAUNCHER_LINKS[@]}"
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

if ((${#missing_packages[@]} || ${#MATE_MISSING[@]} || ${#UNITY_MISSING[@]})); then
    [[ $INSTALL_PACKAGES == true ]] ||
        die "package dependencies are missing; rerun with --install-packages"
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

if ((${#missing_packages[@]})); then
    apt-get update
    apt-get install -y "${missing_packages[@]}"
fi
if ((${#MATE_MISSING[@]})); then
    /usr/sbin/chroot "$MATE_ROOT" apt-get \
        -o Dir::Etc::sourcelist=sources.list.d/schroot-desktop.list \
        -o Dir::Etc::sourceparts=- update
    /usr/sbin/chroot "$MATE_ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get -o Dir::Etc::sourcelist=sources.list.d/schroot-desktop.list \
        -o Dir::Etc::sourceparts=- install -y --install-recommends \
        "${MATE_MISSING[@]}"
fi
if ((${#UNITY_MISSING[@]})); then
    /usr/sbin/chroot "$UNITY_ROOT" apt-get \
        -o Dir::Etc::sourcelist=sources.list.d/schroot-desktop.list \
        -o Dir::Etc::sourceparts=- update
    /usr/sbin/chroot "$UNITY_ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get -o Dir::Etc::sourcelist=sources.list.d/schroot-desktop.list \
        -o Dir::Etc::sourceparts=- install -y --install-recommends \
        "${UNITY_MISSING[@]}"
fi

normalize_root() {
    local root=$1 desktop=$2 path
    local paths=(/etc/xdg/autostart/update-notifier.desktop)
    if [[ $desktop == mate ]]; then
        paths+=(
            /etc/xdg/autostart/blueman.desktop
            /etc/xdg/autostart/polkit-mate-authentication-agent-1.desktop
        )
    else
        paths+=(/etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop)
    fi
    for path in "${paths[@]}"; do
        if [[ -e $root$path ]] &&
            ! /usr/sbin/chroot "$root" dpkg-divert --list "$path" |
                grep -q .; then
            /usr/sbin/chroot "$root" dpkg-divert --local --rename --add "$path"
        fi
    done
}
if [[ $WANT_MATE == true ]]; then
    normalize_root "$MATE_ROOT" mate
fi
if [[ $WANT_UNITY == true ]]; then
    normalize_root "$UNITY_ROOT" unity
fi

read_chroot_password() {
    local first second
    [[ -t 0 ]] ||
        die "a terminal is required to set the Xenial administrative password"
    while true; do
        read -r -s -p "Set Xenial sudo password for $TARGET_USER: " first
        printf '\n'
        [[ -n $first ]] || {
            echo "Password must not be empty." >&2
            continue
        }
        read -r -s -p "Confirm Xenial sudo password: " second
        printf '\n'
        [[ $first == "$second" ]] || {
            echo "Passwords do not match; try again." >&2
            continue
        }
        CHROOT_PASSWORD=$first
        CHROOT_PASSWORD_READY=true
        return
    done
}

ensure_root_account() {
    local root=$1 group_name root_user
    root_user=$(awk -F: -v user="$TARGET_USER" \
        '$1 == user {print $3 ":" $4}' "$root/etc/passwd")
    [[ -z $root_user ]] || return
    group_name=$(awk -F: -v gid="$TARGET_GID" \
        '$3 == gid {print $1; exit}' "$root/etc/group")
    if [[ -z $group_name ]]; then
        /usr/sbin/chroot "$root" groupadd --gid "$TARGET_GID" "$TARGET_USER"
    fi
    /usr/sbin/chroot "$root" useradd --no-create-home --uid "$TARGET_UID" \
        --gid "$TARGET_GID" --home-dir "$TARGET_HOME" \
        --shell /bin/bash "$TARGET_USER"
}

configure_admin_account() {
    local root=$1 password_field needs_password=$FORCE_RESET_CHROOT_PASSWORD
    /usr/sbin/chroot "$root" usermod --append --groups sudo "$TARGET_USER"
    password_field=$(awk -F: -v user="$TARGET_USER" \
        '$1 == user {print $2}' "$root/etc/shadow")
    case $password_field in
        ''|'!'*|'*'*|'$y$'*|'$gy$'*) needs_password=true ;;
    esac
    if [[ $needs_password == true ]]; then
        [[ $CHROOT_PASSWORD_READY == true ]] || read_chroot_password
        printf '%s:%s\n' "$TARGET_USER" "$CHROOT_PASSWORD" |
            /usr/sbin/chroot "$root" chpasswd
    fi
}

if [[ $WANT_MATE == true ]]; then
    ensure_root_account "$MATE_ROOT"
    configure_admin_account "$MATE_ROOT"
fi
if [[ $WANT_UNITY == true ]]; then
    ensure_root_account "$UNITY_ROOT"
    configure_admin_account "$UNITY_ROOT"
fi
CHROOT_PASSWORD=
CHROOT_PASSWORD_READY=false

if [[ $WANT_MATE == true ]]; then
    /usr/sbin/chroot "$MATE_ROOT" \
        glib-compile-schemas /usr/share/glib-2.0/schemas
fi

SELECTED_ROOTS=()
if [[ $WANT_MATE == true ]]; then
    SELECTED_ROOTS+=("$MATE_ROOT")
fi
if [[ $WANT_UNITY == true ]]; then
    SELECTED_ROOTS+=("$UNITY_ROOT")
fi
for root in "${SELECTED_ROOTS[@]}"; do
    install -d -m 0755 "$root/host-xdg/applications" \
        "$root/host-xdg/icons" "$root/host-xdg/pixmaps" "$root/host-xdg/themes"
done
install -d -m 0755 /var/lib/maverick-host-apps/applications \
    /var/lib/maverick-host-apps/caja-xdg/applications

for link in "${PERMANENT_LAUNCHER_LINKS[@]}"; do
    [[ -L $link ]] || die "refusing non-symlink launcher enablement: $link"
    unlink -- "$link"
    note "DISABLE permanent host launcher $link"
done

systemctl daemon-reload
systemctl enable --now maverick-host-app-sync.path
/usr/local/sbin/maverick-sync-host-apps

note "Installation complete. The host launcher user unit was not enabled permanently."
note "Log in to the selected desktop(s) and run '$PROGRAM check --desktop $DESKTOP' after validation."
