# Schroot Desktop

Run a classic Ubuntu MATE userspace directly on a modern Debian host, on the real X11 desktop — no VM, no VNC/RDP, no Xephyr, and no nested display server.

The current reference build uses:

- **Debian 13** as the real host OS
- **Ubuntu MATE 16.04 Xenial** in `/srv/xenial`
- **LightDM + Xorg** from Debian
- **MATE 1.12 / Caja 1.12 / Marco 1.12** from Xenial
- Debian-owned kernel, graphics, networking, PipeWire, UDisks2, PolicyKit and current applications
- a `host-run` bridge so modern Debian applications appear in the Xenial MATE menus and execute with Debian libraries

## Why

The goal is a daily-driver workstation with the classic GTK2-era Ubuntu/MATE desktop model while keeping modern hardware support, current host applications, and a maintained Debian base.

```text
Debian 13 host
├── kernel / drivers / firmware
├── Xorg + LightDM
├── NetworkManager
├── PipeWire / WirePlumber
├── UDisks2 / UPower / polkitd
├── current Debian applications
│
└── physical X11 display :0
       ↓
   schroot /srv/xenial
       ↓
Ubuntu MATE 16.04
├── mate-session
├── mate-panel
├── Caja
├── Marco
└── classic GTK2 desktop
```

## Current status

The reference system is working with:

- normal LightDM → Xenial MATE login
- normal logout, shutdown and reboot
- native Caja USB insertion/eject through Xenial GVfs + host UDisks2
- Xenial audio through Debian PipeWire-Pulse
- MATE volume control
- Debian graphical PolicyKit prompts
- Debian Blueman applet
- automatic mirroring of Debian application launchers into MATE
- coexistence of Xenial-native and Debian-host versions of the same application
- XSMP/ICE integration so compliant host applications close normally during MATE logout
- systemd cgroup cleanup as the fallback for non-XSMP host applications
- current applications such as Discord installed on Debian and launched from the Xenial desktop

## Documentation

The current architecture/build handoff is in:

- [`docs/CURRENT-HANDOFF.md`](docs/CURRENT-HANDOFF.md)

That document is the canonical technical checkpoint and is updated only after a troubleshooting item is finished and accepted.

## Design rules

1. Debian owns hardware, backend services, current applications and system updates.
2. Xenial owns the classic desktop shell and its native desktop components.
3. Do not recursively bind the host `/run` into schroot; expose only the runtime paths actually required.
4. Prefer generic integration fixes over per-application hacks.
5. Install modern applications on Debian, not inside Xenial, unless there is a specific reason otherwise.
6. Mirrored host launchers use distinct desktop IDs so they cannot silently replace Xenial-native launchers.

## Security note

Xenial is an old userspace. This project deliberately relies on the modern Debian host for the kernel, hardware stack, backend services and current applications, but that does **not** make Xenial itself a currently supported security boundary. Treat the Xenial userspace accordingly.

## Hardware

The reference machine is an **iMac18,1**, but most of the architecture is hardware-independent. Hardware-specific firmware, microcode and audio work should remain on the Debian side.

## License

No license has been selected yet.
