# Debian Host Caja Integration

The reference Schroot Desktop build now uses the current Debian Caja for normal file management **and for desktop ownership** while retaining the Xenial MATE shell.

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

## Xenial Caja wrapper

Create `/srv/xenial/usr/local/bin/caja`:

```sh
#!/bin/sh
exec /usr/local/bin/host-run /usr/bin/caja "$@"
```

Then:

```bash
sudo chmod 755 /srv/xenial/usr/local/bin/caja
```

Because `/usr/local/bin` precedes `/usr/bin` in the Xenial PATH, normal Xenial calls to `caja` transparently launch the Debian host version while `/usr/bin/caja` remains available as a rollback path.

## Host Caja desktop autostart

Create `~/.config/autostart/debian-caja-desktop.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Debian Caja Desktop
Exec=/usr/local/bin/host-run /usr/bin/caja --force-desktop --no-default-window
OnlyShowIn=MATE;
X-MATE-Autostart-Phase=Desktop
NoDisplay=true
```

No additional daemon or service is required. The existing session-scoped host launcher owns the Debian Caja process and cleans it up with the rest of the host-app cgroup at logout.

## MATE required-components change

Xenial MATE originally used:

```text
required-components-list:
['windowmanager', 'panel', 'filemanager', 'dock']

filemanager:
'caja'
```

Do **not** make `host-run` itself a required MATE component. `host-run` returns after submitting the process to the host launcher, so MATE could interpret that as the file manager exiting and repeatedly restart it.

The accepted required-component list is:

```text
['windowmanager', 'panel', 'dock']
```

Set it from the Xenial desktop session:

```bash
gsettings set org.mate.session required-components-list \
  "['windowmanager', 'panel', 'dock']"
```

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

## GVfs coexistence

Both Debian and Xenial GVfs processes remain present after the takeover. This is intentional.

- Debian Caja uses the Debian-side GVfs stack.
- Xenial-native applications may continue using Xenial GVfs.

Do not remove or disable the Xenial GVfs stack merely because Debian Caja now owns the desktop. Change that only if a demonstrated problem justifies it.

## Design rationale

This moves the primary file-management surface to the maintained Debian host without replacing the Xenial MATE shell. It also keeps the solution aligned with the project rule of preferring generic host-side modernization over copying current libraries into the legacy userspace.