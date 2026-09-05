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

A minimal `unity` install was not sufficient for a normal desktop. The tested shell requires the Ubuntu defaults, themes, lenses and settings integration as well as the core session packages.

Install:

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

`ubuntu-desktop` was deliberately not used because even with `--no-install-recommends` it pulls a broad Xenial desktop/Xorg payload that the Debian host already owns.

Important omissions discovered during testing:

- without `light-themes` and `ubuntu-settings`, Unity fell back to Adwaita and Compiz logged missing decoration assets; the result included severe visual corruption/ghosting
- without `unity-lens-applications`, `unity-lens-files` and `zeitgeist-core`, the Dash application/search experience was incomplete
- without `unity-control-center`, the desktop context menu lacked the normal **Change Desktop Background** action and Appearance integration
- `python-minimal` alone is not sufficient for the project `host-run` client; it lacks the Python 2 standard library `json` module. Install the normal `python` package

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

The corresponding GNOME session requires `unity-settings-daemon`, but Unity/Compiz itself is launched through Xenial **user Upstart**. `unity7.conf` starts Compiz on the native `xsession SESSION=ubuntu` event.

For that reason the Debian wrapper must enter Xenial through `/etc/X11/Xsession`. Directly launching `gnome-session --session=ubuntu` bypasses part of the native startup contract.

The inherited Debian LightDM `PATH` did not include `/sbin`, which caused Xenial Upstart jobs to fail to find `initctl` and `upstart-udev-bridge`. The wrapper therefore supplies a complete system path.

Unity's Xenial user-Upstart session also creates and owns its own session D-Bus. Do not pass Debian's systemd user-bus address into the Xenial Unity session.

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

# Reproduce the identity of Xenial's native Ubuntu Unity session.
export DESKTOP_SESSION=ubuntu
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CURRENT_DESKTOP=Unity
export GDMSESSION=ubuntu

# Start the existing Debian host-application bridge for this login only.
HOST_DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/${UID_NUM}/bus}"

systemctl --user start maverick-host-launcher.service

cleanup() {
    DBUS_SESSION_BUS_ADDRESS="$HOST_DBUS_SESSION_BUS_ADDRESS" \
        systemctl --user stop maverick-host-launcher.service
}

trap cleanup EXIT HUP INT TERM

# Unity's Xenial user-Upstart session creates and owns its own session D-Bus.
unset DBUS_SESSION_BUS_ADDRESS
unset DBUS_SESSION_BUS_PID
unset DBUS_SESSION_BUS_WINDOWID

# Let Xenial Xsession add its native Ubuntu/GNOME directories around this
# base path while also exposing mirrored Debian applications and resources.
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

In the running Unity session, the native Xsession/Upstart path expanded the tested data path to:

```text
XDG_DATA_DIRS=/usr/share/ubuntu:/usr/share/gnome:/host-xdg:/usr/local/share:/usr/share
```

The live Compiz environment also confirmed:

```text
DESKTOP_SESSION=ubuntu
XDG_CURRENT_DESKTOP=Unity
DBUS_SESSION_BUS_ADDRESS=unix:abstract=/tmp/dbus-...
```

Direct rendering was active with the Debian Intel/Mesa stack; no llvmpipe fallback was observed.

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

The outer Debian session identity is `ubuntu-unity-xenial`; the wrapper resets the **inner Xenial** identity to the native `ubuntu` values before entering the root.

---

# 7. Host application bridge

The same generated Debian launcher mirror used by MATE is mounted into Unity at:

```text
/host-xdg/applications
```

Mirrored host applications keep the normal project policy:

- unique `debian-` desktop IDs
- `(Host)` appended to main and localized application names
- execution through `/usr/local/bin/host-run`
- desktop-action labels left unchanged

The tested Unity root currently carries the same `host-run` client as the MATE root:

```bash
sudo install -m 0755 \
  /srv/xenial/usr/local/bin/host-run \
  /srv/xenial-unity/usr/local/bin/host-run
```

The client uses `#!/usr/bin/python` and imports `json`, so the complete Xenial `python` package is part of the accepted Unity integration. `python-minimal` alone caused:

```text
ImportError: No module named json
```

After installing `python`, a direct bridge test returned success and Debian GUI applications launched normally from the Unity session.

## Unity/BAMF launcher matching

Unity uses BAMF to associate running application windows with their launchers. Mirrored host applications intentionally use unique `debian-*` desktop IDs, so the source desktop ID is not preserved.

Testing established this generic rule:

```text
source launcher has StartupWMClass
    -> preserve it; normal BAMF matching works

source launcher lacks StartupWMClass
    -> prepend BAMF_DESKTOP_FILE_HINT for the mirrored debian-* desktop file
```

For the no-`StartupWMClass` case, the generated command uses the path visible inside Xenial:

```text
BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-<original>.desktop
```

Example:

```ini
Exec=/usr/bin/env BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-org.deskflow.deskflow.desktop /usr/local/bin/host-run deskflow
```

Both Xenial `host-run` clients and `/usr/local/libexec/maverick-host-launcher` must include `BAMF_DESKTOP_FILE_HINT` in their environment allow-lists so the value reaches the real Debian process.

The test case confirmed the value in the host process environment and eliminated the duplicate/transient Unity launcher behavior for previously affected host applications. Firefox ESR and Synaptic, which already supply `StartupWMClass`, remain unchanged and continue to match through their native metadata.

Do not build per-application `StartupWMClass` tables or launcher hacks. This is a conditional rule in the existing generic synchronizer and is inherited automatically by future mirrored host apps.

The existing `maverick-host-launcher.service` remains session-scoped and is started/stopped by the Unity wrapper. Do not permanently enable it.

---

# 8. Storage and graphical PolicyKit

Native Xenial Nautilus/GVfs talks to Debian's UDisks2 through the shared system bus/runtime exposure. USB/removable media works through this path.

Fixed internal volumes may require PolicyKit authentication. The Debian graphical PolicyKit agent must therefore run for the Unity outer session as well as MATE.

Accepted `/etc/X11/Xsession.d/90custom_maverick-host-services`:

```sh
# Debian-side helpers for legacy Xenial desktop sessions.

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

The host polkit-mate agent may log a warning that `org.gnome.SessionManager` is unavailable on Debian's user bus. In the tested Unity session this warning is harmless: the agent still presents the password dialog, Debian UDisks2 mounts the fixed volume, and the mounted filesystem is browsable in Xenial Nautilus.

Blueman remains MATE-only in this hook because Unity Bluetooth integration has not yet been separately validated.

Do not reintroduce `udiskie`, UDisks1 compatibility hacks, or a Xenial-owned hardware service stack.

---

# 9. Confirmed working state

The accepted Unity milestone has been tested with:

- Debian LightDM -> **Ubuntu Unity 16.04** login
- Unity 7/Compiz directly on physical X11 `:0`
- correct Ambiance/Ubuntu theme assets
- normal desktop wallpaper and Appearance integration
- no observed Compiz ghosting after the complete theme/default package set was installed
- native Xenial Nautilus desktop/file management
- populated Unity application/search lenses
- host application discovery through `/host-xdg`
- Debian host applications launching through the existing `host-run` bridge
- correct single-icon Unity launcher association for mirrored host applications, including the generic BAMF hint path for source launchers without `StartupWMClass`
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
- Use the existing generic host-application mirror and launcher; do not add Unity-specific per-app hacks.
- Preserve source `StartupWMClass` when present; use the generic BAMF desktop-file hint only for mirrored host launchers that lack it.
- Do not force Debian Caja desktop ownership into Unity unless a future demonstrated problem justifies it.
- Keep the host launcher session-scoped.
- Do not treat package presence inside Xenial as service ownership.
- Record only tested fixes in the canonical documentation.
