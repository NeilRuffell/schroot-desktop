# Package policy

Package manifests are curated architecture inputs. They are not generated from
the reference machine's `dpkg` database, because that would capture personal
applications, troubleshooting tools, obsolete experiments, and hardware-specific
packages.

## Debian host

`packages/host-common.txt` contains the shared schroot, LightDM, PolicyKit,
Python, D-Bus, Synaptic, and desktop-database dependencies. Host Synaptic is an
integration dependency because native Xenial Synaptic authenticates through the
host PolicyKit environment. `packages/host-mate.txt` adds
only Caja/GVfs and Blueman integration; `packages/host-unity.txt` adds only the
GObject, appmenu/DBusMenu, X11-property, and Host-theme dependencies used by
Unity. Selecting one desktop therefore does not install the other desktop's
host-side packages.

Modern browsers, mail clients, office suites, development tools, and media
applications are deliberately not listed. Users install those on Debian and the
host-application synchronizer exposes them to both legacy desktops.

## Common Xenial layer

`packages/chroot-common.txt` provides certificates, locale generation, session
D-Bus support, Python 2 for the Xenial `host-run` client, and `sudo` for the
matching administrative desktop account.

## Unity

`packages/unity-core.txt` contains the official `ubuntu-desktop` metapackage plus
explicit shell, session, native Nautilus, settings, themes, indicators, HUD,
lenses, and search integration. Installation includes the metapackage's normal
recommendations to provide the complete Xenial Unity application experience.

`packages/unity-essentials.txt` explicitly protects the essential native tools:

- GNOME Terminal
- gedit
- Eye of GNOME
- Evince
- File Roller
- GNOME Calculator
- Synaptic

A terminal and editor are necessary for diagnosis when the Host bridge is not
available. These remain required even if the metapackage changes.

## MATE

`packages/mate-core.txt` contains the official `ubuntu-mate-desktop` metapackage,
Synaptic, the MATE shell, Marco, panel, settings, themes, classic utilities, the
tested Compton compositor, and native Caja/GVfs as a rollback path. Normal
metapackage recommendations are installed. Debian Caja remains the normal file manager after the
integration layer is installed. The integration supplies its MATE session
setting as a system schema default; it does not copy a reference user's dconf
database.

## Runtime ownership

The official desktop metapackages include Xorg, hardware-service packages,
update tools, and classic applications. Their presence is intentional because
the baseline is now a complete Xenial desktop rather than a minimal shell.
Package presence does not transfer runtime ownership away from Debian.
Persistent `policy-rc.d` prevents package maintenance from starting system
daemons inside either root, the Debian Xorg/LightDM session remains outermost,
and the schroot wrappers select the host buses and runtime endpoints. Conflicting
Xenial update-notifier and graphical PolicyKit autostarts are diverted; MATE's
Xenial Blueman autostart is also diverted because the outer Debian session owns
those roles.
