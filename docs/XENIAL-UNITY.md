# Xenial Unity 7 parallel schroot

This document records the tested Ubuntu Unity 16.04 session that runs alongside the established Xenial MATE root on the same Debian 13 host.

The accepted layout is:

```text
Debian 13 host
├── /srv/xenial        -> Ubuntu MATE 16.04
└── /srv/xenial-unity  -> Ubuntu Unity 16.04
```

The roots are intentionally separate. They share `/home` and the same UID/GID, but their desktop packages and session state remain isolated. The Unity root was bootstrapped fresh rather than copied from the MATE root.

Unity runs directly on the real physical X11 display `:0`. It is not a VM, VNC/RDP session, Xephyr session, nested X server, or remote desktop.

---

# 1. Responsibility split

Debian continues to own:

- kernel, firmware and hardware support
- Mesa, DRM/KMS and Xorg
- LightDM
- NetworkManager
- PipeWire/WirePlumber
- UDisks2 and UPower
- polkitd and the graphical PolicyKit agent
- modern/current applications
- system and security updates

The Unity root owns:

- Unity 7 / Compiz
- `ubuntu-session`
- `unity-settings-daemon`
- `unity-control-center`
- native Xenial Nautilus
- Unity lenses/search components
- Xenial GTK/theme defaults and shell assets
- the native Xenial user-Upstart session used by Unity

Package presence inside Xenial does not imply runtime ownership. Dependencies such as Xenial `upower`, `udisks2`, `pulseaudio`, or BlueZ libraries may be installed because Xenial desktop packages depend on them, while the real runtime services remain Debian-owned.

Do not force the Debian Caja takeover used by the MATE root into Unity. The accepted Unity baseline uses native Xenial Nautilus.

---

# 2. Fresh root and schroot definition

The root was bootstrapped with:

```bash
sudo debootstrap --arch=amd64 xenial /srv/xenial-unity \
  http://archive.ubuntu.com/ubuntu/
```

APT sources:

```text
deb http://archive.ubuntu.com/ubuntu/ xenial main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ xenial-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ xenial-security main restricted universe multiverse
```

The user inside the root must match the Debian account UID/GID and use the shared home directory. The tested account is UID/GID `1000:1000` with home under `/home`.

During package installation, service startup is blocked with `/usr/sbin/policy-rc.d`:

```sh
#!/bin/sh
exit 101
```

Locale:

```text
LANG=en_US.UTF-8
```

Schroot definition:

```ini
[xenial-unity]
description=Ubuntu Unity 16.04 Xenial
type=directory
directory=/srv/xenial-unity
users=nruffell
preserve-environment=true
profile=xenial-unity-desktop
setup.nssdatabases=
```

The `xenial-unity-desktop` profile is intentionally separate from the MATE profile even though its current mounts are the same. This keeps future desktop-specific changes isolated.

Current profile fstab:

```text
/proc   /proc   none   rw,bind    0 0
/sys    /sys    none   rw,rbind   0 0
/dev    /dev    none   rw,rbind   0 0
/home   /home   none   rw,rbind   0 0
/tmp    /tmp    none   rw,bind    0 0
/media  /media  none   rw,rbind,rslave  0 0
/var/lib/maverick-host-apps/applications  /host-xdg/applications  none  ro,bind  0 0
/usr/share/icons                          /host-xdg/icons         none  ro,bind  0 0
/usr/share/pixmaps                        /host-xdg/pixmaps       none  ro,bind  0 0
/run/dbus /run/dbus none rw,bind 0 0
/run/user /run/user none rw,rbind,rslave 0 0
/usr/share/themes /host-xdg/themes none ro,bind 0 0
```

Never recursively bind all of `/run` into this root.

---

# 3. Tested Unity package set

Install the tested shell/integration set:

```bash
sudo chroot /srv/xenial-unity \
  apt-get install -y --no-install-recommends \
    unity \
    ubuntu-session \
    nautilus \
    indicator-appmenu \
    indicator-application \
    indicator-datetime \
    indicator-keyboard \
    indicator-messages \
    indicator-power \
    indicator-session \
    indicator-sound \
    hud \
    session-shortcuts \
    dbus-x11 \
    ubuntu-settings \
    light-themes \
    unity-lens-applications \
    unity-lens-files \
    zeitgeist-core \
    iso-codes \
    unity-control-center \
    python
```

`ubuntu-desktop` was deliberately not used because it pulls a broad Xenial desktop/Xorg payload that the Debian host already owns.

Important tested effects:

- `light-themes` and `ubuntu-settings` restore expected Ubuntu/Unity theming and decoration assets
- Unity lenses + Zeitgeist restore normal Dash application/search content
- `unity-control-center` restores Appearance/Desktop Background integration
- full `python` is required because project `host-run` imports Python 2 `json`; `python-minimal` alone is insufficient

Tested core versions include:

```text
unity                  7.4.5+16.04.20190312-0ubuntu1
compiz                 1:0.9.12.3+16.04.20180221-0ubuntu1
ubuntu-session         3.18.1.2-1ubuntu1.16.04.2
unity-settings-daemon  15.04.1+16.04.20160701-0ubuntu3
unity-control-center   15.04.0+16.04.20171130-0ubuntu1
nautilus               1:3.18.4.is.3.14.3-0ubuntu6
```

---

# 4. Native Unity startup contract

Xenial's native X session is:

```ini
[Desktop Entry]
Name=Ubuntu
Exec=gnome-session --session=ubuntu
TryExec=unity
DesktopNames=Unity
```

Unity/Compiz itself is launched through Xenial user Upstart. The Debian wrapper must therefore enter Xenial through:

```text
/etc/X11/Xsession "gnome-session --session=ubuntu"
```

Directly launching `gnome-session --session=ubuntu` bypasses part of the native startup contract.

The inherited Debian LightDM `PATH` did not include `/sbin`, so the accepted wrapper supplies:

```text
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Unity's Xenial user-Upstart session creates and owns its own session D-Bus. Do not pass Debian's systemd user-bus address into the Xenial Unity session.

---

# 5. Debian Unity session wrapper

Accepted `/usr/local/bin/xenial-unity-session`:

```bash
#!/bin/bash

UID_NUM="$(id -u)"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export DBUS_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket"
export PULSE_SERVER="unix:/run/user/${UID_NUM}/pulse/native"
export ICEAUTHORITY="$HOME/.ICEauthority"

export DESKTOP_SESSION=ubuntu
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CURRENT_DESKTOP=Unity
export GDMSESSION=ubuntu

HOST_DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/${UID_NUM}/bus}"

systemctl --user start maverick-host-launcher.service

cleanup() {
    DBUS_SESSION_BUS_ADDRESS="$HOST_DBUS_SESSION_BUS_ADDRESS" \
        systemctl --user stop maverick-host-launcher.service
}

trap cleanup EXIT HUP INT TERM

unset DBUS_SESSION_BUS_ADDRESS
unset DBUS_SESSION_BUS_PID
unset DBUS_SESSION_BUS_WINDOWID

unset XDG_CONFIG_DIRS
export XDG_DATA_DIRS="/host-xdg:/usr/local/share:/usr/share"

schroot \
  --preserve-environment \
  --directory="$HOME" \
  -c xenial-unity -- \
  /etc/X11/Xsession "gnome-session --session=ubuntu"

STATUS=$?
cleanup
trap - EXIT
exit "$STATUS"
```

In the live Unity session, Xenial Xsession expands the data path to include native Ubuntu/GNOME directories. The Compiz environment confirmed native Unity identity and a Xenial abstract `/tmp/dbus-*` session bus. Direct Intel/Mesa rendering was active with no llvmpipe fallback observed.

---

# 6. LightDM session entry

`/usr/share/xsessions/ubuntu-unity-xenial.desktop`:

```ini
[Desktop Entry]
Name=Ubuntu Unity 16.04
Comment=Ubuntu Unity 16.04 Xenial
Exec=/usr/local/bin/xenial-unity-session
TryExec=/usr/local/bin/xenial-unity-session
Type=Application
DesktopNames=Unity
```

The outer Debian session identity is `ubuntu-unity-xenial`; the wrapper resets the inner Xenial identity to the native `ubuntu` values before entering the root.

---

# 7. Host application bridge

The same generated Debian launcher mirror used by MATE is mounted into Unity at:

```text
/host-xdg/applications
```

Mirrored Host policy:

- unique `debian-` desktop IDs
- `(Host)` appended to main and localized application names
- execution through `/usr/local/bin/host-run`
- desktop-action labels left unchanged
- `BAMF_DESKTOP_FILE_HINT` added for every generated Host `Exec=`
- `StartupWMClass=` removed from every generated `debian-*.desktop`
- current tested mirror forces `StartupNotify=false`

The Unity root carries the same `host-run` client as the MATE root.

## Unity/BAMF launcher matching

The final accepted matching design is **not** based on preserving host `StartupWMClass`.

The duplicate/replacement icon failure was captured directly from BAMF. During a failing Visual Studio Code launch, BAMF created a `Starting=true` Host application object for `debian-code.desktop`, then created a second runtime application when the real X11 window appeared. Unity therefore displayed two launcher objects until the first startup object disappeared.

Two structural problems caused that behavior:

1. The schroot bridge breaks BAMF's normal launch-PID ancestry because Xenial launches `host-run` while the real Debian GUI process is later spawned by the separate host launcher service.
2. Copied Debian `StartupWMClass` values can be absent, stale, or case-mismatched and can cause Xenial BAMF to reject an otherwise-correct explicit Host desktop identity.

Confirmed examples included:

```text
Visual Studio Code:
  StartupWMClass=Code
  live WM_CLASS="code", "code"

GIMP 3:
  StartupWMClass=gimp-3.0
  live WM_CLASS="gimp", "Gimp"
```

### Accepted global bridge flow

Every mirrored Host launch follows the same path:

```text
mirrored debian-*.desktop
        ↓
BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-*.desktop
        ↓
Xenial host-run sends request to Debian launcher
        ↓
Debian launcher creates a stopped launch-gate process
        ↓
launcher returns the real PID
        ↓
Xenial host-run calls:
org.ayatana.bamf.control.RegisterApplicationForPid
        ↓
real PID is registered to the mirrored debian-* desktop file
        ↓
host-run sends SIGCONT
        ↓
gate execs the real Debian application with the same PID
```

The stopped launch gate prevents a race where a fast application could create its first X11 window before BAMF receives the registration. The Debian launcher retains the real child reaper; `SIGCHLD=SIG_IGN` must not be used.

BAMF then applies the registered identity through the process ancestry it understands. Testing confirmed the correct `_BAMF_DESKTOP_FILE` on Visual Studio Code and on privileged GUFW after its helper chain detached.

### Mirrored `StartupWMClass` is removed globally

The synchronizer strips `StartupWMClass=` from the main `[Desktop Entry]` of **every** generated `debian-*.desktop` file. This leaves Debian's real desktop files and all Xenial-native launchers untouched.

The reason is architectural: once the bridge explicitly supplies the authoritative `debian-*` desktop identity and real PID, copied `StartupWMClass` is a weaker heuristic that can veto the correct identity. It is therefore removed from the generated Host view rather than repaired per application.

Do not create per-app WM-class maps, Electron exceptions, launcher hacks, or a downstream BAMF source patch for this problem.

The duplicate/replacement launcher behavior was retested successfully across multiple Host application classes, including Visual Studio Code, GIMP, Firefox ESR, Synaptic, GUFW/Firewall Configuration, and ordinary GTK applications. Future mirrored Host applications inherit the same rules automatically through the existing synchronizer.

The existing `maverick-host-launcher.service` remains session-scoped and must not be permanently enabled.

---

# 8. Storage and graphical PolicyKit

Native Xenial Nautilus/GVfs talks to Debian's UDisks2 through the shared system bus/runtime exposure. USB/removable media works through this path.

Fixed internal volumes may require PolicyKit authentication. The Debian graphical PolicyKit agent runs for the Unity outer session as well as MATE.

Accepted `/etc/X11/Xsession.d/90custom_maverick-host-services`:

```sh
case "$DESKTOP_SESSION" in
    ubuntu-mate-xenial|ubuntu-unity-xenial)
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
            /usr/libexec/polkit-mate-authentication-agent-1 \
            >"$HOME/.cache/xenial-host-polkit.log" 2>&1 &
        ;;
esac

if [ "$DESKTOP_SESSION" = "ubuntu-mate-xenial" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
        /usr/bin/blueman-applet \
        >"$HOME/.cache/xenial-host-blueman.log" 2>&1 &
fi
```

The host polkit-mate agent may log a harmless `org.gnome.SessionManager` warning on Debian's user bus. In the tested Unity session it still presents the password dialog and authorized UDisks2 mounts succeed.

Blueman remains MATE-only until Unity Bluetooth behavior is separately validated.

Do not reintroduce `udiskie`, UDisks1 compatibility hacks, or a Xenial-owned hardware-service stack.

---

# 9. Confirmed working state

The accepted Unity milestone has been tested with:

- Debian LightDM -> **Ubuntu Unity 16.04** login
- Unity 7/Compiz directly on physical X11 `:0`
- correct Ambiance/Ubuntu theme assets
- normal desktop wallpaper and Appearance integration
- populated Unity application/search lenses
- native Xenial Nautilus desktop/file management
- host application discovery through `/host-xdg`
- Debian Host applications launching through the generic bridge
- single-icon Unity launcher association across the tested Host application classes using early BAMF PID registration plus global removal of mirrored `StartupWMClass`
- USB/removable media through Xenial GVfs + Debian UDisks2
- fixed internal volume authentication through Debian polkitd + Debian graphical polkit-mate agent
- mounted fixed volumes visible and browsable in Nautilus
- direct hardware-accelerated Mesa rendering

The MATE root remains independent and unchanged by the Unity desktop package set.

---

# 10. Design constraints retained

- Keep `/srv/xenial` and `/srv/xenial-unity` separate.
- Share `/home`; keep UID/GID identical.
- Do not recursively bind all of `/run`.
- Debian owns hardware-facing services and modern applications.
- Unity owns its classic Xenial shell and native Nautilus/GVfs user experience.
- Use the existing generic Host application mirror and launcher; do not add Unity-specific per-app hacks.
- Every generated `debian-*` mirror uses the authoritative Host/BAMF identity path and removes copied `StartupWMClass`.
- Register the real Debian launch PID with Xenial BAMF before allowing the gated process to exec the application.
- Keep the host launcher session-scoped.
- Do not use `SIGCHLD=SIG_IGN`; keep the real child reaper.
- Do not force Debian Caja desktop ownership into Unity unless a demonstrated problem justifies it.
- Do not treat package presence inside Xenial as service ownership.
- Record only tested fixes in canonical documentation.
