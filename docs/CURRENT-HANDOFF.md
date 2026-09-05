# Debian 13 Host + Ubuntu Xenial MATE/Unity Hybrid Desktop
## Current canonical handoff / replication checkpoint

This document records the current accepted architecture for **Schroot Desktop**.

The project runs classic Ubuntu 16.04 desktop userspaces directly on the physical X11 display while Debian 13 remains the real operating system underneath. The established MATE session and the accepted Unity session use separate Xenial roots. Failed experiments and superseded fixes are deliberately omitted.

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
├── Caja 1.26 + Debian GVfs for MATE
├── host-run launcher service
└── physical X11 display :0
       ├── schroot /srv/xenial
       │    └── Ubuntu MATE 16.04 Xenial
       │         ├── mate-session
       │         ├── mate-panel
       │         ├── Marco 1.12
       │         ├── mate-settings-daemon
       │         └── classic GTK2 shell behavior
       │
       └── schroot /srv/xenial-unity
            └── Ubuntu Unity 16.04 Xenial
                 ├── Unity 7 / Compiz
                 ├── ubuntu-session / Xenial user Upstart
                 ├── unity-settings-daemon
                 ├── unity-control-center
                 └── native Xenial Nautilus/GVfs
```

This is not a VM, VNC/RDP session, Xephyr session, nested X server, or remote desktop. Both accepted Xenial desktop sessions run directly on the real physical X11 display.

The roots are intentionally separate:

```text
/srv/xenial        -> MATE
/srv/xenial-unity  -> Unity
```

They share `/home`. User UID/GID must match between Debian and both Xenial roots.

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
- Caja 1.26 for normal MATE file management and desktop ownership
- Debian GVfs used by host Caja
- system/security updates

The MATE root owns:

- MATE session
- mate-panel
- Marco
- mate-settings-daemon
- classic GTK2 desktop behavior
- Xenial GVfs for Xenial-native applications

The Unity root owns:

- Unity 7 / Compiz
- `ubuntu-session`
- Xenial user-Upstart session startup
- `unity-settings-daemon`
- `unity-control-center`
- native Xenial Nautilus/GVfs desktop behavior
- Unity lenses/search components and Xenial theme/default integration

Package presence inside Xenial does not imply runtime service ownership. Debian remains the owner of hardware-facing backend services even when Xenial packages pull older service binaries as dependencies.

---

# 2. Critical schroot mount rule

Never recursively bind the whole host `/run` into either Xenial root.

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

The Unity root uses its own `xenial-unity-desktop` schroot profile so later desktop-specific mount changes do not risk the MATE root. The current tested mount set is otherwise the same as the MATE profile.

---

# 3. Xenial session lifecycles

## MATE

The Debian LightDM session launches Xenial MATE through `/usr/local/bin/xenial-mate-session`.

Important environment values include:

```text
DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
PULSE_SERVER=unix:/run/user/$UID/pulse/native
ICEAUTHORITY=$HOME/.ICEauthority
XDG_DATA_DIRS=/host-xdg:/usr/share/mate:/usr/local/share:/usr/share
```

## Unity

The Debian LightDM session launches the separate `xenial-unity` root through `/usr/local/bin/xenial-unity-session`.

Unity must enter Xenial through:

```text
/etc/X11/Xsession "gnome-session --session=ubuntu"
```

because Xenial Unity/Compiz is started by Xenial **user Upstart** from the native `xsession SESSION=ubuntu` event. Directly launching `gnome-session` bypasses part of the native Unity startup contract.

The Debian LightDM environment did not include `/sbin`, so the accepted Unity wrapper sets:

```text
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

This is required for Xenial Upstart helpers such as `initctl` and `upstart-udev-bridge`.

Unity's Xenial user-Upstart session owns its own session D-Bus. The wrapper deliberately removes Debian's inherited `DBUS_SESSION_BUS_ADDRESS` before entering Xenial. The live Compiz environment confirmed a native Xenial abstract `/tmp/dbus-*` address.

For host application discovery, the wrapper seeds:

```text
XDG_DATA_DIRS=/host-xdg:/usr/local/share:/usr/share
```

and Xenial Xsession expands the live value to include the native Ubuntu/GNOME directories:

```text
/usr/share/ubuntu:/usr/share/gnome:/host-xdg:/usr/local/share:/usr/share
```

Full tested Unity setup: [`XENIAL-UNITY.md`](XENIAL-UNITY.md).

## Host launcher lifecycle

Both desktop wrappers use the same Debian `maverick-host-launcher.service` as a **session-scoped** systemd user service and stop it when the legacy desktop exits. The launcher must not be permanently enabled.

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

Modern applications normally live on Debian but appear in the Xenial desktop menus/Dash.

```text
Xenial menu / Unity Dash
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

## Xenial application view

Generated launchers live below:

```text
/var/lib/maverick-host-apps/applications
```

and are exposed inside the Xenial roots at:

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
StartupWMClass       -> preserve when supplied by source
if no StartupWMClass -> prepend BAMF_DESKTOP_FILE_HINT for the mirrored debian-* file
TryExec=             -> remove
DBusActivatable=     -> force false
OnlyShowIn=          -> remove
NotShowIn=           -> remove
```

This lets Xenial-native and Debian-host versions of the same application coexist without silently replacing each other.

The Unity root currently carries the same `host-run` client as the MATE root. The client uses `#!/usr/bin/python` and imports Python 2 `json`; therefore the normal Xenial `python` package is part of the accepted Unity integration. `python-minimal` alone is insufficient and produced `ImportError: No module named json`.

## Unity/BAMF launcher matching

Unity uses BAMF to associate a running application with the `.desktop` launcher that owns it. Testing showed that host launchers which already provide `StartupWMClass` match correctly after mirroring, while some source launchers without `StartupWMClass` can produce a temporary launcher icon plus a separate running-app icon because the project intentionally changed the desktop ID to `debian-*`.

The accepted generic fix is conditional:

```text
source has StartupWMClass
    -> preserve it; no BAMF hint added

source lacks StartupWMClass
    -> generated Exec prepends:
       BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-<original>.desktop
```

The path is the mirrored desktop-file path visible inside Xenial, where Unity/BAMF runs.

Example:

```ini
Exec=/usr/bin/env BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-org.deskflow.deskflow.desktop /usr/local/bin/host-run deskflow
```

The environment is filtered by the bridge, so `BAMF_DESKTOP_FILE_HINT` must be present in the allow-lists of:

```text
/srv/xenial/usr/local/bin/host-run
/srv/xenial-unity/usr/local/bin/host-run
/usr/local/libexec/maverick-host-launcher
```

The hint was confirmed in the real Debian Deskflow process environment. After applying the generic rule, previously affected host applications tested in Unity used one correct launcher icon. Firefox ESR and Synaptic, which already provide `StartupWMClass`, remained on their native matching path and were unchanged.

Do not create per-app `StartupWMClass` maps or app-specific launcher fixes for this class of problem. The conditional BAMF rule belongs in the generic synchronizer and is inherited automatically by future mirrored host apps.

Full labeling/matching policy: [`HOST-APP-LABELING.md`](HOST-APP-LABELING.md).

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

This behavior is confirmed for the MATE path. The Unity host bridge forwards the same relevant environment values, but the full XSMP logout case has not yet been separately revalidated for Unity.

---

# 6. Debian Caja owns the MATE desktop and file management

The MATE reference build uses Debian Caja 1.26 rather than Xenial Caja for normal browsing and desktop ownership.

Tested host packages include:

```text
caja 1.26.4-1
gvfs 1.57.2-2+deb13u1
gvfs-backends 1.57.2-2+deb13u1
gvfs-fuse 1.57.2-2+deb13u1
```

The Xenial Caja package remains installed as a rollback/fallback.

Do **not** apply this Caja takeover to Unity. The accepted Unity baseline intentionally uses native Xenial Nautilus.

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

Confirmed working in MATE:

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

After Debian Caja took over the MATE desktop, its `Open With` and file-context menus read Debian's normal application database and therefore lost the project `(Host)` labels.

The accepted generic fix is a second generated XDG application view:

```text
/var/lib/maverick-host-apps/caja-xdg/applications
```

It is maintained by the **same existing app synchronizer**. No new daemon, watcher, or separate synchronizer was added.

## Debian entries

For Debian applications in this Caja-specific view:

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

## Xenial-native MIME handlers

Host Caja must also see Xenial-native handlers. Otherwise applications can remain visible in the MATE panel menus but disappear from Caja's `Open With` choices.

The confirmed example was GDebi. Both Debian and Xenial provide:

```text
gdebi.desktop
MimeType=application/vnd.debian.binary-package;
```

The accepted generic policy is to add Xenial application entries to the same private Caja view with unique `xenial-` desktop IDs:

```text
Debian:
  gdebi.desktop
  Name=GDebi Package Installer (Host)
  Exec=gdebi-gtk %f

Xenial:
  xenial-gdebi.desktop
  Name=GDebi Package Installer
  Exec=/usr/local/bin/xenial-run gdebi-gtk %f
```

Policy for Xenial entries:

```text
desktop ID          -> prefix with xenial-
Name=/Name[locale]  -> preserve original Xenial name
Exec=               -> wrap with /usr/local/bin/xenial-run
TryExec=             -> remove
DBusActivatable=    -> force false when present
MimeType=           -> preserve
Categories/metadata -> preserve
```

This allows Debian-host and Xenial-native applications to coexist for the same MIME type while keeping the execution side obvious: Debian handlers carry `(Host)` and Xenial handlers do not.

## `xenial-run`

`/usr/local/bin/xenial-run` currently launches commands inside the **already-running Xenial MATE schroot session**.

It locates the live `mate-panel` process for the current user, verifies that its `/proc/<pid>/root` is `/run/schroot/mount/xenial-*`, imports that process's session environment, and then executes:

```text
schroot --run-session -c <active-xenial-session> --preserve-environment ...
```

The live Xenial MATE environment was confirmed to contain:

```text
DISPLAY=:0
XAUTHORITY=$HOME/.Xauthority
DBUS_SESSION_BUS_ADDRESS=<Xenial session bus>
PULSE_SERVER=unix:/run/user/$UID/pulse/native
XDG_RUNTIME_DIR=/run/user/$UID
SESSION_MANAGER=<Xenial MATE session manager>
ICEAUTHORITY=$HOME/.ICEauthority
```

A manual `schroot --run-session` launch using this environment successfully opened Xenial GDebi. After the generated Xenial entries were added and Caja restarted, both GDebi choices were visible again for `.deb` files.

This helper remains MATE-specific because it discovers the active root through `mate-panel`. Do not generalize it to Unity until a demonstrated Unity host->legacy-native MIME-handler requirement exists.

The existing synchronizer scans Xenial application directories whenever it runs. No new watcher was added. If Xenial application launchers later change independently of Debian launcher changes, rerun:

```bash
sudo /usr/local/sbin/maverick-sync-host-apps
```

to refresh the Caja application view.

Full labeling policy: [`HOST-APP-LABELING.md`](HOST-APP-LABELING.md).

---

# 8. Storage, audio and graphical helpers

## Storage

Do not reintroduce `udiskie` or a UDisks1 compatibility layer.

The MATE design uses host UDisks2 with Debian Caja/Debian GVfs for host file management while Xenial GVfs remains available to Xenial-native applications.

The Unity design uses native Xenial Nautilus/GVfs against the same host UDisks2 backend. Tested Unity behavior includes:

- removable USB media visible and browsable
- fixed internal volume requiring authentication
- Debian graphical PolicyKit password prompt
- successful mount through Debian UDisks2
- mounted fixed volume visible and browsable in Xenial Nautilus

## Audio

Xenial audio clients use Debian PipeWire-Pulse through:

```text
PULSE_SERVER=unix:/run/user/$UID/pulse/native
```

The Xenial MATE volume applet can control the host sink. Unity continues to use the same host audio architecture.

## PolicyKit and Bluetooth

Debian's graphical PolicyKit agent is used for both accepted Xenial desktop sessions.

The current host helper policy is:

```text
ubuntu-mate-xenial  -> Debian polkit-mate agent + Debian Blueman
ubuntu-unity-xenial -> Debian polkit-mate agent
```

The Debian polkit-mate agent can log a warning that `org.gnome.SessionManager` is unavailable on the host user bus during Unity login. The warning is functionally harmless in the tested setup: PolicyKit authentication still works and authorized UDisks2 mounts succeed.

Blueman remains MATE-only until Unity Bluetooth behavior is separately validated.

Xenial's update notifier remains disabled because Debian owns system updates.

---

# 9. Xenial Unity parallel root

The accepted Unity root is a **fresh debootstrap**, not a copy of `/srv/xenial`.

Schroot name/root/profile:

```text
xenial-unity
/srv/xenial-unity
xenial-unity-desktop
```

The tested final desktop package set includes the core Unity session plus the Ubuntu defaults/integration that proved necessary for a usable desktop:

```text
unity
ubuntu-session
nautilus
indicator-appmenu
indicator-application
indicator-datetime
indicator-keyboard
indicator-messages
indicator-power
indicator-session
indicator-sound
hud
session-shortcuts
dbus-x11
ubuntu-settings
light-themes
unity-lens-applications
unity-lens-files
zeitgeist-core
iso-codes
unity-control-center
python
```

`ubuntu-desktop` was deliberately not adopted because it pulls a much broader Xenial desktop/Xorg payload than this architecture requires.

Important proven package effects:

- `ubuntu-settings` + `light-themes` restore the expected Ubuntu/Unity theme defaults and decoration assets
- Unity lenses + Zeitgeist restore normal Dash application/search content
- `unity-control-center` restores normal Appearance/Desktop Background integration
- full `python` supplies the Python 2 standard library required by `host-run`; `python-minimal` alone does not

The Unity root keeps native Nautilus rather than the MATE-specific host Caja takeover.

Full replication details, wrapper contents, LightDM entry and helper hook: [`XENIAL-UNITY.md`](XENIAL-UNITY.md).

---

# 10. Modern applications belong on Debian

Current applications should normally be installed on the Debian host and exposed through the bridge.

Discord provided the confirmed MATE example: when its `.deb` was accidentally installed inside Xenial it appeared in the menu but did not launch correctly. Removing the Xenial copy and installing the `.deb` on Debian fixed it.

The same generic host application bridge is now confirmed working from the Unity root.

General rule:

```text
modern/current application
→ install on Debian host
→ mirror launcher into Xenial desktop
→ run with Debian libraries through host-run
```

Do not install current Electron/Chromium-style applications inside Xenial unless there is a specific justified reason.

---

# 11. Current performance baseline

The reference iMac18,1 was audited and did not require low-level performance tuning.

Confirmed for the established baseline:

- `intel_pstate` scales from roughly 400 MHz idle to about 3.6 GHz under load
- one-minute four-thread load ended around 50 C with no observed frequency collapse
- Debian uses i915 + Xorg modesetting
- direct rendering is active on Debian and the Xenial MATE session
- no llvmpipe fallback was observed
- memory and swap pressure were absent during testing
- settled idle CPU was typically about 98–99.5% idle
- Marco runs with its compositor disabled while Compton provides the GLX compositor
- Compton showed effectively zero settled idle CPU cost

The Unity session was separately confirmed to use direct Intel/Mesa hardware acceleration with no llvmpipe fallback. A full Unity-specific performance baseline has not been run and is not currently required because no performance problem has been demonstrated.

No generic performance tweaks are accepted or required at this time.

See [`PERFORMANCE-BASELINE.md`](PERFORMANCE-BASELINE.md).

---

# 12. Current confirmed state

The reference machine has been tested with:

## MATE

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
- simultaneous Debian-host and Xenial-native MIME handlers in host Caja, confirmed with GDebi for `.deb` files
- host/native duplicate application coexistence
- XSMP/ICE graceful logout for capable host apps
- cgroup fallback cleanup for remaining host apps
- a real `SIGCHLD` reaper in the host launcher
- healthy CPU/GPU/memory/thermal performance baseline

## Unity

- separate fresh `/srv/xenial-unity` root
- Debian LightDM -> Ubuntu Unity 16.04 login
- Unity 7/Compiz directly on physical X11
- native Xenial user-Upstart startup and session D-Bus
- expected Ambiance/Ubuntu theme assets
- wallpaper and Appearance/Desktop Background integration
- no observed Compiz ghosting after the complete accepted theme/default package set was installed
- populated application/search lenses
- native Xenial Nautilus desktop/file management
- automatic host-app mirror visible through `/host-xdg`
- Debian host applications launching through the existing host-run bridge
- generic BAMF launcher matching: preserve source `StartupWMClass`, otherwise forward `BAMF_DESKTOP_FILE_HINT` for the mirrored `debian-*` desktop file
- previously affected host apps now associate with one correct Unity launcher icon without per-app WM-class rules
- removable USB media through Xenial GVfs + Debian UDisks2
- fixed internal volume authentication through Debian polkitd + Debian graphical polkit-mate agent
- mounted fixed volume visible and browsable in Nautilus
- direct Intel/Mesa hardware acceleration with no llvmpipe fallback observed

---

# 13. Maintenance rules

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

Keep MATE-specific and Unity-specific behavior separate where their native desktop architecture differs. Generalize only infrastructure that has actually proved common, such as the host application mirror/launcher and Debian hardware-facing services.

The latest accepted GitHub files are the source of truth for implementation details. If older handoffs or conversation history disagree with current accepted documentation or observed behavior, prefer the current evidence and documentation.
