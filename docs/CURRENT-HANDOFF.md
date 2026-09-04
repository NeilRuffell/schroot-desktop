# Debian 13 Host + Ubuntu MATE 16.04 Xenial Hybrid Desktop
## Current canonical handoff / replication checkpoint

This document records the current accepted architecture for **Schroot Desktop**.

The project runs an Ubuntu MATE 16.04 Xenial desktop userspace directly on the physical X11 display while Debian 13 remains the real operating system underneath. Failed experiments and superseded fixes are deliberately omitted.

---

# 1. Current architecture

```text
Debian 13 host
├── kernel / drivers / firmware
├── Mesa / DRM / KMS
├── Xorg + LightDM
├── NetworkManager
├── PipeWire / WirePlumber
├── UDisks2 / UPower / polkitd
├── current applications
├── Caja 1.26 + Debian GVfs
├── host-run launcher service
└── physical X11 display :0
       ↓
   schroot /srv/xenial
       ↓
Ubuntu MATE 16.04 Xenial
├── mate-session
├── mate-panel
├── Marco 1.12
├── mate-settings-daemon
├── classic GTK2 shell behavior
└── Xenial GVfs remains available for Xenial-native applications
```

This is not a VM, VNC/RDP session, Xephyr session, nested X server, or remote desktop. Xenial MATE runs directly on the real physical X11 display.

## Responsibility split

Debian owns:

- kernel and hardware support
- firmware, Mesa, DRM/KMS and Xorg
- LightDM
- NetworkManager
- PipeWire/WirePlumber
- UDisks2 and UPower
- polkitd and graphical host helpers
- current/modern applications
- Caja 1.26 for normal file management and desktop ownership
- Debian GVfs used by host Caja
- system/security updates

Xenial owns:

- MATE session
- mate-panel
- Marco
- mate-settings-daemon
- classic GTK2 desktop behavior
- Xenial GVfs for Xenial-native applications

`/home` is shared. User UID/GID must match between Debian and Xenial.

---

# 2. Critical schroot mount rule

Never recursively bind the whole host `/run` into Xenial.

The old design:

```text
/run /run none rw,rbind 0 0
```

caused schroot's own `/run/schroot/mount/...` trees to be recursively pulled back into the chroot, producing stale sessions, busy mount trees, `findmnt` hangs, and slow or blocked logout/shutdown/reboot.

The accepted runtime exposure is selective:

```text
/proc     /proc      none rw,bind          0 0
/sys      /sys       none rw,rbind         0 0
/dev      /dev       none rw,rbind         0 0
/home     /home      none rw,rbind         0 0
/tmp      /tmp       none rw,bind          0 0
/run/dbus /run/dbus  none rw,bind          0 0
/run/user /run/user  none rw,rbind,rslave  0 0
/media    /media     none rw,rbind,rslave  0 0
```

Host XDG resources are exposed at `/host-xdg` as required. Do not reintroduce a recursive `/run` bind.

---

# 3. Xenial session lifecycle

The Debian LightDM session launches Xenial MATE through `/usr/local/bin/xenial-mate-session`.

Important environment values include:

```text
DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
PULSE_SERVER=unix:/run/user/$UID/pulse/native
ICEAUTHORITY=$HOME/.ICEauthority
XDG_DATA_DIRS=/host-xdg:/usr/share/mate:/usr/local/share:/usr/share
```

The session starts the host application launcher as a **session-scoped** systemd user service and stops it when MATE exits. The launcher must not be permanently enabled.

Expected service policy:

```ini
[Service]
Type=simple
ExecStart=/usr/local/libexec/maverick-host-launcher
Restart=on-failure
KillMode=control-group
TimeoutStopSec=5s
```

The service cgroup is a fallback cleanup mechanism for host applications that do not participate in XSMP logout.

---

# 4. Host application bridge

Modern applications normally live on Debian but appear in the Xenial MATE menus.

```text
Xenial MATE menu
  ↓
generated Debian launcher
  ↓
/usr/local/bin/host-run
  ↓
/run/user/$UID/maverick-host-launch.sock
  ↓
session-scoped host launcher
  ↓
real Debian executable + Debian libraries
```

The existing synchronizer is:

```text
/usr/local/sbin/maverick-sync-host-apps
```

and is triggered by the existing host-app path watcher.

## Xenial menu view

Generated launchers live below:

```text
/var/lib/maverick-host-apps/applications
```

and are exposed inside Xenial at:

```text
/host-xdg/applications
```

Policy:

```text
desktop ID           -> prefix with debian-
main Name=           -> append " (Host)"
localized Name[]=    -> append " (Host)"
desktop-action Name= -> preserve
Exec=                -> wrap with host-run
TryExec=             -> remove
DBusActivatable=     -> force false
OnlyShowIn=          -> remove
NotShowIn=           -> remove
```

This lets Xenial-native and Debian-host versions of the same application coexist without silently replacing each other.

## Correct child handling

Do **not** use:

```python
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
```

Ignored `SIGCHLD` dispositions can be inherited by launched Electron/Chromium/Firefox-style applications and cause their `waitpid()` calls to fail with `ECHILD`.

Use a real child reaper in the launcher instead.

---

# 5. XSMP / ICE integration

Host applications receive:

```text
SESSION_MANAGER
ICEAUTHORITY=$HOME/.ICEauthority
```

Xenial MATE writes its ICE/XSMP cookies to `~/.ICEauthority`, while current Debian libICE may otherwise default to `/run/user/$UID/ICEauthority`.

With the explicit `ICEAUTHORITY`, XSMP-capable host applications such as Debian Firefox ESR acquire an `SM_CLIENT_ID` and close normally during MATE logout.

---

# 6. Debian Caja owns the desktop and file management

The reference build uses Debian Caja 1.26 rather than Xenial Caja for normal browsing and desktop ownership.

Tested host packages include:

```text
caja 1.26.4-1
gvfs 1.57.2-2+deb13u1
gvfs-backends 1.57.2-2+deb13u1
gvfs-fuse 1.57.2-2+deb13u1
```

The Xenial Caja package remains installed as a rollback/fallback.

## MATE required components

Do not use fire-and-forget `host-run` as MATE's required `filemanager` component. The accepted list is:

```text
['windowmanager', 'panel', 'dock']
```

Host Caja is instead started once in the MATE Desktop autostart phase.

## Xenial Caja wrapper

`/srv/xenial/usr/local/bin/caja` routes normal Xenial `caja` calls to the host:

```sh
#!/bin/sh
exec /usr/local/bin/host-run \
  /usr/bin/env \
  XDG_DATA_DIRS=/var/lib/maverick-host-apps/caja-xdg:/usr/local/share:/usr/share \
  /usr/bin/caja "$@"
```

Because `/usr/local/bin` precedes `/usr/bin`, normal Places/folder actions use Debian Caja while `/usr/bin/caja` remains available inside Xenial for rollback.

## Desktop autostart

`~/.config/autostart/debian-caja-desktop.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Debian Caja Desktop
Exec=/usr/local/bin/host-run /usr/bin/env XDG_DATA_DIRS=/var/lib/maverick-host-apps/caja-xdg:/usr/local/share:/usr/share /usr/bin/caja --force-desktop --no-default-window
OnlyShowIn=MATE;
X-MATE-Autostart-Phase=Desktop
NoDisplay=true
```

Confirmed runtime:

```text
/usr/bin/caja --force-desktop --no-default-window
exe:  /usr/bin/caja
root: /
```

This proves Debian Caja owns the desktop rather than the schroot copy.

Confirmed working:

- desktop icons and desktop right-click
- Home / Computer / Trash
- Places menu and folder launching
- additional Caja windows
- USB insertion/visibility/eject
- normal logout/login

Both Debian and Xenial GVfs stacks may run simultaneously. Debian Caja uses Debian GVfs; Xenial-native applications may continue using Xenial GVfs. Do not remove Xenial GVfs without a demonstrated reason.

Full details: [`HOST-CAJA.md`](HOST-CAJA.md).

---

# 7. Host Caja private XDG application view

After Debian Caja took over, its `Open With` and file-context menus read Debian's normal application database and therefore lost the project `(Host)` labels.

The accepted generic fix is a second generated XDG application view:

```text
/var/lib/maverick-host-apps/caja-xdg/applications
```

It is maintained by the **same existing app synchronizer and watcher**. No new daemon or watcher was added.

For this Caja-specific view:

```text
desktop ID           -> preserve original Debian ID
Exec=                -> preserve original direct host command
MIME/default-app IDs -> preserve
main Name=           -> append " (Host)"
localized Name[]=    -> append " (Host)"
desktop-action Name= -> preserve
```

Caja is launched with:

```text
XDG_DATA_DIRS=/var/lib/maverick-host-apps/caja-xdg:/usr/local/share:/usr/share
```

This restores `(Host)` labels in `Open With` and file-context application menus without modifying Debian's real `.desktop` files and without breaking native Debian MIME/default-application IDs.

Full labeling policy: [`HOST-APP-LABELING.md`](HOST-APP-LABELING.md).

---

# 8. Storage, audio and graphical helpers

## Storage

Do not reintroduce `udiskie` or a UDisks1 compatibility layer.

The current design uses host UDisks2. Debian Caja uses Debian GVfs; Xenial GVfs remains available for Xenial-native applications.

## Audio

Xenial audio clients use Debian PipeWire-Pulse through:

```text
PULSE_SERVER=unix:/run/user/$UID/pulse/native
```

The Xenial MATE volume applet can control the host sink.

## PolicyKit and Bluetooth

Debian's graphical PolicyKit agent and Debian Blueman are used in the Xenial session. Xenial's obsolete Blueman autostart is disabled.

Xenial's update notifier is also disabled because Debian owns system updates.

---

# 9. Modern applications belong on Debian

Current applications should normally be installed on the Debian host and exposed through the bridge.

Discord provided the confirmed example: when its `.deb` was accidentally installed inside Xenial it appeared in the menu but did not launch correctly. Removing the Xenial copy and installing the `.deb` on Debian fixed it.

General rule:

```text
modern/current application
→ install on Debian host
→ mirror launcher into Xenial menu
→ run with Debian libraries through host-run
```

Do not install current Electron/Chromium-style applications inside Xenial unless there is a specific justified reason.

---

# 10. Current performance baseline

The reference iMac18,1 was audited and did not require low-level performance tuning.

Confirmed:

- `intel_pstate` scales from roughly 400 MHz idle to about 3.6 GHz under load
- one-minute four-thread load ended around 50 C with no observed frequency collapse
- Debian uses i915 + Xorg modesetting
- direct rendering is active on both Debian and Xenial
- no llvmpipe fallback was observed
- memory and swap pressure were absent during testing
- settled idle CPU was typically about 98–99.5% idle
- Marco runs with its compositor disabled while Compton provides the GLX compositor
- Compton showed effectively zero settled idle CPU cost

No generic performance tweaks are accepted or required at this time.

See [`PERFORMANCE-BASELINE.md`](PERFORMANCE-BASELINE.md).

---

# 11. Current confirmed state

The reference machine has been tested with:

- Debian 13 normal boot to LightDM
- Xenial MATE login directly on physical X11
- normal logout, shutdown and reboot
- Debian Caja desktop ownership
- normal Caja folder browsing
- desktop icons/right-click/Home/Computer/Trash
- USB insertion/eject and removable-storage visibility
- Debian and Xenial GVfs coexistence
- PipeWire-Pulse audio and MATE volume control
- Debian graphical PolicyKit prompts
- Debian Blueman applet
- automatic host-app mirroring
- automatic `(Host)` labels in the MATE menu
- automatic `(Host)` labels in host Caja `Open With`/file-context menus
- host/native duplicate application coexistence
- XSMP/ICE graceful logout for capable host apps
- cgroup fallback cleanup for remaining host apps
- a real `SIGCHLD` reaper in the host launcher
- healthy CPU/GPU/memory/thermal performance baseline

---

# 12. Maintenance rules

For future work:

```text
1. diagnose first
2. gather evidence
3. prefer the smallest generic fix
4. test it
5. confirm the issue is resolved
6. only then ask whether canonical documentation should be updated
7. update GitHub only after approval
```

Do not put provisional experiments into canonical setup instructions.

The latest accepted GitHub files are the source of truth for implementation details. If older handoffs or conversation history disagree with current accepted documentation or observed behavior, prefer the current evidence and documentation.
