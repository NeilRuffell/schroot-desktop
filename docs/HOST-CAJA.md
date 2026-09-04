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

For this Caja-specific view, each Debian launcher keeps:

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

Host Caja XDG view
  desktop ID  -> original Debian ID
  Exec=       -> original direct host command
  Name=       -> append (Host)
```

Keeping the original desktop IDs in the Caja view preserves Debian MIME/default-application behavior, while keeping the original `Exec=` avoids routing a host Caja action back through the Xenial bridge unnecessarily.

The synchronizer also removes stale Caja-overlay entries when their real Debian launchers disappear and runs `update-desktop-database` on the private application directory when available.

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

## GVfs coexistence

Both Debian and Xenial GVfs processes remain present after the takeover. This is intentional.

- Debian Caja uses the Debian-side GVfs stack.
- Xenial-native applications may continue using Xenial GVfs.

Do not remove or disable the Xenial GVfs stack merely because Debian Caja now owns the desktop. Change that only if a demonstrated problem justifies it.

## Design rationale

This moves the primary file-management surface to the maintained Debian host without replacing the Xenial MATE shell. The private Caja XDG view also keeps application-origin labeling consistent without modifying Debian's real `.desktop` files or adding another background component.