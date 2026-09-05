# Schroot Desktop

Run classic Ubuntu desktop userspaces directly on a modern Debian host, on the real X11 desktop — no VM, no VNC/RDP, no Xephyr, and no nested display server.

The current reference build uses:

- **Debian 13** as the real host OS
- **Ubuntu MATE 16.04 Xenial** in `/srv/xenial`
- **Ubuntu Unity 16.04 Xenial** in a separate `/srv/xenial-unity` root
- **LightDM + Xorg** from Debian
- **MATE 1.12 / Marco 1.12** from Xenial for the MATE session
- **Unity 7 / Compiz** from Xenial for the Unity session
- **Caja 1.26** from Debian for normal MATE file management and desktop ownership
- **Nautilus 3.14/3.18-era Xenial stack** for the Unity desktop/file manager
- Debian-owned kernel, graphics, networking, PipeWire, UDisks2, PolicyKit and current applications
- a `host-run` bridge so modern Debian applications appear in the Xenial desktops and execute with Debian libraries
- a generic Unity Host menu/HUD protocol bridge for supported Debian applications

## Why

The goal is a daily-driver workstation with classic Ubuntu desktop environments while keeping modern hardware support, current host applications, and a maintained Debian base.

```text
Debian 13 host
├── kernel / drivers / firmware
├── Xorg + LightDM
├── NetworkManager
├── PipeWire / WirePlumber
├── UDisks2 / UPower / polkitd
├── current Debian applications
├── Caja 1.26 + Debian GVfs for the MATE session
│
└── physical X11 display :0
       ├── schroot /srv/xenial
       │    └── Ubuntu MATE 16.04
       │         ├── mate-session
       │         ├── mate-panel
       │         ├── Marco
       │         └── mate-settings-daemon
       │
       └── schroot /srv/xenial-unity
            └── Ubuntu Unity 16.04
                 ├── Unity 7 / Compiz
                 ├── unity-settings-daemon
                 ├── ubuntu-session / user Upstart
                 └── native Xenial Nautilus
```

The two Xenial roots are deliberately independent. They share `/home` and matching UID/GID values, but their desktop packages remain isolated.

## Current status

The reference system is working with:

- normal LightDM → Xenial MATE login
- normal LightDM → Xenial Unity login
- both desktops running directly on physical X11 `:0`
- normal MATE logout, shutdown and reboot
- Debian Caja 1.26 owning the MATE desktop and handling normal folder browsing
- native Xenial Nautilus owning the Unity desktop/file-management experience
- Debian Caja + Debian GVfs + host UDisks2 removable-media integration in MATE
- Xenial Nautilus/GVfs + host UDisks2 removable/fixed-volume integration in Unity
- Xenial GVfs retained for Xenial-native applications
- Xenial audio through Debian PipeWire-Pulse
- Debian graphical PolicyKit prompts in both MATE and Unity
- Debian Blueman applet in the MATE session
- automatic mirroring of Debian application launchers into Xenial desktops
- automatic `(Host)` suffixes on all mirrored Debian application names
- simultaneous visibility of Xenial-native and Debian-host applications, including when both distributions use the same original desktop-file ID
- `(Host)` suffixes also preserved in Debian Caja `Open With` and file-context application menus through a private Caja XDG application view
- simultaneous Debian-host and Xenial-native MIME handlers in host Caja, with Xenial entries launched back into the existing Xenial MATE session through `xenial-run`
- coexistence of Xenial-native and Debian-host versions of the same application
- independent GTK3 theme selection for Unity Host applications through **Customize Look and Feel (Host)**, without exposing Xenial's incompatible Ambiance/Radiance assets in the Host theme catalog
- generic Unity global-menu/HUD integration for Host applications that expose supported GMenu/GAction or DBusMenu interfaces, with no per-app whitelist or focus-switch workaround
- XSMP/ICE integration for the established MATE host-app path
- systemd cgroup cleanup as the fallback for non-XSMP host applications
- current applications such as Discord installed on Debian and launched from Xenial
- verified hardware acceleration on the tested MATE and Unity sessions

## Documentation

The current architecture/build handoff is in:

- [`docs/CURRENT-HANDOFF.md`](docs/CURRENT-HANDOFF.md)

The tested parallel Xenial Unity build is documented in:

- [`docs/XENIAL-UNITY.md`](docs/XENIAL-UNITY.md)

The accepted Unity Host global-menu/HUD protocol bridge is documented in:

- [`docs/UNITY-HOST-MENU-HUD.md`](docs/UNITY-HOST-MENU-HUD.md)

Host Caja desktop integration, including its private XDG application view and Xenial MIME-handler bridge, is documented in:

- [`docs/HOST-CAJA.md`](docs/HOST-CAJA.md)

Host application labeling behavior is documented in:

- [`docs/HOST-APP-LABELING.md`](docs/HOST-APP-LABELING.md)

The tested performance baseline is documented in:

- [`docs/PERFORMANCE-BASELINE.md`](docs/PERFORMANCE-BASELINE.md)

The guarded audit and offline recovery procedure for orphaned schroot sessions
is documented in:

- [`docs/SCHROOT-SESSION-CLEANUP.md`](docs/SCHROOT-SESSION-CLEANUP.md)

The version-controlled integration installer for existing Xenial roots is
documented in:

- [`docs/INSTALLER.md`](docs/INSTALLER.md)

The handoff is the canonical technical checkpoint and is updated only after a troubleshooting item is finished and accepted.

## Design rules

1. Debian owns hardware, backend services, current applications and system updates.
2. Each Xenial root owns its classic desktop shell and legacy desktop behavior.
3. Keep MATE and Unity in separate roots; do not merge their package sets.
4. Debian Caja owns normal MATE file management and desktop ownership; Unity keeps native Xenial Nautilus unless a demonstrated problem justifies changing it.
5. Do not recursively bind the host `/run` into schroot; expose only the runtime paths actually required.
6. Prefer generic integration fixes over per-application hacks.
7. Install modern applications on Debian, not inside Xenial, unless there is a specific reason otherwise.
8. Mirrored host launchers use distinct desktop IDs so they cannot silently replace Xenial-native launchers.
9. Every mirrored Debian application is visibly suffixed with `(Host)` so the execution side is always unambiguous.
10. Do not generate unprefixed `Hidden=true` shadow launchers; native and Host applications coexist unless a user explicitly hides or removes one.
11. Debian's real `.desktop` files remain untouched; generated XDG views are used where desktop-specific labeling or MIME integration is required.
12. Keep the host launcher session-scoped rather than permanently enabled.
13. Treat package presence inside a Xenial root separately from runtime service ownership; Debian remains responsible for modern hardware-facing daemons.
14. In Unity, bridge supported menu protocols generically rather than adding per-app global-menu or HUD fixes.
15. Keep Unity Host GTK theming independent: use the Host `lxappearance` setting through the launcher, and do not expose Xenial theme directories to Debian applications.

## Security note

Xenial is an old userspace. This project deliberately relies on the modern Debian host for the kernel, hardware stack, backend services, and current applications, but that does **not** make Xenial a currently supported security boundary. Shared `/home`, X11 and selected runtime paths also mean the schroots are integration environments rather than strong sandboxes. Treat the Xenial userspaces accordingly.

## Hardware

The reference machine is an **iMac18,1**, but most of the architecture is hardware-independent. Hardware-specific firmware, microcode and audio work should remain on the Debian side.

## License

No license has been selected yet.
