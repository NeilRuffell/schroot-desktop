# Unity Host global menu and HUD bridge

This document records the accepted generic integration that makes supported Debian Host applications participate in the Xenial Unity 7 global menu and HUD while the applications themselves continue to run on Debian.

The accepted implementation was validated on 2026-09-05 after the earlier GTK-only relay experiment was superseded.

---

# 1. Goal and scope

The bridge must provide Unity global-menu and HUD integration for every mirrored Host application that already exports a menu through a protocol Unity can consume.

It is deliberately **not** an application whitelist and contains no per-application menu rules.

Supported source families are:

1. **GMenuModel/GActionGroup** applications exposed through the standard X11 `_GTK_*` properties.
2. **Classic GTK menu bars** converted to GMenu/GAction by Debian's `appmenu-gtk3-module`.
3. **Legacy DBusMenu** applications that register through `com.canonical.AppMenu.Registrar`, including Qt/libdbusmenu-style exporters.

Applications that expose neither GMenu/GAction nor DBusMenu do not have a menu interface for the bridge to transport. The bridge must not fabricate application menus for them.

The Host identity gate remains generic: Unity's `com.canonical.Unity.WindowStack` must identify the XID with a mirrored `debian-*` application ID.

---

# 2. Why a protocol bridge is required

Debian Host applications run on Debian's user D-Bus:

```text
unix:path=/run/user/$UID/bus
```

The Xenial Unity session owns a separate native Xenial session bus, normally an abstract `/tmp/dbus-*` address.

Unity's panel and HUD therefore cannot directly consume menu objects exported only on Debian's user bus.

The accepted solution is to bridge menu **protocols** between those buses while keeping the real application on Debian.

Do not move the Host application itself onto the Xenial bus. Its normal environment remains:

```text
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID/bus
```

The Xenial Unity bus address is sent to the Debian launcher only as bridge-control metadata.

---

# 3. Accepted files and lifecycle

Debian files:

```text
/usr/local/libexec/maverick_unity_menu.py
/usr/local/libexec/maverick-unity-menu-bridge
```

`maverick_unity_menu.py` is imported by the existing Debian host launcher. It starts one `maverick-unity-menu-bridge` helper for the active Unity session and waits for an explicit `READY` handshake before considering the bridge available.

The helper is a child of the existing session-scoped:

```text
maverick-host-launcher.service
```

No new service, permanent daemon, watcher unit, or per-app helper is added.

When the Unity session ends, the existing launcher service lifecycle removes the helper along with Host applications in the service cgroup.

The helper must start with a valid Python shebang as the first line:

```text
#!/usr/bin/python3
```

---

# 4. Debian dependencies

The accepted Debian runtime requires:

```text
appmenu-gtk3-module
gir1.2-dbusmenu-glib-0.4
gir1.2-dbusmenu-gtk3-0.4
gir1.2-gtk-3.0
```

The bridge uses PyGObject/GIO, GTK3 and libdbusmenu introspection bindings supplied by Debian.

For Unity Host launches the existing host launcher injects, generically:

```text
GTK_MODULES=appmenu-gtk-module
UBUNTU_MENUPROXY=1
```

without replacing the Host application's Debian D-Bus address.

This allows traditional GTK3 `GtkMenuShell`/`GtkUIManager` applications to expose the same GMenu/GAction surface as newer GMenu-aware GTK applications.

The bridge helper itself removes `GTK_MODULES` and sets:

```text
UBUNTU_MENUPROXY=0
```

because the helper constructs synthetic GTK menu objects internally and must not recursively apply appmenu to itself.

---

# 5. GMenu/GAction path

For each new X11 client window the helper inspects the standard properties:

```text
_GTK_UNIQUE_BUS_NAME
_GTK_APP_MENU_OBJECT_PATH
_GTK_MENUBAR_OBJECT_PATH
_GTK_APPLICATION_OBJECT_PATH
_GTK_WINDOW_OBJECT_PATH
_UNITY_OBJECT_PATH
_GTK_APPLICATION_ID
```

A Host window is eligible only after Unity WindowStack resolves its XID to a `debian-*` application ID.

The bridge can therefore support both:

- appmenu-module applications that normally expose a menubar plus `unity` action group; and
- native GtkApplication layouts that may expose separate application menu, menubar, `app`, `win`, and `unity` action groups.

For an eligible window the helper:

1. obtains remote `Gio.DBusMenuModel` objects from the Debian user bus;
2. obtains the corresponding remote `Gio.DBusActionGroup` objects;
3. combines the exported application menu and menubar into a synthetic GTK3 menu bar;
4. inserts action groups under their native prefixes: `app`, `win`, and `unity`;
5. converts that live GTK menu structure into a libdbusmenu tree with `DbusmenuGtk3.gtk_parse_menu_structure()`;
6. exports a `Dbusmenu.Server` on the **Unity session bus** at a unique per-window relay path; and
7. registers that relay path with Unity's real `com.canonical.AppMenu.Registrar.RegisterWindow` for the XID.

The GTK/libdbusmenu parser keeps menu state live rather than taking a static snapshot. Dynamic item insertion/removal and normal menu-property/action changes continue to propagate.

---

# 6. Legacy DBusMenu path

The bridge also supports applications that already speak `com.canonical.dbusmenu`.

On the Debian user bus the helper attempts to own:

```text
com.canonical.AppMenu.Registrar
```

If no Host registrar exists, the helper provides the normal registrar methods and signals so legacy Host applications have somewhere to register.

If another registrar already exists, the helper follows its existing `WindowRegistered` / `WindowUnregistered` signals and seeds itself from `GetMenus` instead of replacing it.

For each eligible `debian-*` XID, the helper creates a transparent DBusMenu proxy on the Unity bus. Method calls, properties, and DBusMenu signals are forwarded between Unity and the original Debian exporter.

The proxy includes the current DBusMenu API plus compatibility calls used by older exporters.

The relayed object is then registered with Unity through the same `RegisterWindow` path used for translated GMenu windows.

---

# 7. Why the focus-switch race is gone

The superseded GTK-only relay rewrote `_GTK_UNIQUE_BUS_NAME` after Unity had already inspected the active window. It then called `UnregisterWindow` only to invalidate Unity's stale cache. Unity rebuilt the GMenu entry only after a later BAMF active-window change, which required switching focus away and back.

That behavior is **not accepted**.

The current bridge instead normalizes Host menus onto Unity's native DBusMenu registrar path and calls:

```text
com.canonical.AppMenu.Registrar.RegisterWindow
```

for the actual XID after the relayed DBusMenu object is ready on the Unity bus.

Unity's registrar path immediately updates the active window after registration. The first focused Host window therefore receives its global menu without a focus bounce.

Do not reintroduce:

- `_GTK_UNIQUE_BUS_NAME` rewriting;
- `UnregisterWindow` cache-invalidation tricks;
- fake focus changes;
- per-app panel refresh hacks.

---

# 8. HUD integration

The accepted bridge does **not** separately call HUD `AddSources` for each application.

Unity HUD already consumes DBusMenu window registration through the AppMenu registrar path. Because both translated GMenu applications and native DBusMenu applications end up registered through `RegisterWindow`, the same generic registration supplies both:

```text
global menu
HUD
```

This removes the earlier per-window direct HUD-source relay from the accepted implementation.

Do not restore direct `com.canonical.hud.Application.AddSources`/`SetWindowContext` integration unless a future demonstrated protocol requires it.

---

# 9. Window tracking and cleanup

The helper watches the physical X11 `_NET_CLIENT_LIST_STACKING` property and probes new windows for up to ten seconds while normal startup identity/menu properties settle.

Each XID has its own unique Unity DBusMenu relay path, avoiding collisions between applications that export common GMenu paths such as:

```text
/org/appmenu/gtk/window/0
```

When a window disappears the helper:

- removes pending state;
- unregisters the XID from Unity's registrar; and
- destroys the corresponding GMenu or DBusMenu relay.

Legacy DBusMenu registration takes priority for a window that provides it. If a legacy registration disappears, the helper may probe the same XID again for a GMenu source.

---

# 10. Integration with BAMF launcher matching

Menu/HUD transport does not replace the accepted BAMF launch identity design.

The existing stopped launch gate remains authoritative:

```text
mirrored debian-*.desktop
        ↓
BAMF_DESKTOP_FILE_HINT
        ↓
Debian launcher starts stopped gate
        ↓
Xenial host-run registers real PID with BAMF
        ↓
SIGCONT
        ↓
real Debian application execs with same PID
```

The menu helper identifies Host windows from Unity WindowStack `debian-*` application IDs. It does **not** require `_BAMF_DESKTOP_FILE` to be stamped as an X11 property on the window.

This distinction matters: a tested Host Caja window had the correct environment hint and WindowStack identity but no `_BAMF_DESKTOP_FILE` X property. Requiring that property caused the first production relay to ignore a valid Host window and was removed.

---

# 11. Accepted compatibility scope

The bridge is expected to work automatically for any mirrored Host application that exposes one of the supported menu protocols.

As of the accepted 2026-09-05 Host inventory, applications expected to participate include the relevant launchers for:

```text
Blueman Manager
Caja
Chromium
Visual Studio Code
GDebi
GIMP
GUFW
Deskflow
Evolution
Shutter
Synaptic
system-config-printer
```

Multiple desktop IDs that launch the same underlying application inherit the same behavior.

Applications without a supported global-menu source remain normal Host applications but do not gain a fabricated menu/HUD. Examples in the current inventory include terminal launchers and small dialogs/utilities that have no appropriate application menu exporter.

This compatibility list is descriptive, not a code whitelist.

---

# 12. Accepted tests

The development path proved the underlying GMenu relay with both:

- GIMP 3; and
- Debian Caja, whose menu is built with the older GtkUIManager/GtkMenuShell style.

The final universal bridge was then accepted with normal Host launches and no focus-switch workaround. Representative final acceptance included:

- Caja (Host)
- Chromium (Host)
- Visual Studio Code (Host)

The acceptance criterion is:

```text
launch normally from Unity
→ do not switch focus away/back
→ global menu works immediately when the app exposes one
→ HUD works immediately when the app exposes one
```

Per-app launch commands, app-specific relay rules, and manual cache refreshes are not part of the accepted setup.

---

# 13. Design rules

- Bridge protocols, not applications.
- Keep real Host applications on Debian's user bus.
- Treat Unity's native session bus as a separate destination bus.
- Use Unity WindowStack `debian-*` identity to scope relays to mirrored Host windows.
- Support both GMenu/GAction and DBusMenu families.
- Normalize onto Unity's native `RegisterWindow` path so panel and HUD share one registration mechanism.
- Do not require a focus change after launch.
- Do not create per-app menu maps or special cases.
- Keep the bridge inside the existing session-scoped host launcher lifecycle.
- Do not add another daemon or synchronizer.
- Preserve the existing BAMF stopped-gate PID registration and real `SIGCHLD` child reaper.
- Record only tested and accepted behavior in canonical documentation.
