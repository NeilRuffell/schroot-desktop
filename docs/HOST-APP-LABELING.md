# Host application labeling

Schroot Desktop exposes modern Debian applications inside the Xenial desktop menus/Dash through the existing host-application mirror and `host-run` bridge.

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

The relevant base rewrite is:

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

## Desktop actions are deliberately excluded from renaming

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

This keeps the execution-side indicator visible regardless of which translated application name the desktop chooses.

## Automatic handling of future host applications

The existing systemd path watcher already runs the synchronizer when Debian application launchers change:

```text
/etc/systemd/system/maverick-host-app-sync.path
```

Therefore the normal flow for newly installed host applications is:

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
Unity/BAMF matching metadata is handled generically
        ↓
application appears in the Xenial desktop
```

No additional runtime daemon or watcher is required.

## Unity launcher / BAMF matching

Unity uses BAMF to associate a running application window with the `.desktop` launcher that started it. The project intentionally changes mirrored Debian desktop IDs to unique `debian-*` IDs so host and Xenial-native launchers can coexist.

Testing showed two classes of host launchers:

```text
source has StartupWMClass
    -> existing BAMF matching works

source lacks StartupWMClass
    -> the debian-* desktop ID can no longer be inferred reliably
    -> Unity may show a temporary launcher icon plus a second running-app icon
```

Confirmed working examples with native matching metadata were:

```text
Firefox ESR:
  StartupWMClass=firefox-esr
  WM_CLASS second value=firefox-esr

Synaptic:
  StartupWMClass=synaptic
  WM_CLASS second value=Synaptic
```

Deskflow provided the confirmed no-`StartupWMClass` case:

```text
WM_CLASS="deskflow", "Deskflow"
_GTK_APPLICATION_ID=org.deskflow.deskflow
mirrored ID=debian-org.deskflow.deskflow.desktop
```

The accepted generic fix is **not** to synthesize per-application `StartupWMClass` values. Instead, the synchronizer preserves source `StartupWMClass` metadata when present and, only when it is absent, adds BAMF's desktop-file ownership hint to the mirrored launch command:

```text
BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-<original>.desktop
```

For example:

```ini
Exec=/usr/bin/env BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-org.deskflow.deskflow.desktop /usr/local/bin/host-run deskflow
```

The path is intentionally the path visible inside the Xenial desktop session, where BAMF runs.

The `host-run` client and Debian host launcher both use environment allow-lists. `BAMF_DESKTOP_FILE_HINT` must therefore be forwarded by all of these generic bridge components:

```text
/srv/xenial/usr/local/bin/host-run
/srv/xenial-unity/usr/local/bin/host-run
/usr/local/libexec/maverick-host-launcher
```

The forwarded value was confirmed in the real Debian Deskflow process environment:

```text
BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-org.deskflow.deskflow.desktop
```

After this generic rule was applied, the previously affected host applications tested in Unity associated with a single launcher icon instead of creating duplicate/transient launcher entries. Existing applications with valid `StartupWMClass`, including Firefox ESR and Synaptic, remain on their original matching path.

Do not add application-specific `StartupWMClass` tables or per-app launcher fixes for this problem. Future mirrored host applications inherit the conditional BAMF rule automatically through the existing synchronizer.

## Host Caja `Open With` and file-context menus

Once Debian Caja became the primary file manager and desktop owner, its `Open With` menus no longer read the Xenial `debian-*` mirror. Caja is a Debian process, so without an override it reads the host's normal application database and shows unmodified names such as `Firefox ESR` or `Discord`.

The real Debian `.desktop` files are intentionally **not** renamed. Instead, the same synchronizer also maintains a private host-Caja XDG application view:

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

To let both coexist in host Caja, the same synchronizer adds Xenial entries with unique `xenial-` desktop IDs:

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
Xenial desktop mirror:
  desktop ID           -> prefix filename with debian-
  main Name=           -> append " (Host)"
  localized Name[]=    -> append " (Host)"
  desktop-action Name= -> preserve
  Exec=                -> wrap with host-run
  StartupWMClass       -> preserve when supplied by source
  if no StartupWMClass -> prepend BAMF_DESKTOP_FILE_HINT for the debian-* file
  TryExec=             -> remove
  DBusActivatable=     -> force false
  OnlyShowIn=          -> remove
  NotShowIn=           -> remove
  NoDisplay=true       -> preserve
  Hidden=true          -> preserve
  Categories           -> preserve

Host-run environment bridge:
  BAMF_DESKTOP_FILE_HINT -> forward when present

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

The host-label view, Unity/BAMF launcher matching, and dual Debian/Xenial MIME-handler behavior were tested successfully on the reference system on 2026-09-04.
