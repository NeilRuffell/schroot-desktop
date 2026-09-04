# Debian Host Caja Integration

The reference Schroot Desktop build uses the current Debian Caja for normal file management **and for desktop ownership** while retaining the Xenial MATE shell.

## Accepted responsibility split

```text
Xenial
├── mate-session
├── mate-panel
├── Marco
├── mate-settings-daemon
├── classic GTK2 shell behavior
└── Xenial GVfs remains available for Xenial-native applications

Debian host
├── Caja 1.26
├── Caja desktop ownership
├── normal folder browsing
├── Debian GVfs used by host Caja
└── UDisks2
```

The Xenial Caja package remains installed as a rollback/fallback. Debian Caja binaries or libraries are **not** copied into Xenial, and Debian packages are not installed into the Xenial root.

## Tested host packages

```text
caja 1.26.4-1
gvfs 1.57.2-2+deb13u1
gvfs-backends 1.57.2-2+deb13u1
gvfs-fuse 1.57.2-2+deb13u1
```

## Why host Caja is not a MATE required component

Xenial MATE originally used:

```text
required-components-list:
['windowmanager', 'panel', 'filemanager', 'dock']

filemanager:
'caja'
```

Do **not** make `host-run` itself a required MATE component. `host-run` is a fire-and-forget client: it submits the launch request to the host launcher and returns. MATE could therefore interpret the required file manager as having exited and repeatedly restart it.

The accepted required-component list is:

```text
['windowmanager', 'panel', 'dock']
```

Set it from the Xenial desktop session:

```bash
gsettings set org.mate.session required-components-list \
  "['windowmanager', 'panel', 'dock']"
```

Host Caja is instead started once in the normal MATE Desktop autostart phase.

## Private host-Caja XDG application view

After moving Caja to Debian, Caja's `Open With` and file-context menus began reading Debian's normal application database directly. The applications still worked, but names such as `Firefox ESR` and `Discord` no longer carried the project's `(Host)` suffix because the real Debian `.desktop` files are intentionally left unmodified.

The accepted fix is a second generated XDG application view used **only by host Caja**:

```text
/var/lib/maverick-host-apps/caja-xdg/applications
```

It is maintained by the existing synchronizer:

```text
/usr/local/sbin/maverick-sync-host-apps
```

No additional daemon, watcher, or synchronizer was added.

For Debian entries in this Caja-specific view, each launcher keeps:

```text
original desktop-file ID
original Exec=
original MIME associations
original Categories/visibility metadata
```

but the main application names are rewritten as:

```text
Name=... (Host)
Name[locale]=... (Host)
```

Names in `[Desktop Action ...]` sections remain unchanged.

This distinction is important:

```text
Xenial menu mirror
  desktop ID  -> debian-* prefix
  Exec=       -> host-run wrapper
  Name=       -> append (Host)

Host Caja Debian view
  desktop ID  -> original Debian ID
  Exec=       -> original direct host command
  Name=       -> append (Host)
```

Keeping the original Debian desktop IDs in the Caja view preserves Debian MIME/default-application behavior, while keeping the original `Exec=` avoids routing a host Caja action back through the Xenial bridge unnecessarily.

The synchronizer also removes stale generated entries and runs `update-desktop-database` on the private application directory when available.

## Xenial-native MIME handlers in host Caja

A second issue appeared after the private Caja view was introduced: host Caja could see Debian MIME handlers but no longer offered Xenial-native handlers in `Open With`, even though both applications still appeared in the MATE panel menus.

The confirmed example was GDebi. Both Debian and Xenial provide the same desktop ID and MIME type:

```text
gdebi.desktop
MimeType=application/vnd.debian.binary-package;
```

The accepted generic fix is for the **same existing synchronizer** to add Xenial-native application entries to the private Caja view as well.

Xenial entries use unique `xenial-` desktop IDs so they can coexist with the Debian entry:

```text
gdebi.desktop
  Name=GDebi Package Installer (Host)
  Exec=gdebi-gtk %f

xenial-gdebi.desktop
  Name=GDebi Package Installer
  Exec=/usr/local/bin/xenial-run gdebi-gtk %f
```

Both entries retain their original MIME declaration, so host Caja can offer both choices for a `.deb` file.

Policy for Xenial entries in the Caja view:

```text
desktop ID           -> prefix with xenial-
main/localized Name  -> preserve Xenial name; no (Host) suffix
Exec=                -> wrap with /usr/local/bin/xenial-run
TryExec=             -> remove
DBusActivatable=     -> force false when present
MimeType=            -> preserve
Categories/metadata  -> preserve
```

This is generic for MIME-capable Xenial applications; it is not a GDebi-specific rule.

### `xenial-run`

`/usr/local/bin/xenial-run` launches a command inside the **already-running Xenial MATE schroot session** rather than creating a separate unrelated schroot session.

It finds the live Xenial `mate-panel` owned by the current user, verifies that its root is an active `/run/schroot/mount/xenial-*` session, imports that process's graphical/session environment, and then uses `schroot --run-session`.

Accepted helper:

```python
#!/usr/bin/python3

import os
import sys
from pathlib import Path

if len(sys.argv) < 2:
    print("usage: xenial-run COMMAND [ARG ...]", file=sys.stderr)
    sys.exit(2)

uid = os.getuid()
panel_pid = None

for proc in Path("/proc").iterdir():
    if not proc.name.isdigit():
        continue

    try:
        if proc.stat().st_uid != uid:
            continue

        comm = (proc / "comm").read_text().strip()
        if comm != "mate-panel":
            continue

        root = os.readlink(proc / "root")
        if root.startswith("/run/schroot/mount/xenial-"):
            panel_pid = proc.name
            session = Path(root).name
            break
    except (OSError, PermissionError):
        continue

if panel_pid is None:
    print("xenial-run: active Xenial MATE session not found",
          file=sys.stderr)
    sys.exit(1)

raw = Path(f"/proc/{panel_pid}/environ").read_bytes()
session_env = {}

for item in raw.split(b"\0"):
    if not item or b"=" not in item:
        continue

    key, value = item.split(b"=", 1)
    session_env[
        key.decode("utf-8", "surrogateescape")
    ] = value.decode("utf-8", "surrogateescape")

os.environ.clear()
os.environ.update(session_env)

os.execv(
    "/usr/bin/schroot",
    [
        "/usr/bin/schroot",
        "--run-session",
        "-c", session,
        "--preserve-environment",
        "--directory=" + os.environ["HOME"],
        "--",
        *sys.argv[1:],
    ],
)
```

Install it as executable:

```bash
sudo chmod 755 /usr/local/bin/xenial-run
```

The live Xenial session environment was confirmed to provide the required values, including:

```text
DISPLAY=:0
XAUTHORITY=$HOME/.Xauthority
DBUS_SESSION_BUS_ADDRESS=<Xenial session bus>
PULSE_SERVER=unix:/run/user/$UID/pulse/native
XDG_RUNTIME_DIR=/run/user/$UID
SESSION_MANAGER=<Xenial MATE session manager>
ICEAUTHORITY=$HOME/.ICEauthority
```

A manual launch through the active `schroot --run-session` path successfully opened Xenial GDebi. After the generated dual application view was installed and Caja was restarted, both GDebi choices were visible again in `Open With`.

No new background service or watcher was added for this feature. The existing synchronizer scans the Xenial application directories when it runs. If Xenial application launchers are later added or removed independently of a Debian launcher change, rerun `/usr/local/sbin/maverick-sync-host-apps` to refresh the Caja view.

## Xenial Caja wrapper

Create `/srv/xenial/usr/local/bin/caja`:

```sh
#!/bin/sh
exec /usr/local/bin/host-run \
  /usr/bin/env \
  XDG_DATA_DIRS=/var/lib/maverick-host-apps/caja-xdg:/usr/local/share:/usr/share \
  /usr/bin/caja "$@"
```

Then:

```bash
sudo chmod 755 /srv/xenial/usr/local/bin/caja
```

Because `/usr/local/bin` precedes `/usr/bin` in the Xenial PATH, normal Xenial calls to `caja` transparently launch Debian Caja while `/usr/bin/caja` remains available as a rollback path.

The private `XDG_DATA_DIRS` value is scoped to the host Caja process and its children. It does **not** modify Debian's normal desktop-file database globally.

## Host Caja desktop autostart

Create `~/.config/autostart/debian-caja-desktop.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Debian Caja Desktop
Exec=/usr/local/bin/host-run /usr/bin/env XDG_DATA_DIRS=/var/lib/maverick-host-apps/caja-xdg:/usr/local/share:/usr/share /usr/bin/caja --force-desktop --no-default-window
OnlyShowIn=MATE;
X-MATE-Autostart-Phase=Desktop
NoDisplay=true
```

No additional daemon or service is required. The existing session-scoped host launcher owns the Debian Caja process and cleans it up with the rest of the host-app cgroup at logout.

## Confirmed runtime

After logout/login, the desktop Caja process was confirmed as:

```text
/usr/bin/caja --force-desktop --no-default-window
```

with:

```text
exe:  /usr/bin/caja
root: /
```

That proves desktop ownership belongs to Debian Caja rather than `/srv/xenial/usr/bin/caja`.

Confirmed working:

- desktop icons
- desktop right-click
- Home / Computer / Trash
- Places menu
- double-clicking desktop folders
- additional Caja windows
- USB insertion
- USB visibility in Caja and on the desktop
- USB eject
- normal logout/login
- `Open With` and file-context application menus
- `(Host)` labels in host Caja application-choice menus
- simultaneous visibility of Debian-host and Xenial-native MIME handlers, confirmed with GDebi for `.deb` files

## GVfs coexistence

Both Debian and Xenial GVfs processes remain present after the takeover. This is intentional.

- Debian Caja uses the Debian-side GVfs stack.
- Xenial-native applications may continue using Xenial GVfs.

Do not remove or disable the Xenial GVfs stack merely because Debian Caja now owns the desktop. Change that only if a demonstrated problem justifies it.

## Design rationale

This moves the primary file-management surface to the maintained Debian host without replacing the Xenial MATE shell. The private Caja XDG view keeps application-origin labeling consistent while also preserving access to Xenial-native MIME handlers, without modifying Debian's real `.desktop` files or adding another background component.