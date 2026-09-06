# Integration installer

The installer has two deliberately separate layers:

- `bootstrap.sh` creates fresh MATE and Unity Xenial roots and installs their
  curated package manifests.
- `install.sh` installs or updates the version-controlled integration around
  existing roots.

The installer is deliberately staged this way: host integration can be made
idempotent and compared with the working reference machine before automating
the larger, network-dependent Xenial bootstrap.

## Safety model

The installer:

- supports a read-only `check` command and a non-mutating `--dry-run`;
- validates Debian 13, amd64, both root releases, and matching UID/GID values;
- refuses a real installation while any schroot session record exists;
- backs up changed existing files under `/var/backups/schroot-desktop`;
- installs only repository-owned files with explicit modes and owners;
- supplies the MATE required-component list as a system schema default without
  writing to a user's dconf database;
- does not permanently enable the session-scoped host launcher; and
- installs missing Debian or chroot packages only with the explicit
  `--install-packages` option.

For existing roots, the installer adds a project-owned Xenial EOL source under
`sources.list.d` and uses only that source for opted-in chroot package work. It
does not overwrite the root's main `sources.list`, and APT signature checking
remains enabled.

## Check the reference machine

Checking is safe from a running desktop:

```bash
./install.sh check
```

The reference machine's integration files match the repository, including the
proposed non-recursive `/run/user/UID` correction. The package audit currently
also reports any agreed baseline applications that have not yet been installed.
The mount correction remains pending final MATE and reboot acceptance tests.

## Preview installation

```bash
./install.sh install --dry-run
```

## Install

Run installation from a TTY or SSH maintenance session after stopping LightDM
and confirming there are no schroot session records:

```bash
sudo ./tools/schroot-session-maintenance audit
sudo ./install.sh install
```

If Debian dependencies are missing, review them in the dry-run output and then
opt into package installation:

```bash
sudo ./install.sh install --install-packages
```

## Bootstrap new roots

Preview the operation without changing the machine:

```bash
./bootstrap.sh plan
```

On a new Debian 13 machine where neither target root exists:

```bash
sudo ./bootstrap.sh create --apply --install-host-packages
sudo ./install.sh install --install-packages
```

Bootstrap refuses to overwrite either root path. It uses the Xenial EOL archive
without disabling signature verification, prevents package post-install scripts
from starting system services, creates a locked matching chroot account without
a private home, and keeps MATE and Unity in separate roots.

Package selection is defined in `packages/`. The manifests deliberately exclude
the oversized desktop metapackages, Xenial update/store clients, legacy browsers
and mail clients, and hardware-facing services that belong to Debian. Unity's
native essentials include a terminal, editor, image/PDF viewers, archive manager,
and calculator so a fresh session is usable even if the Host bridge needs repair.

The MATE integration also installs a system GSettings override that removes
`filemanager` from MATE's required-component list. This lets the normal Desktop
autostart own the Debian Caja launch without embedding any user's dconf database
in the project.

[Ubuntu's EOL guidance](https://help.ubuntu.com/community/EOLUpgrades)
documents moving an unchanged release codename to `old-releases.ubuntu.com`;
bootstrap follows that pattern for `xenial`, `xenial-updates`, and
`xenial-security`.

Bootstrap remains separate from integration updates so a routine bridge upgrade
never rebuilds or broadly modifies a working root.
