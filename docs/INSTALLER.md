# Integration installer

`install.sh` installs the version-controlled Schroot Desktop integration into
two existing Ubuntu 16.04 roots. It does not yet bootstrap those roots or
install their desktop package sets.

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
- does not permanently enable the session-scoped host launcher; and
- installs missing Debian packages only with the explicit
  `--install-packages` option.

## Check the reference machine

Checking is safe from a running desktop:

```bash
./install.sh check --target-user nruffell
```

The reference machine now matches the repository, including the proposed
non-recursive `/run/user/UID` correction. That correction remains pending final
MATE and reboot acceptance tests.

## Preview installation

```bash
./install.sh install --dry-run --target-user nruffell
```

## Install

Run installation from a TTY or SSH maintenance session after stopping LightDM
and confirming there are no schroot session records:

```bash
sudo ./tools/schroot-session-maintenance audit
sudo ./install.sh install --target-user nruffell
```

If Debian dependencies are missing, review them in the dry-run output and then
opt into package installation:

```bash
sudo ./install.sh install --target-user nruffell --install-packages
```

## Future bootstrap layer

The next installer phase will create fresh Xenial roots with `debootstrap`,
configure archived Ubuntu package sources, install the separately tested MATE
and Unity package sets, create matching users, and apply root-specific service
suppression. That phase should remain separate from integration updates so a
routine bridge upgrade never rebuilds or broadly modifies a working root.
