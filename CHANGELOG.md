# Changelog

Accepted project changes are recorded here after they are tested and approved.

## 2026-09-04

- Established Debian 13 + Ubuntu MATE 16.04 Xenial as the current architecture.
- Confirmed physical-X11 MATE session through schroot.
- Confirmed native Xenial GVfs/host UDisks2 removable-media integration.
- Confirmed Xenial audio through Debian PipeWire-Pulse.
- Added Debian graphical PolicyKit and current Blueman integration.
- Added Debian host-application mirroring and `host-run` execution bridge.
- Made the host launcher session-scoped rather than permanently enabled.
- Added XSMP/ICE integration using `SESSION_MANAGER` and `~/.ICEauthority`.
- Replaced `SIGCHLD=SIG_IGN` with a real child reaper so Electron/Firefox-style applications keep normal `waitpid()` behavior.
- Removed recursive `/run` binding from the schroot design; only required runtime paths are exposed.
- Confirmed normal login, logout, shutdown and reboot after stale schroot cleanup.
- Confirmed Discord works when installed on the Debian host and exposed through the bridge rather than installed inside Xenial.
- Added and tested generic `(Host)` suffixing for all mirrored Debian application names, including localized `Name[...]` entries while leaving desktop-action labels unchanged.
- Confirmed the existing host-app synchronizer/path watcher applies `(Host)` automatically to both current and future mirrored applications with no additional service or daemon.
- Completed a performance baseline on the reference iMac18,1: hardware acceleration is active on both Debian and Xenial, idle desktop overhead is negligible, CPU scaling reaches ~3.6 GHz under load, and a one-minute full-load test ended at 50 C without observed throttling. No performance-specific tuning changes were required.
- Moved primary Caja file management and desktop ownership from Xenial Caja 1.12 to Debian Caja 1.26 through the existing `host-run` bridge.
- Added `/srv/xenial/usr/local/bin/caja` as a generic wrapper to route normal Xenial Caja invocations to Debian `/usr/bin/caja` while keeping Xenial `/usr/bin/caja` available as a rollback path.
- Removed `filemanager` from MATE's required-component list and started Debian Caja in the Desktop autostart phase with `--force-desktop --no-default-window`, avoiding misuse of the fire-and-forget `host-run` client as a required MATE component.
- Confirmed Debian Caja desktop ownership via `/proc` (`exe: /usr/bin/caja`, `root: /`) and tested desktop icons, desktop right-click, Home/Computer/Trash, Places, folder launching, additional Caja windows, USB insertion/eject, and normal logout/login.
- Retained Xenial GVfs for Xenial-native applications while Debian Caja uses the Debian GVfs stack; both stacks are intentionally allowed to coexist.
- Added a second generated XDG application view at `/var/lib/maverick-host-apps/caja-xdg/applications` for Debian Caja. It preserves original Debian desktop IDs, `Exec=` commands, MIME associations and metadata while appending `(Host)` to main and localized application names.
- Scoped host Caja to `XDG_DATA_DIRS=/var/lib/maverick-host-apps/caja-xdg:/usr/local/share:/usr/share`, restoring `(Host)` labels in `Open With` and file-context application menus without modifying Debian's real `.desktop` files.
- Reused the existing host-app synchronizer and path watcher to maintain both the Xenial `debian-*` launcher mirror and the host-Caja XDG view; no additional daemon or watcher was introduced.
- Extended the host-Caja XDG view to include Xenial-native MIME handlers with unique `xenial-` desktop IDs so host and Xenial applications can coexist in Caja's `Open With` menus.
- Added generic `/usr/local/bin/xenial-run`, which locates the already-running Xenial MATE schroot session from the live `mate-panel` process, imports its graphical/session environment, and launches Xenial commands with `schroot --run-session`.
- Confirmed the dual-handler case with GDebi: `gdebi.desktop` remains the Debian-host handler labeled `(Host)`, while `xenial-gdebi.desktop` exposes the Xenial-native installer for the same `application/vnd.debian.binary-package` MIME type.
- Confirmed both host and Xenial GDebi choices are visible again in Debian Caja's `.deb` `Open With` menu.
- Added a separate fresh Xenial Unity root at `/srv/xenial-unity`, using its own `xenial-unity-desktop` schroot profile while continuing to share `/home` and matching UID/GID values.
- Confirmed Xenial Unity 7 runs directly on the same physical X11 `:0` display through Debian LightDM/Xorg without a VM, nested X server, or remote desktop layer.
- Established the native Unity startup contract through Xenial `/etc/X11/Xsession` and Xenial user Upstart rather than launching `gnome-session` directly.
- Added a complete system `PATH` to the Unity wrapper so Xenial Upstart can find `/sbin/initctl` and `upstart-udev-bridge` under Debian LightDM.
- Kept Unity's native Xenial user-Upstart D-Bus separate from Debian's systemd user bus; the live Compiz environment confirmed the expected native Unity session identity and abstract Xenial session bus.
- Confirmed hardware-accelerated Intel/Mesa rendering in the live Unity session with no llvmpipe fallback.
- Corrected the initially under-complete Unity package set by adding `ubuntu-settings`, `light-themes`, `unity-lens-applications`, `unity-lens-files`, `zeitgeist-core`, `iso-codes`, and `unity-control-center`; this restored normal Ambiance theming, eliminated observed Compiz ghosting, populated the Dash, and restored Appearance/Desktop Background integration.
- Kept native Xenial Nautilus as the Unity desktop/file manager instead of applying the MATE-specific Debian Caja takeover.
- Extended the existing `/host-xdg` launcher mirror into Unity and reused the same session-scoped `maverick-host-launcher.service` rather than creating a Unity-specific bridge.
- Installed the normal Xenial `python` package in the Unity root because `host-run` imports Python 2 `json`; `python-minimal` alone produced `ImportError: No module named json`.
- Confirmed the Unity `host-run` path reaches the Debian launcher successfully and launches Debian GUI applications from the Unity session.
- Extended the Debian graphical PolicyKit helper hook to the outer `ubuntu-unity-xenial` session while leaving Debian Blueman MATE-only for now.
- Confirmed native Xenial Nautilus/GVfs can mount removable media and a fixed internal volume through Debian UDisks2; the fixed volume produced a Debian graphical PolicyKit password prompt and was mounted and browsable after authorization.
- Documented the accepted Unity build and integration in `docs/XENIAL-UNITY.md`.
- Diagnosed Unity duplicate/transient launcher icons for mirrored host applications as a BAMF matching gap affecting source launchers that do not provide `StartupWMClass`; Firefox ESR and Synaptic remained correctly matched through their existing `StartupWMClass` metadata.
- Added a generic conditional launcher rule: preserve source `StartupWMClass` when present, otherwise prepend `BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-<original>.desktop` to the mirrored launcher command.
- Added `BAMF_DESKTOP_FILE_HINT` to the environment allow-lists in both Xenial `host-run` clients and the Debian host launcher so the hint reaches the real host process.
- Confirmed the hint in the running Debian Deskflow process and confirmed the previously affected host applications now use a single correct Unity launcher icon. No per-application WM-class table or launcher hack is required.
