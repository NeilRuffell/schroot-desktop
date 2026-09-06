# Installation acceptance

An installation is not accepted merely because package installation completed.
Run this checklist on a clean Debian 13 machine for every installer release.

## Static convergence

From a Debian maintenance session with no active schroot desktop:

```bash
sudo ./install.sh check --desktop both
sudo ./tools/schroot-session-maintenance audit
```

The integration check must report no differences. The session audit must report
no active or orphaned session records before login.

## Test each installed desktop

Log in through LightDM. Test MATE and Unity separately when both are installed.

Confirm the expected desktop shell, panel, theme, terminal, editor, file manager,
image viewer, PDF viewer, archive manager, calculator, system monitor, and normal
application menus are present.

Inside the Xenial terminal, verify administrative authentication:

```bash
sudo -k
sudo whoami
```

It must prompt for the configured Xenial password and print `root`.

Launch both **Synaptic Package Manager** and **Synaptic Package Manager (Host)**.
Each must display graphical authentication and open successfully. The native
entry manages the selected Xenial root; the `(Host)` entry manages Debian.

Confirm a representative Debian Host application launches from the desktop menu.
In Unity, verify it receives one launcher identity, its supported global menu is
available on first focus, and HUD search sees its supported actions.

Test audio playback, removable-media insertion/eject, fixed-volume PolicyKit
authentication, suspend-related desktop controls, and normal file opening.

Confirm direct rendering rather than a software renderer:

```bash
glxinfo -B
```

## Lifecycle

While logged in, the maintenance audit should show exactly one live session for
the selected desktop and no orphaned session records. Log out normally, then run
the audit again from Debian. It must show zero session records and no retained
schroot mount tree.

Finally test a complete reboot and repeat one login/logout cycle. Record package
versions and any deviation before changing the canonical handoff or changelog.
