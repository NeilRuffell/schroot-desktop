# Debian 13 Host + Ubuntu MATE 16.04 Xenial Hybrid Desktop
## Current canonical handoff / replication checkpoint

This document records the accepted architecture and fixes for **Schroot Desktop**.

The project runs an Ubuntu MATE 16.04 Xenial desktop userspace directly on the physical X11 display while Debian 13 remains the real operating system underneath.

The original Ubuntu 10.10 Maverick/GNOME 2 prototype proved the concept, but Maverick's UDisks1-era storage stack created unnecessary compatibility problems with a modern Debian host. Xenial was selected because it preserves the classic GTK2/GNOME-2-derived desktop model while using UDisks2-era userspace.

Failed experiments and temporary troubleshooting steps are deliberately omitted.

---

# 1. Architecture

```text
Debian 13 host
├── kernel
├── hardware drivers / firmware
├── Mesa / DRM / KMS
├── Xorg
├── LightDM
├── NetworkManager
├── PipeWire / WirePlumber
├── UDisks2
├── UPower
├── polkitd
├── current Debian applications
├── security updates
│
└── physical X11 display :0
       ↓
   schroot /srv/xenial
       ↓
Ubuntu MATE 16.04 Xenial
├── MATE 1.12
├── mate-panel
├── Caja 1.12
├── Marco 1.12
├── mate-session
├── mate-settings-daemon
├── GVfs 1.28
└── classic GTK2 desktop
```

This is not a VM, VNC/RDP session, Xephyr session, nested X server, or recreation of an old desktop theme. Xenial MATE itself owns the physical desktop session.

## Responsibility split

Debian owns:

- kernel and hardware support
- graphics stack
- Xorg and LightDM
- networking backend
- audio backend
- UDisks2 and UPower
- PolicyKit backend
- current applications
- security/system updates

Xenial owns:

- MATE session
- mate-panel
- Caja
- Marco
- classic desktop settings
- native Xenial GVfs client stack
- classic GTK2 desktop appearance

Do not run duplicate old hardware-management daemons inside Xenial unless specifically proven necessary.

---

# 2. Debian host packages

Core host packages used by the reference build:

```bash
sudo apt update
sudo apt install \
  xserver-xorg-core \
  xserver-xorg-input-libinput \
  x11-xserver-utils \
  xauth \
  xinit \
  mesa-utils \
  libgl1-mesa-dri \
  network-manager \
  pipewire \
  pipewire-pulse \
  wireplumber \
  udisks2 \
  upower \
  polkitd \
  dbus-x11 \
  curl \
  wget \
  ca-certificates \
  debootstrap \
  schroot \
  lightdm \
  lightdm-gtk-greeter
```

Graphical PolicyKit agent:

```bash
sudo apt install --no-install-recommends mate-polkit
```

Bluetooth UI when required:

```bash
sudo apt install --no-install-recommends blueman
```

Hardware-specific firmware/microcode belongs on Debian. The reference iMac18,1 uses Intel graphics and Broadcom Wi-Fi; do not copy its firmware package choices blindly to unrelated machines.

---

# 3. Bootstrap Xenial

```bash
sudo debootstrap --arch=amd64 xenial /srv/xenial http://archive.ubuntu.com/ubuntu/
```

`/srv/xenial/etc/apt/sources.list`:

```text
deb http://archive.ubuntu.com/ubuntu/ xenial main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ xenial-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ xenial-security main restricted universe multiverse
```

Keep Xenial `/etc/resolv.conf` as a real file rather than the old `/run/resolvconf/...` symlink:

```bash
sudo rm -f /srv/xenial/etc/resolv.conf
sudo cp -L /etc/resolv.conf /srv/xenial/etc/resolv.conf
sudo chmod 644 /srv/xenial/etc/resolv.conf
```

Prevent old daemons starting during package installation:

```bash
sudo tee /srv/xenial/usr/sbin/policy-rc.d >/dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
sudo chmod 755 /srv/xenial/usr/sbin/policy-rc.d
```

Install the complete desktop:

```bash
sudo chroot /srv/xenial apt-get update
sudo chroot /srv/xenial apt-get install ubuntu-mate-desktop
sudo chroot /srv/xenial dpkg --configure -a
sudo chroot /srv/xenial apt-get -f install
sudo chroot /srv/xenial dpkg --configure -a
```

Generate locale data:

```bash
sudo chroot /srv/xenial locale-gen en_US.UTF-8
sudo chroot /srv/xenial update-locale LANG=en_US.UTF-8
```

The Xenial user must have the same UID/GID as the Debian host user because `/home` is shared.

---

# 4. Critical schroot mount design

The most important mount rule discovered during testing is:

> **Never recursively bind the whole host `/run` into the Xenial schroot.**

The old configuration:

```text
/run /run none rw,rbind 0 0
```

was wrong for this design because schroot itself stores session mount trees below `/run/schroot/mount/`. Recursively binding all of `/run` pulled those mount trees back inside the chroot and caused:

- stale schroot sessions
- `Device or resource busy` during teardown
- `findmnt` hangs
- `systemd-analyze` hangs
- very slow or blocked logout/shutdown/reboot

The accepted `/etc/schroot/xenial-desktop/fstab` design is:

```text
/proc   /proc   none   rw,bind    0 0
/sys    /sys    none   rw,rbind   0 0
/dev    /dev    none   rw,rbind   0 0
/home   /home   none   rw,rbind   0 0
/tmp    /tmp    none   rw,bind    0 0
/run/dbus /run/dbus none rw,bind 0 0
/run/user /run/user none rw,rbind,rslave 0 0
/media  /media  none   rw,rbind,rslave  0 0
/var/lib/maverick-host-apps/applications  /host-xdg/applications  none  ro,bind  0 0
/usr/share/icons                          /host-xdg/icons         none  ro,bind  0 0
/usr/share/pixmaps                        /host-xdg/pixmaps       none  ro,bind  0 0
/usr/share/themes                         /host-xdg/themes        none  ro,bind  0 0
```

Only `/run/dbus` and `/run/user` are exposed from the host runtime hierarchy.

At LightDM, a healthy state should show no stale Xenial sessions:

```bash
schroot -l --all-sessions
```

and `findmnt` should return immediately.

---

# 5. Xenial schroot profile

`/etc/schroot/chroot.d/xenial.conf`:

```text
[xenial]
description=Ubuntu MATE 16.04 Xenial
type=directory
directory=/srv/xenial
users=nruffell
preserve-environment=true
profile=xenial-desktop
setup.nssdatabases=
```

Replace the username when reproducing on another system.

Use the standard desktop `copyfiles` profile and an empty `nssdatabases` file.

---

# 6. LightDM Xenial session

Current `/usr/local/bin/xenial-mate-session`:

```bash
#!/bin/bash

UID_NUM="$(id -u)"

export DBUS_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket"
export PULSE_SERVER="unix:/run/user/${UID_NUM}/pulse/native"
export ICEAUTHORITY="$HOME/.ICEauthority"
export XDG_DATA_DIRS="/host-xdg:/usr/share/mate:/usr/local/share:/usr/share"

systemctl --user start maverick-host-launcher.service

cleanup()
{
    systemctl --user stop maverick-host-launcher.service
}

trap cleanup EXIT HUP INT TERM

schroot \
  --preserve-environment \
  --directory="$HOME" \
  -c xenial \
  -- \
  /usr/bin/dbus-launch --exit-with-session /usr/bin/mate-session

STATUS=$?
cleanup
trap - EXIT
exit "$STATUS"
```

Do not manually override `DESKTOP_SESSION`, `XDG_CURRENT_DESKTOP`, or similar values; LightDM supplies them.

`/usr/share/xsessions/ubuntu-mate-xenial.desktop`:

```ini
[Desktop Entry]
Name=Ubuntu MATE 16.04
Comment=Ubuntu MATE 16.04 Xenial
Exec=/usr/local/bin/xenial-mate-session
TryExec=/usr/local/bin/xenial-mate-session
Type=Application
DesktopNames=MATE
```

---

# 7. Native storage and audio

Xenial's GVfs/UDisks2-era stack works directly with Debian's current UDisks2 service. Confirmed behavior:

```text
insert USB
→ appears on desktop
→ appears in Caja
→ appears in Disks
→ eject works
→ remove/reinsert works
```

Do not add `udiskie` and do not build a UDisks1 compatibility bridge for Xenial.

Audio uses Debian PipeWire-Pulse through:

```text
PULSE_SERVER=unix:/run/user/$UID/pulse/native
```

The Xenial MATE volume applet works with the host sink.

---

# 8. Bluetooth and update notifier

Disable Xenial's obsolete Blueman autostart:

```bash
sudo mv /srv/xenial/etc/xdg/autostart/blueman.desktop \
  /srv/xenial/etc/xdg/autostart/blueman.desktop.disabled
```

Debian's current `blueman-applet` is started for the Xenial session instead.

Disable Xenial's update notifier because Debian owns updates:

```bash
sudo mv /srv/xenial/etc/xdg/autostart/update-notifier.desktop \
  /srv/xenial/etc/xdg/autostart/update-notifier.desktop.disabled
```

---

# 9. Debian host application bridge

Modern applications run on Debian but appear in Xenial's MATE menus.

```text
Xenial MATE menu
  ↓
mirrored Debian .desktop file
  ↓
/usr/local/bin/host-run
  ↓
/run/user/$UID/maverick-host-launch.sock
  ↓
session-scoped Debian systemd --user service
  ↓
real Debian executable + Debian libraries
  ↓
window on the Xenial/Marco desktop
```

Historical filenames still use the `maverick-*` prefix; this is only naming residue from the original prototype.

Mirrored host desktop files are prefixed with `debian-` so host and Xenial versions of the same application can coexist.

The app synchronizer watches Debian application directories and generates entries below:

```text
/var/lib/maverick-host-apps/applications
```

mounted read-only inside Xenial at:

```text
/host-xdg/applications
```

The synchronizer rewrites `Exec=` to use `/usr/local/bin/host-run`, removes `TryExec`, sets `DBusActivatable=false`, and avoids `OnlyShowIn`/`NotShowIn` conflicts.

A fallback MATE menu merge places otherwise-unallocated host applications under `Applications → Other`.

---

# 10. Session-scoped host launcher

`maverick-host-launcher.service` is intentionally **static/session-scoped**. It must not be permanently enabled under the user's default target.

Current unit:

```ini
[Unit]
Description=Debian host applications for legacy desktop session

[Service]
Type=simple
ExecStart=/usr/local/libexec/maverick-host-launcher
Restart=on-failure
KillMode=control-group
TimeoutStopSec=5s
```

The Xenial session script starts it at login and stops it after MATE exits.

XSMP-capable applications should close normally as part of MATE logout. The service cgroup is only the fallback for non-XSMP applications.

---

# 11. XSMP / ICE integration

A major logout integration fix was the explicit use of Xenial MATE's ICE authority file.

Xenial MATE writes ICE/XSMP cookies to:

```text
~/.ICEauthority
```

Modern Debian libICE otherwise defaults to:

```text
/run/user/$UID/ICEauthority
```

Therefore host applications must receive:

```text
SESSION_MANAGER
ICEAUTHORITY=$HOME/.ICEauthority
```

With this in place, Debian Firefox ESR was confirmed to acquire an `SM_CLIENT_ID` and close gracefully during normal MATE logout.

---

# 12. Correct SIGCHLD handling

The host launcher must **not** use:

```python
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
```

Although that avoids zombie children in the launcher itself, the ignored disposition can be inherited by launched applications. Electron/Chromium/Firefox-style applications may then fail when they call `waitpid()`, producing errors such as:

```text
Sandbox: CanCreateUserNamespace() waitpid(...) failure: ECHILD
```

The accepted generic fix is a real reaper:

```python
def reap_children(signum, frame):
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
            if pid == 0:
                break
        except ChildProcessError:
            break

signal.signal(signal.SIGCHLD, reap_children)
```

This reaps exited launcher children without forcing launched applications to inherit `SIGCHLD=SIG_IGN`.

---

# 13. Modern applications belong on Debian

Current applications should normally be installed on the Debian host, then exposed through the host-app bridge.

Discord provided the confirmed example. It initially appeared in the MATE menu but would not launch because its `.deb` had accidentally been installed inside Xenial:

```text
Xenial:
discord 1.0.156
/usr/bin/discord
/usr/share/applications/discord.desktop

Debian:
no Discord package
no Discord executable
no Discord desktop file
```

Correct workflow:

```bash
# Remove mistaken Xenial installation.
sudo schroot -c xenial -- apt remove discord

# Install the current .deb on Debian.
sudo apt install ~/Downloads/discord-*.deb

# Refresh host app mirror if needed.
sudo /usr/local/sbin/maverick-sync-host-apps
```

After installing Discord on Debian and exposing it through the bridge, Discord launched successfully from the Xenial MATE desktop.

General rule:

```text
modern/current application
→ install on Debian host
→ mirror launcher into Xenial menu
→ run through host-run with Debian libraries
```

---

# 14. Host graphical helpers

Debian graphical PolicyKit and Blueman helpers are started only for the Xenial session via an Xsession hook.

Known working helper paths:

```text
/usr/libexec/polkit-mate-authentication-agent-1
/usr/bin/blueman-applet
```

No host `udiskie` and no duplicate host NetworkManager applet are used inside Xenial.

---

# 15. Current confirmed state

Confirmed on the reference system:

- Debian 13 boots normally.
- LightDM offers `Ubuntu MATE 16.04`.
- Xenial MATE starts directly on the physical X11 display.
- MATE panel, Caja and Marco work.
- USB insertion/eject/reinsert works natively.
- USB devices appear in Caja, on the desktop and in Disks.
- Xenial audio reaches Debian PipeWire-Pulse.
- MATE volume control works.
- Debian applications are mirrored into Xenial menus.
- Xenial and Debian versions of the same application can coexist.
- Debian `host-run` works.
- Debian graphical PolicyKit prompts work.
- Debian Blueman appears in the MATE panel.
- Xenial Blueman and update-notifier are disabled.
- `SESSION_MANAGER` and `ICEAUTHORITY` are forwarded.
- XSMP-capable Debian applications participate in normal MATE logout.
- Non-XSMP host apps are cleaned up by the session-scoped service cgroup.
- The host launcher uses a real SIGCHLD reaper and leaves no defunct children.
- No recursive host `/run` bind is present.
- At LightDM, stale schroot sessions are absent and `findmnt` is responsive.
- Xenial login/logout is normal.
- Host shutdown/reboot is normal.
- Discord works when installed on Debian rather than Xenial.

---

# 16. Rules for reproduction

1. Match Xenial UID/GID to the Debian user.
2. Keep hardware-specific drivers/firmware on Debian.
3. Confirm host graphics before debugging Xenial.
4. Test raw Xenial MATE before adding bridge integration.
5. Test native USB before adding any automounter.
6. Keep `/run` selective; never recursively bind all of it.
7. Keep host launcher static/session-scoped.
8. Forward `SESSION_MANAGER` and `ICEAUTHORITY`.
9. Use a real SIGCHLD reaper, not `SIGCHLD=SIG_IGN`.
10. Prefer generic infrastructure changes over per-app fixes.
11. Install modern applications on Debian.
12. Keep Xenial desktop-shell components native for visual consistency.
13. Prefix mirrored host desktop IDs so host/Xenial copies can coexist.
14. Treat lingering Xenial schroot sessions at LightDM as abnormal.

---

# 17. Outstanding / deferred work

## Host application labels

Accepted design direction: all mirrored Debian/current applications should receive a visible suffix such as:

```text
(Host)
```

Example:

```text
Discord (Host)
Disks (Host)
Firefox ESR (Host)
```

This should be implemented generically in the existing host-app synchronizer so both current and future mirrored launchers are labeled automatically. It should not require another service.

Implementation is not yet recorded here as completed; it should be added only after testing succeeds.

## Themes

Theme sharing between Debian and Xenial is still being designed. A temporary host-theme exposure exists, but the final architecture should avoid unnecessary synchronizers while preserving:

- Xenial-native themes
- Debian-host themes
- system-wide/root visibility where appropriate

Do not treat the theme bridge as finalized until explicitly accepted.

---

# 18. Documentation maintenance rule

For future work:

```text
1. diagnose the issue or improvement
2. apply and test the final solution
3. only after the work is finished, ask whether this Markdown should be updated
4. update it only if approved
```

Do not update this handoff mid-troubleshooting. Temporary, failed or rejected fixes should not enter the canonical guide.

---

# Project summary

```text
Debian 13 supplies the modern operating system.
Ubuntu MATE 16.04 supplies the classic GTK2 desktop.
The session runs directly on physical X11 through schroot.
Host-run and XDG mirroring expose current Debian applications without replacing Xenial's native copies.
XSMP/ICE integration lets compliant host applications participate in normal MATE logout.
A session-scoped systemd cgroup handles non-XSMP leftovers.
Selective runtime binds avoid /run/schroot recursion and stale mount trees.
```
