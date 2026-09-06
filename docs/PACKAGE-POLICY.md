# Package policy

Package manifests are curated architecture inputs. They are not generated from
the reference machine's `dpkg` database, because that would capture personal
applications, troubleshooting tools, obsolete experiments, and hardware-specific
packages.

## Debian host

`packages/host-integration.txt` contains only packages directly required by the
desktop bridge: schroot and LightDM integration, Caja/GVfs, PolicyKit and
Blueman helpers, Python/GObject bindings, appmenu/DBusMenu support, X11 property
inspection, and desktop-database maintenance.

Modern browsers, mail clients, office suites, development tools, and media
applications are deliberately not listed. Users install those on Debian and the
host-application synchronizer exposes them to both legacy desktops.

## Common Xenial layer

`packages/chroot-common.txt` provides certificates, locale generation, session
D-Bus support, and Python 2 for the Xenial `host-run` client.

## Unity

`packages/unity-core.txt` contains the shell, session, native Nautilus, settings,
themes, indicators, HUD, lenses, and search integration.

`packages/unity-essentials.txt` supplies a deliberately small native fallback:

- GNOME Terminal
- gedit
- Eye of GNOME
- Evince
- File Roller
- GNOME Calculator

A terminal and editor are necessary for diagnosis when the Host bridge is not
available. The other small utilities make a fresh desktop usable without adding
obsolete network-facing applications.

## MATE

`packages/mate-core.txt` contains the MATE shell, Marco, panel, settings,
themes, classic utilities, the tested Compton compositor, and native Caja/GVfs
as a rollback path. Debian Caja remains the normal file manager after the
integration layer is installed. The integration supplies its MATE session
setting as a system schema default; it does not copy a reference user's dconf
database.

## Explicit exclusions

The manifests do not directly install:

- `ubuntu-desktop` or `ubuntu-mate-desktop`;
- Xenial kernels, firmware, Xorg servers, or display managers;
- Xenial NetworkManager, UDisks, UPower, BlueZ, or PulseAudio services;
- Xenial update managers, software stores, or release-upgrade tools; or
- legacy browsers, mail clients, office suites, and media suites.

Some desktop packages may depend on client libraries or service packages with
similar names. Package presence does not transfer runtime service ownership away
from Debian, and persistent `policy-rc.d` prevents package maintenance from
starting system daemons inside either root.
