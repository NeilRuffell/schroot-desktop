# Host application labeling

Schroot Desktop exposes modern Debian applications inside the Xenial MATE menu through the existing host-application mirror and `host-run` bridge.

To make it immediately obvious which side an application belongs to, every mirrored Debian application is visibly suffixed with:

```text
(Host)
```

Examples:

```text
Discord (Host)
Firefox ESR (Host)
Disks (Host)
Synaptic Package Manager (Host)
```

This policy applies to **all** mirrored host applications, not only cases where a Xenial-native duplicate also exists.

## Why `Host`

`(Host)` describes the architecture rather than the current distribution name. The application is executing on the real host operating system while Xenial provides the desktop userspace. The label therefore remains correct even if the host distribution changes later.

## Xenial menu implementation

No additional daemon, watcher, or per-application rule is used.

The existing synchronizer:

```text
/usr/local/sbin/maverick-sync-host-apps
```

rewrites Debian `.desktop` files before placing them below:

```text
/var/lib/maverick-host-apps/applications
```

For the Xenial menu view, the synchronizer appends ` (Host)` to the main application `Name=` and localized `Name[...]` keys in the `[Desktop Entry]` section.

The relevant logic is:

```python
output = []
section = None

for line in lines:
    stripped = line.rstrip("\r\n")
    newline = line[len(stripped):]

    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped

    if (
        section == "[Desktop Entry]"
        and (
            stripped.startswith("Name=")
            or (
                stripped.startswith("Name[")
                and "]=" in stripped
            )
        )
    ):
        key, value = stripped.split("=", 1)
        if not value.endswith(" (Host)"):
            stripped = f"{key}={value} (Host)"

    elif stripped.startswith("Exec="):
        stripped = (
            "Exec=/usr/local/bin/host-run "
            + stripped[5:]
        )
```

The suffix check makes the rewrite idempotent: rerunning the synchronizer does not produce repeated labels such as `(Host) (Host)`.

## Desktop actions are deliberately excluded

Only names in the main `[Desktop Entry]` section are changed.

Entries inside sections such as:

```ini
[Desktop Action new-window]
Name=New Window
```

remain unchanged. This prevents action labels such as `New Window`, `Private Window`, or similar application-specific actions from being misleadingly renamed.

## Localized names

Localized application names are labeled as well:

```ini
Name=Example (Host)
Name[fr]=Exemple (Host)
Name[de]=Beispiel (Host)
```

This keeps the execution-side indicator visible regardless of which translated application name MATE chooses.

## Automatic handling of future host applications

The existing systemd path watcher already runs the synchronizer when Debian application launchers change:

```text
/etc/systemd/system/maverick-host-app-sync.path
```

Therefore the flow for newly installed host applications is:

```text
install current application on Debian
        ↓
Debian .desktop file appears/changes
        ↓
existing path watcher triggers synchronizer
        ↓
launcher receives unique debian-* desktop ID
        ↓
main display name receives (Host)
        ↓
Exec= is wrapped with host-run
        ↓
application appears in Xenial MATE menu
```

No additional runtime component was introduced for this feature.

## Host Caja `Open With` and file-context menus

Once Debian Caja became the primary file manager and desktop owner, its `Open With` menus no longer read the Xenial `debian-*` mirror. Caja is a Debian process, so without an override it reads the host's normal application database and shows unmodified names such as `Firefox ESR` or `Discord`.

The real Debian `.desktop` files are intentionally **not** renamed. Instead, the same synchronizer now also maintains a private host-Caja XDG application view:

```text
/var/lib/maverick-host-apps/caja-xdg/applications
```

For Debian applications, that view differs from the Xenial menu mirror:

```text
Xenial menu view
  desktop IDs         -> debian-* prefix
  Exec=               -> host-run wrapper
  Name=/Name[locale]  -> append (Host)

Host Caja Debian view
  desktop IDs         -> original Debian IDs
  Exec=               -> original direct host command
  Name=/Name[locale]  -> append (Host)
```

Keeping the original desktop IDs and `Exec=` lines in Caja's private view preserves native Debian MIME/default-application behavior while restoring the `(Host)` labels in Caja's application-choice menus.

Host Caja is launched with:

```text
XDG_DATA_DIRS=/var/lib/maverick-host-apps/caja-xdg:/usr/local/share:/usr/share
```

This environment is scoped to Caja; Debian's normal application database remains untouched.

## Xenial-native handlers in host Caja

The Caja-only view must contain more than Debian applications. Otherwise host Caja loses Xenial-native MIME handlers even though those applications still appear normally in the MATE panel menus.

The confirmed example was `.deb` handling. Debian and Xenial both provide:

```text
gdebi.desktop
MimeType=application/vnd.debian.binary-package;
```

To let both coexist in host Caja, the same synchronizer now adds Xenial entries with unique `xenial-` desktop IDs:

```text
Debian:
  gdebi.desktop
  Name=GDebi Package Installer (Host)
  Exec=gdebi-gtk %f

Xenial:
  xenial-gdebi.desktop
  Name=GDebi Package Installer
  Exec=/usr/local/bin/xenial-run gdebi-gtk %f
```

The Xenial entry keeps its original MIME declarations and visible name, but `Exec=` is routed through `/usr/local/bin/xenial-run` into the already-running Xenial MATE schroot session.

This preserves the origin convention consistently:

```text
Debian-host application  -> name carries (Host)
Xenial-native application -> original name, no suffix
```

and restores simultaneous host/native choices in Caja's `Open With` menus without modifying either distribution's real `.desktop` files.

The existing synchronizer scans Xenial application directories whenever it runs. No new watcher was added; if Xenial application launchers change independently, rerun `/usr/local/sbin/maverick-sync-host-apps` to refresh the Caja view.

## Current launcher policy

```text
Xenial menu mirror:
  desktop ID           -> prefix filename with debian-
  main Name=           -> append " (Host)"
  localized Name[]=    -> append " (Host)"
  desktop-action Name= -> preserve
  Exec=                -> wrap with host-run
  TryExec=             -> remove
  DBusActivatable=     -> force false
  OnlyShowIn=          -> remove
  NotShowIn=           -> remove
  NoDisplay=true       -> preserve
  Hidden=true          -> preserve
  Categories           -> preserve

Host Caja Debian entries:
  desktop ID           -> preserve original ID
  main Name=           -> append " (Host)"
  localized Name[]=    -> append " (Host)"
  desktop-action Name= -> preserve
  Exec=                -> preserve original host command
  MIME/default-app IDs -> preserve

Host Caja Xenial entries:
  desktop ID           -> prefix filename with xenial-
  main/localized Name  -> preserve
  Exec=                -> wrap with xenial-run
  TryExec=             -> remove
  DBusActivatable=     -> force false when present
  MimeType=            -> preserve
```

The host-label view and dual Debian/Xenial MIME-handler behavior were tested successfully on the reference system on 2026-09-04.