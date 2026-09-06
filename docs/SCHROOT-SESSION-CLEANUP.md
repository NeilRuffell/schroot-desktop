# Schroot session cleanup and runtime-mount correction

## Confirmed failure mode

The reference machine accumulated 17 recorded schroot sessions while only one
Unity desktop was active. Sixteen records had no processes, but every recorded
tree had 29 mounts after boot recovery.

This is not 17 running desktops. It is a session lifecycle failure:

1. A MATE or Unity login creates an automatic schroot session.
2. The profile recursively bind-mounts `/run/user`.
3. This imports dynamic GVfs and document-portal FUSE mounts below the user's
   runtime directory.
4. Teardown fails to retire some session mount trees and records.
5. `/etc/default/schroot` uses `START_ACTION="recover"`, so `schroot.service`
   reconstructs every retained session tree at the next boot.

The broad `/run` recursive bind was removed earlier, but the narrower
`/run/user` recursive bind retains the same class of dynamic-submount problem.

## Proposed corrective mount

For the single configured desktop user, bind only that user's runtime directory
and do not recursively clone its child mounts:

```text
/run/user/UID /run/user/UID none rw,bind 0 0
```

This exposes the host-launch socket, Pulse socket, and other ordinary runtime
files while excluding the separately mounted `gvfs` and `doc` FUSE trees.
`config/schroot/xenial-desktop.fstab.in` is the source template for both the
MATE and Unity profiles. It becomes accepted configuration only after the
login/logout and reboot tests below pass.

## Read-only audit

The audit is safe to run from the active desktop:

```bash
./tools/schroot-session-maintenance audit
```

Run it with `sudo` when authoritative visibility into every process is needed:

```bash
sudo ./tools/schroot-session-maintenance audit
```

## Offline repair

Do not switch from Unity to MATE before repairing the lifecycle. That creates
another automatic session.

Save all work, then open an SSH connection from another machine or switch to a
text console with `Ctrl`+`Alt`+`F3`. From that independent terminal:

```bash
cd /path/to/schroot-desktop
sudo systemctl stop lightdm
sudo ./tools/schroot-session-maintenance audit
sudo ./tools/schroot-session-maintenance repair --apply
sudo ./tools/schroot-session-maintenance audit
sudo systemctl start lightdm
```

The repair command:

- refuses to run while LightDM is active;
- refuses to run if a managed session still contains processes;
- backs up both schroot mount profiles below
  `/var/backups/schroot-desktop/TIMESTAMP`;
- replaces only the recognized recursive `/run/user` rule;
- asks schroot to end zero-process MATE and Unity sessions normally; and
- never force-unmounts filesystems or deletes session records directly.

If normal teardown fails, leave LightDM stopped and retain the exact error. Do
not improvise recursive or lazy unmount commands; inspect the remaining mount
tree before deciding on a second-stage recovery.

## Acceptance test

After repair, test the lifecycle in this order:

1. Start LightDM and log into Unity.
2. Confirm the audit reports one active session.
3. Log out to the greeter.
4. From the TTY or SSH connection, confirm the audit reports zero sessions.
5. Repeat the same login/logout check with MATE.
6. Reboot and confirm no orphan session is recovered.

Expected steady state:

```text
logged out: 0 schroot sessions
logged in:  1 active schroot session
```
