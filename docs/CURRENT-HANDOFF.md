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
├── session-scoped host-run launcher service
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

Unity's Xenial user-Upstart session owns its own session D-Bus. The wrapper deliberately removes Debian's inherited `DBUS_SESSION_BUS_ADDRESS` before entering Xenial. The live Compiz environment confirmed a native Xenial abstract `/tmp/dbus-*` address.

For host application discovery, the wrapper seeds:

```text
XDG_DATA_DIRS=/host-xdg:/usr/local/share:/usr/share
```

and Xenial Xsession expands the live value to include native Ubuntu/GNOME directories.

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

Current accepted policy:

```text
desktop ID           -> prefix with debian-
main Name=           -> append " (Host)"
localized Name[]=    -> append " (Host)"
desktop-action Name= -> preserve
Exec=                -> wrap with host-run
BAMF identity        -> prepend BAMF_DESKTOP_FILE_HINT for every generated Host Exec=
StartupWMClass       -> remove from generated Host mirror
StartupNotify        -> force false in current tested mirror
TryExec=             -> remove
DBusActivatable=     -> force false
OnlyShowIn=          -> remove
NotShowIn=           -> remove
unprefixed shadows  -> never generate
```

This lets Xenial-native and Debian-host versions of the same application coexist without silently replacing each other. The mirror must not create unprefixed `Hidden=true` tombstones: because `/host-xdg` precedes the native application directory, such a file would mask a Xenial launcher with the same desktop-file ID. Hiding remains an explicit per-user policy through `~/.local/share/applications`.

The Unity root carries the same `host-run` client as the MATE root. The client uses `#!/usr/bin/python` and imports Python 2 `json`; therefore the normal Xenial `python` package is part of the accepted Unity integration. `python-minimal` alone is insufficient.

## Unity/BAMF launcher matching — final accepted design

The earlier conditional rule — preserve source `StartupWMClass` and add a BAMF hint only when it is missing — is **superseded** and is not part of the current build.

The duplicate/replacement icon problem was captured directly at the BAMF object level. During a failing Visual Studio Code Host launch, BAMF first created a `Starting=true` application object for `debian-code.desktop`. When the real Code X11 window appeared, BAMF created a second runtime application object rather than attaching that window to the existing Host startup application. Unity therefore showed two launcher objects until the startup object disappeared.

The investigation established two architectural causes:

1. The asynchronous schroot bridge breaks BAMF's normal GIO launch-PID ancestry. Xenial starts `host-run`, but the real Debian application is later spawned by the separate Debian launcher service.
2. Copied Debian `StartupWMClass` is only a heuristic and can be absent, stale, or case-mismatched. Xenial BAMF can use it to veto an otherwise-correct explicit Host identity.

Confirmed real examples:

```text
Visual Studio Code:
  source StartupWMClass=Code
  live WM_CLASS="code", "code"

GIMP 3:
  source StartupWMClass=gimp-3.0
  live WM_CLASS="gimp", "Gimp"
```

Environment-only BAMF hints were also proven structurally insufficient because Electron Visual Studio Code lost the launch identity from its final process environment.

### Authoritative mirrored identity

Every generated Host `Exec=` carries:

```text
BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-<original>.desktop
```

This is the path visible to Xenial BAMF. It applies to **all** generated `debian-*.desktop` launchers.

### Real PID registration

The bridge restores BAMF's expected PID relationship explicitly:

```text
mirrored debian-*.desktop
        ↓
Xenial host-run sends command + mirrored desktop identity
        ↓
Debian maverick-host-launcher starts a stopped launch gate
        ↓
launcher returns the gate/real PID
        ↓
Xenial host-run calls:
org.ayatana.bamf.control.RegisterApplicationForPid
        ↓
PID is registered to /host-xdg/applications/debian-*.desktop
        ↓
host-run sends SIGCONT
        ↓
gate execs the real Debian application with the same PID
```

The stopped gate is deliberate. It removes the race where a fast application could create its first X11 window before BAMF receives the PID registration.

Testing confirmed that `RegisterApplicationForPid` stamps the authoritative `_BAMF_DESKTOP_FILE` on the real application window, including Electron Visual Studio Code and privileged GUFW. BAMF's PID ancestry handling covers normal descendants/wrappers; the early registration was also confirmed to survive the GUFW privilege-helper/detachment path at the window identity level.

### Remove mirrored `StartupWMClass` globally

The synchronizer strips `StartupWMClass=` from the main `[Desktop Entry]` of **every** generated `debian-*.desktop` file.

This affects only the generated Host mirror. Debian's real `.desktop` files and Xenial-native launchers are not modified.

Once the bridge provides an authoritative PID-to-desktop relationship, copied host `StartupWMClass` is a weaker heuristic that can override the correct identity. Removing it globally is therefore cleaner than synthesizing or repairing values per application.

The current tested generic mirror pass also forces `StartupNotify=false`. That setting was present during final testing, but it was **not sufficient by itself** to solve the duplicate-icon problem. The accepted decisive mechanism is authoritative Host identity + early BAMF PID registration + global removal of mirrored `StartupWMClass`.

Final Unity regression testing showed duplicate/replacement launcher icons resolved across the tested Host application classes, including:

- Visual Studio Code (Electron)
- GIMP
- Firefox ESR
- Synaptic / pkexec wrapper
- GUFW / Firewall Configuration privileged path
- ordinary GTK Host applications

Do not create per-app `StartupWMClass` maps, Electron exceptions, application-specific launcher fixes, or a downstream BAMF source patch for this issue. Future Host applications inherit the generic synchronizer/bridge behavior automatically.

Full labeling/matching policy: [`HOST-APP-LABELING.md`](HOST-APP-LABELING.md).

## Unity Host global menu and HUD — accepted universal protocol bridge

The accepted Unity menu/HUD integration is **not** based on per-app fixes.

Debian Host applications remain connected to Debian's user bus:

```text
unix:path=/run/user/$UID/bus
```

while Xenial Unity keeps its independent native session bus. The bridge transports supported menu interfaces between those buses without moving the application itself.

Accepted Debian helper files are:

```text
/usr/local/libexec/maverick_unity_menu.py
/usr/local/libexec/maverick-unity-menu-bridge
```

They run under the existing session-scoped `maverick-host-launcher.service`; no new permanent daemon or systemd unit was added.

The bridge supports both of Unity's relevant menu source families:

1. GMenuModel/GActionGroup exposed through standard `_GTK_*` X11 properties, including separate application menu, menubar and `app`, `win`, and `unity` action groups where present.
2. Legacy `com.canonical.dbusmenu` exporters using `com.canonical.AppMenu.Registrar`.

Traditional GTK3 GtkMenuShell/GtkUIManager applications are covered generically by injecting Debian's `appmenu-gtk3-module` for Unity Host launches:

```text
GTK_MODULES=appmenu-gtk-module
UBUNTU_MENUPROXY=1
```

The real Host process still receives Debian's D-Bus address.

For GMenu sources the helper retrieves the remote GMenu/GAction objects from Debian, constructs a live GTK3 menu model with the correct action prefixes, converts it to DBusMenu, exports a unique per-window DBusMenu object on the Unity bus, and registers the actual XID with Unity's native:

```text
com.canonical.AppMenu.Registrar.RegisterWindow
```

For existing DBusMenu applications, the helper transparently proxies their DBusMenu interface onto the Unity bus and uses the same registrar path.

This registrar normalization replaces the superseded `_GTK_UNIQUE_BUS_NAME` rewrite/cache-invalidation design. It removes the first-focus race: supported Host applications must receive their global menu and HUD without switching focus away and back.

The accepted implementation does not use:

- `_GTK_UNIQUE_BUS_NAME` rewriting;
- `UnregisterWindow` cache-refresh tricks;
- fake focus changes;
- direct per-window HUD `AddSources` / `SetWindowContext`; or
- application-specific menu/HUD rules.

HUD follows the same native AppMenu DBusMenu registration as the global menu, so both features share one generic registration mechanism.

Unity WindowStack `debian-*` application identity is the scope gate for Host windows. The relay does not require an `_BAMF_DESKTOP_FILE` X property to be present; that requirement was proven too strict with Host Caja and removed.

The compatibility rule is protocol-based: any mirrored Host application that exposes a supported GMenu/GAction or DBusMenu interface is eligible. Applications that expose neither protocol remain normal Host applications but do not receive a fabricated menu/HUD.

Representative accepted compatibility includes Blueman Manager, Caja, Chromium, Visual Studio Code, GDebi, GIMP, GUFW, Deskflow, Evolution, Shutter, Synaptic and system-config-printer. This list describes the current inventory; it is not a code whitelist.

Final acceptance included normal Host launches with no focus bounce, with representative testing on Caja, Chromium and Visual Studio Code.

Full protocol design and maintenance rules: [`UNITY-HOST-MENU-HUD.md`](UNITY-HOST-MENU-HUD.md).

## Correct child handling

Do **not** use:

```python
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
```

Ignored `SIGCHLD` dispositions can be inherited by launched Electron/Chromium/Firefox-style applications and cause their `waitpid()` calls to fail with `ECHILD`.

Use a real child reaper in the launcher instead. The BAMF launch gate does not change this requirement.

---

# 5. XSMP / ICE integration

Host applications receive:

```text
SESSION_MANAGER
ICEAUTHORITY=$HOME/.ICEauthority
```

Xenial MATE writes its ICE/XSMP cookies to `~/.ICEauthority`, while current Debian libICE may otherwise default to `/run/user/$UID/ICEauthority`.

With the explicit `ICEAUTHORITY`, XSMP-capable host applications such as Debian Firefox ESR acquire an `SM_CLIENT_ID` and close normally during MATE logout.

This behavior is confirmed for the MATE path. The Unity bridge forwards the same relevant environment values, but the full XSMP logout case has not been separately revalidated for Unity.

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

Host Caja is started once in the MATE Desktop autostart phase.

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

Confirmed runtime uses Debian `/usr/bin/caja` with host root `/`.

Confirmed working in MATE:

- desktop icons and desktop right-click
- Home / Computer / Trash
- Places menu and folder launching
- additional Caja windows
- USB insertion/visibility/eject
- normal logout/login

Both Debian and Xenial GVfs stacks may run simultaneously. Debian Caja uses Debian GVfs; Xenial-native applications may continue using Xenial GVfs.

Full details: [`HOST-CAJA.md`](HOST-CAJA.md).

---

# 7. Host Caja private XDG application view

The accepted host-Caja application view is:

```text
/var/lib/maverick-host-apps/caja-xdg/applications
```

It is maintained by the same existing app synchronizer. No additional daemon, watcher, or separate synchronizer was added.

## Debian entries

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

This restores `(Host)` labels in `Open With` and file-context application menus without modifying Debian's real `.desktop` files.

## Xenial-native MIME handlers

The same private view also contains Xenial-native handlers with unique `xenial-` desktop IDs. The confirmed GDebi case is:

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

`/usr/local/bin/xenial-run` locates the already-running Xenial MATE schroot session through the live `mate-panel`, imports its graphical/session environment, and executes through `schroot --run-session`.

This helper remains MATE-specific until a demonstrated Unity host->legacy-native MIME-handler requirement exists.

Full labeling policy: [`HOST-APP-LABELING.md`](HOST-APP-LABELING.md).

---

# 8. Storage, audio and graphical helpers

## Storage

Do not reintroduce `udiskie` or a UDisks1 compatibility layer.

MATE uses host UDisks2 with Debian Caja/Debian GVfs for host file management while Xenial GVfs remains available to Xenial-native applications.

Unity uses native Xenial Nautilus/GVfs against the same host UDisks2 backend. Tested Unity behavior includes removable USB media and fixed-volume PolicyKit authentication/mounting.

## Audio

Xenial audio clients use Debian PipeWire-Pulse through:

```text
PULSE_SERVER=unix:/run/user/$UID/pulse/native
```

## PolicyKit and Bluetooth

Debian's graphical PolicyKit agent is used for both accepted Xenial desktop sessions.

Current host helper policy:

```text
ubuntu-mate-xenial  -> Debian polkit-mate agent + Debian Blueman
ubuntu-unity-xenial -> Debian polkit-mate agent
```

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

The tested final desktop package set includes the core Unity session plus Ubuntu defaults/integration needed for a usable desktop:

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

Full replication details: [`XENIAL-UNITY.md`](XENIAL-UNITY.md).

---

# 10. Modern applications belong on Debian

Current applications should normally be installed on the Debian host and exposed through the bridge.

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

Confirmed baseline:

- `intel_pstate` scales from roughly 400 MHz idle to about 3.6 GHz under load
- one-minute four-thread load ended around 50 C with no observed frequency collapse
- Debian uses i915 + Xorg modesetting
- direct rendering is active on Debian and Xenial
- no llvmpipe fallback was observed
- memory and swap pressure were absent during testing
- settled idle CPU was typically about 98–99.5% idle
- Marco compositor is disabled while Compton provides the GLX compositor in MATE

No generic performance tweaks are accepted or required at this time.

See [`PERFORMANCE-BASELINE.md`](PERFORMANCE-BASELINE.md).

---

# 12. Current confirmed state

## MATE

- Debian 13 normal boot to LightDM
- Xenial MATE login directly on physical X11
- normal logout, shutdown and reboot
- Debian Caja desktop ownership and browsing
- desktop icons/right-click/Home/Computer/Trash
- USB insertion/eject and removable-storage visibility
- Debian and Xenial GVfs coexistence
- PipeWire-Pulse audio and MATE volume control
- Debian graphical PolicyKit prompts
- Debian Blueman applet
- automatic Host application mirroring and `(Host)` labels
- host Caja `(Host)` labels and dual Debian/Xenial MIME handlers
- host/native duplicate application coexistence
- XSMP/ICE graceful logout for capable host apps
- cgroup fallback cleanup for remaining host apps
- real `SIGCHLD` child reaper
- healthy CPU/GPU/memory/thermal performance baseline

## Unity

- separate fresh `/srv/xenial-unity` root
- Debian LightDM -> Ubuntu Unity 16.04 login
- Unity 7/Compiz directly on physical X11
- native Xenial user-Upstart startup and session D-Bus
- expected Ambiance/Ubuntu theme assets
- wallpaper and Appearance/Desktop Background integration
- populated application/search lenses
- native Xenial Nautilus desktop/file management
- automatic Host application mirror visible through `/host-xdg`
- Debian Host applications launching through the existing bridge
- final global BAMF matching: authoritative mirrored identity + early real-PID registration + no mirrored `StartupWMClass`
- duplicate/replacement launcher icons resolved across tested GTK, Electron, wrapper and privileged Host applications
- accepted universal Host global-menu/HUD protocol bridge for supported GMenu/GAction and DBusMenu exporters
- supported Host global menus and HUD available on first focus with no focus-switch/cache workaround
- representative final menu/HUD acceptance with Caja, Chromium and Visual Studio Code
- removable USB media through Xenial GVfs + Debian UDisks2
- fixed-volume authentication through Debian polkitd + Debian graphical polkit-mate agent
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

Keep MATE-specific and Unity-specific behavior separate where their native desktop architecture differs. Generalize only infrastructure that has actually proved common, such as the Host application mirror/launcher and Debian hardware-facing services.

For Unity Host menu/HUD work, preserve the accepted protocol-based bridge. Do not reintroduce application whitelists, `_GTK_UNIQUE_BUS_NAME` rewriting, focus bouncing, cache-invalidating `UnregisterWindow` tricks, or direct per-app HUD registration.

The latest accepted GitHub files are the source of truth for implementation details. If older handoffs or conversation history disagree with current accepted documentation or observed behavior, prefer the current evidence and documentation.
