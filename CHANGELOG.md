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
