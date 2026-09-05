#!/usr/bin/python3
import os
import select
import subprocess
import threading

class UnityMenuRelayManager:
    def __init__(self, uid, logpath):
        self.uid = uid
        self.logpath = logpath
        self.lock = threading.Lock()
        self.process = None
        self.address = None

    def _log(self, text):
        try:
            with open(self.logpath, "ab", buffering=0) as log:
                log.write(("[unity-menu] %s\n" % text).encode("utf-8", "replace"))
        except Exception:
            pass

    def configure(self, address, launch_env):
        if not address:
            return

        with self.lock:
            if self.process is not None and self.process.poll() is None:
                return

            env = os.environ.copy()
            env["DBUS_SESSION_BUS_ADDRESS"] = address
            env["MAVERICK_HOST_BUS_ADDRESS"] = (
                "unix:path=/run/user/%d/bus" % self.uid
            )
            env["XDG_RUNTIME_DIR"] = "/run/user/%d" % self.uid

            for key in ("DISPLAY", "XAUTHORITY", "LANG", "LC_ALL", "LC_CTYPE"):
                value = launch_env.get(key)
                if value:
                    env[key] = value

            # The bridge builds synthetic GTK menus; never load appmenu into it.
            env.pop("GTK_MODULES", None)
            env["UBUNTU_MENUPROXY"] = "0"

            log = open(self.logpath, "ab", buffering=0)
            proc = subprocess.Popen(
                ["/usr/local/libexec/maverick-unity-menu-bridge"],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=log,
                text=True,
                start_new_session=False,
            )
            log.close()

            ready, _, _ = select.select([proc.stdout], [], [], 3.0)
            line = proc.stdout.readline().strip() if ready else ""
            proc.stdout.close()

            if line != "READY":
                self._log("universal bridge failed to become ready")
                try:
                    proc.terminate()
                except Exception:
                    pass
                self.process = None
                return

            self.process = proc
            self.address = address
            self._log("universal GMenu/DBusMenu bridge ready")
