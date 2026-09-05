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
generic Host/BAMF identity rules are applied
        ↓
application appears in the Xenial desktop
```

No additional runtime daemon or watcher is required.

## Unity launcher / BAMF matching

Unity uses BAMF to associate a running application window with the `.desktop` launcher that started it. Schroot Desktop intentionally changes mirrored Debian desktop IDs to unique `debian-*` IDs so host and Xenial-native launchers can coexist.

The duplicate-icon failure was captured at the BAMF object level. During a failing Visual Studio Code launch, BAMF first created a startup application for:

```text
Visual Studio Code (Host)
/host-xdg/applications/debian-code.desktop
Starting=true
```

When the real Code X11 window appeared, BAMF created a **second** runtime application object instead of attaching that window to the existing Host startup application. Unity therefore displayed a temporary Host launcher icon plus a second running-app icon; the first icon later disappeared.

The bridge had already supplied the correct mirrored identity to the real window, but source `StartupWMClass` metadata could cause Xenial BAMF to reject that identity. Real examples showed why preserving host `StartupWMClass` is not reliable across the bridge:

```text
Visual Studio Code:
  source StartupWMClass=Code
  live WM_CLASS="code", "code"

GIMP 3:
  source StartupWMClass=gimp-3.0
  live WM_CLASS="gimp", "Gimp"
```

The accepted solution is fully generic and has two parts.

### 1. Every mirrored Host launcher has an authoritative desktop identity

The synchronizer prepends the mirrored Xenial-visible desktop path to generated `Exec=` lines:

```text
BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-<original>.desktop
```

For example:

```ini
Exec=/usr/bin/env BAMF_DESKTOP_FILE_HINT=/host-xdg/applications/debian-code.desktop /usr/local/bin/host-run /usr/share/code/code %F
```

This rule applies to **every** generated `debian-*.desktop`, not only launchers missing `StartupWMClass`.

Both Xenial `host-run` clients are identical and receive this value. The Debian launcher also keeps `BAMF_DESKTOP_FILE_HINT` in its environment allow-list.

### 2. Register the real Debian launch PID with Xenial BAMF before the application can create a window

The asynchronous bridge breaks BAMF's normal GIO launch-PID ancestry: Xenial starts `host-run`, while the real GUI process is later spawned by the separate Debian `maverick-host-launcher` service. Environment inheritance alone is not universal because Electron/Chromium-style applications can re-exec or otherwise discard launch environment variables.

The accepted bridge therefore restores the PID relationship explicitly:

```text
mirrored debian-*.desktop
        ↓
host-run knows the mirrored desktop path
        ↓
Debian launcher creates a stopped launch-gate process
        ↓
launcher returns that real PID
        ↓
Xenial host-run calls BAMF RegisterApplicationForPid
        ↓
PID -> /host-xdg/applications/debian-*.desktop
        ↓
host-run sends SIGCONT
        ↓
gate execs the real Debian application with the same PID
```

The stopped launch gate removes the race where a fast application could create its first X11 window before BAMF receives the PID registration. The Debian launcher still uses a real `SIGCHLD` reaper; it does **not** use `SIGCHLD=SIG_IGN`.

BAMF's registered-PID matching walks the process parent tree, so normal descendants and wrappers inherit the registered desktop identity. Runtime testing also confirmed the correct `_BAMF_DESKTOP_FILE` on Electron Visual Studio Code and on privileged GUFW after its helper/process chain detached.

### `StartupWMClass` is removed from every mirrored Host launcher

Once the bridge supplies an authoritative PID-to-desktop relationship, copied Debian `StartupWMClass` values become a weaker heuristic and can actively veto the correct Host identity. The synchronizer therefore strips `StartupWMClass=` from the main `[Desktop Entry]` of **all** generated `debian-*.desktop` files.

This does not modify Debian's real `.desktop` files and does not change Xenial-native launchers. It only applies to the generated Host mirror.

The current generic mirror pass also forces `StartupNotify=false`. This setting was present during final regression testing, but it was not sufficient by itself to solve the duplicate-icon problem; the decisive accepted behavior is authoritative PID registration plus removal of mirrored `StartupWMClass`.

The final rule is therefore:

```text
all current and future debian-* mirrors
    -> unique mirrored desktop ID
    -> BAMF_DESKTOP_FILE_HINT for that mirrored ID
    -> no mirrored StartupWMClass
    -> StartupNotify=false in the current tested mirror
    -> launch through host-run
    -> real Debian PID registered with Xenial BAMF before exec continues
```

Do not add application-specific WM-class tables, Electron exceptions, per-app launcher hacks, or a downstream BAMF patch for this problem.

Final cross-application testing in Unity showed the duplicate/replacement launcher behavior resolved across the tested Host applications, including Visual Studio Code, GIMP, Firefox ESR, Synaptic, GUFW/Firewall Configuration, and ordinary GTK host applications.

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
  BAMF identity        -> prepend mirrored BAMF_DESKTOP_FILE_HINT to every Exec=
  StartupWMClass       -> remove from generated Host mirror
  StartupNotify        -> force false in current tested mirror
  TryExec=             -> remove
  DBusActivatable=     -> force false
  OnlyShowIn=          -> remove
  NotShowIn=           -> remove
  NoDisplay=true       -> preserve
  Hidden=true          -> preserve
  Categories           -> preserve
  unprefixed shadows   -> never generate

Host-run / Debian launcher bridge:
  BAMF_DESKTOP_FILE_HINT -> forward/use as mirrored desktop identity
  DESKTOP_STARTUP_ID     -> forward when present
  real launch PID         -> register with Xenial BAMF before SIGCONT/exec
  child handling          -> real SIGCHLD reaper; never SIGCHLD=SIG_IGN

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

The shared Xenial desktop mirror contains only uniquely prefixed `debian-*.desktop` Host entries. It does not create unprefixed `Hidden=true` shadow files. A higher-priority shadow with an ID such as `simple-scan.desktop` or `synaptic.desktop` would mask the native Xenial entry of the same ID in Unity and MATE. Users can still hide either side independently with a matching `Hidden=true` override in `~/.local/share/applications`.

The host-label view, global Unity/BAMF launcher matching, and dual Debian/Xenial MIME-handler behavior were tested successfully on the reference system on 2026-09-04.
