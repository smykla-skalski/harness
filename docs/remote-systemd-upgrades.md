# Remote daemon systemd upgrades

This runbook covers the Linux systemd lifecycle for a production Harness remote daemon. Run lifecycle commands as root, and identify the deployment by its systemd unit name.

## Install and upgrade are different operations

Use `harness-systemd install` for the first installation and for an idempotent check of that installation. Installation creates the hardened unit and its environment file, records the root-owned controller/daemon release pair, and starts `harness-daemon remote serve`. It is not a binary upgrade command.

Use `harness-systemd upgrade` when replacing the daemon binary used by an existing unit. The candidate is the new `harness-daemon` executable to validate and install; the target is the executable path owned by the installed service. A typical unattended invocation is:

```bash
sudo /usr/local/bin/harness-systemd upgrade \
  --candidate-path /path/to/new/harness-daemon \
  --binary-path /usr/local/bin/harness-daemon \
  --json
```

Always execute the controller path recorded by `harness-systemd install`. Never invoke the new daemon candidate with `sudo`; the controller validates candidate bytes as data and rejects any controller path, controller digest, daemon path, daemon digest, release identity, or lifecycle protocol version that does not match the root-owned pair record before creating transaction state.

On a host with the Harness repo checked out, `mise run daemon:remote:deploy` builds and activates the daemon release set and then runs exactly this controller upgrade against the activated binary. Forward `--dry-run` to report the transaction without mutating anything, or `--unit NAME` for a non-default unit. It never rotates the controller: a newer `harness-systemd` still needs the `install` rotation described next.

After installing a newer trusted `harness-systemd` executable, rerun `harness-systemd install` while the lifecycle is idle to rotate the controller side of the pair record. Rotation preserves the proven unit and daemon binding, requires a strictly newer controller release, and rejects same-release, stale, or writable controller candidates. An armed transaction is never rotated: its immutable copied controller and existing recovery arm remain authoritative until recovery completes.

The compatibility routes `harness-daemon remote install-systemd|upgrade-systemd|rollback-systemd|recover-systemd|uninstall-systemd|status` sibling-exec `harness-systemd` with the original raw arguments. The daemon package does not compile or execute lifecycle implementation code.

Do not overwrite the target by hand and then restart the unit. That bypasses the database snapshot, staged SHA-256 verification, readiness checks, and automatic rollback described below.

Harness binds each normalized installed-binary path to exactly one canonical service in a durable root-owned registry. A global lifecycle lock serializes install, upgrade, rollback, recovery, and uninstall across units; each operation inventories installed, loaded, and transient service, socket, mount, and swap units and fails closed if any effective executable command phase uses the target path. Binary replacement rechecks that inventory after the managed service is inhibited and immediately before the copy.

Template units are probed through two distinct synthetic instances and must resolve to identical executable paths, search paths, fragments, drop-ins, and mount-namespace classification. The inventory covers unit files and loaded units surfaced by the systemd manager; do not introduce a dormant instance-only drop-in directory during a lifecycle transaction because an instance that is neither installed nor loaded is outside that manager inventory until activated.

The global lock serializes Harness operations, not arbitrary root-level configuration managers. Do not add, uninhibit, or rewrite systemd services during a lifecycle transaction. A unique installed-binary path per unit is the strongest isolation when external privileged automation cannot be paused.

## What an upgrade protects

An upgrade is one durable transaction. Before the candidate starts, Harness:

1. proves that the controller and installed daemon match the root-owned release pair;
2. copies the candidate into a root-only pending journal and records its SHA-256 digest without executing the candidate as root;
3. persists a root-only recovery controller and arm record, starts a repeating recovery timer, and disables the daemon's boot enablement;
4. installs and validates a durable Harness-owned start inhibitor, stops the service, then proves its control group is quiescent;
5. checkpoints and verifies SQLite, including foreign keys, then snapshots the full Harness subtree of the systemd `StateDirectory` together with the current binary, unit, and environment;
6. verifies that complete rollback generation and the staged candidate digest; and
7. preallocates real, disk-backed capacity for every restore artifact before marking the transaction rollback-ready.

Disabling the unit prevents an uncommitted candidate from starting through the boot target. The persistent inhibitor blocks manual, dependency-driven, and reboot starts while files and state are being replaced, and Harness never removes it for a controlled start. Instead, Harness temporarily shadows it with a higher-priority runtime permit whose condition is tied to the live coordinator, proves that exact effective override, starts the controlled generation, removes the permit, and revalidates the persistent inhibitor while the process runs. Coordinator death closes the permit condition immediately and reboot clears its runtime file while retaining the persistent inhibitor. Harness releases the persistent inhibitor only after a durable commit or a verified paired rollback; original enablement is restored at the same terminal boundary.

The full state snapshot includes the SQLite database and its migration state as well as configuration and other files that startup migrations can change. It is intentionally broader than a copy of `harness.db`. This allows an older binary to be restored together with the database schema and state it expects.

Harness promotes the candidate only after staging succeeds. It first starts the unit and verifies systemd readiness, a main process whose PID and restart count remain stable for the configured window, and the SHA-256 digest of that running executable. The readiness notification is sent only after database and Task Board startup completes and the HTTP router has been built. Harness then stops the candidate under the persistent inhibitor, checkpoints and integrity-checks its migrated SQLite database, flushes the state filesystem, durably records the database presence and schema seal, and performs a second verified start against that sealed state before committing the generation. Committed recovery revalidates the seal and automatically restores the paired previous generation if the new binary or migrated database cannot be trusted. The previous generation remains retained after a successful upgrade so an operator can explicitly return to it.

Process attestation requires systemd 244 or newer because Harness verifies the manager-provided `STATE_DIRECTORY` value and rejects unit or environment-file attempts to override or remove it.

If candidate startup, migration, or verification fails before the transaction commits, Harness automatically stops the candidate, restores the previous binary and full state snapshot, starts the previous service, and checks its health. A failed upgrade is still reported as a failure even when this automatic rollback succeeds.

## Backup location and permissions

Each generation is stored below `/var/lib/harness/remote-systemd/<unit>/`; `pending` is the durable uncommitted journal, `armed.json` records autonomous recovery, and `previous` is the last committed rollback generation. The exact path is reported in lifecycle JSON output. The backup root must be outside the service `StateDirectory`--normally backed by `/var/lib/private/<unit>` for the hardened dynamic-user service--so a state restore cannot overwrite its own recovery material.

The backup root and generation metadata are root-owned and accessible only to root (directory mode `0700`). Secret-bearing files keep permissions no broader than their originals. Do not change ownership, move individual files between generations, place backups inside the service state directory, or delete the last retained previous generation.

Capacity planning must allow the snapshots plus disk-backed restore reserves. Harness sums every state and binary, unit, and environment source that a restore can write, and it reserves both data blocks and filesystem inodes before live state mutation. An explicit rollback reserves both generations before its first replacement, so recovery can reverse direction even while the coordinator keeps the displaced executable inode allocated. The state and transaction store must share a filesystem, and the binary, unit, and environment targets must share a filesystem. If these checks or reserve allocation fail, Harness restarts the unchanged current generation and does not start the candidate.

Restore reserve files preallocate the transaction's measured block and inode demand, but they are not filesystem quotas. An unrelated privileged writer on the same filesystem can consume capacity after a reserve is released for restoration; deployments that require a hard capacity guarantee must isolate or quota the managed filesystems so external writers cannot race recovery.

## Explicit rollback and data loss

Use `harness-systemd rollback --confirm-data-loss` to restore the retained generation. Select the unit and review the transaction recorded by the retained upgrade JSON report before confirming it.

An explicit rollback restores the binary and the full state snapshot as a pair. It therefore discards database writes and other state changes made after that snapshot. Harness requires an explicit data-loss confirmation for a committed generation; never work around that guard by swapping only the binary. If the new service has accepted important work, preserve the current state separately and reconcile it at the application level before rolling back.

Before replacing anything, explicit rollback snapshots the current binary and full state and reserves enough capacity for both directions. After a successful rollback it rotates that displaced generation into the retained slot, so another confirmed rollback can return to it as an equally paired binary-and-state generation.

## JSON and exit behavior

Human-readable output is intended for interactive use. Request JSON when the command is run by deployment automation. The report identifies the unit and transaction, previous and candidate artifact digests, backup generation, completed checks, final outcome, and any automatic rollback result.

Exit status zero means the requested operation completed or was a verified no-op. An upgrade that failed returns nonzero even if automatic rollback made the previous service healthy again. A rollback failure is a distinct urgent outcome in the JSON report. Automation must use both the process exit status and the report outcome; it must not treat "previous service restored" as a successful upgrade.

Retain the JSON report with the deployment record. It is the safest source for the generation path and transaction identifier needed during recovery.

## Autonomous recovery after interruption

Lifecycle transactions are journaled and watched by a per-unit systemd timer. The recovery controller tries the same nonblocking operation lock as the live lifecycle command. A busy lock is a normal defer, so the timer cannot roll back an intentional candidate start. If the lifecycle process exits or is killed, the next timer tick restores the complete previous generation. On reboot the daemon remains disabled until recovery finishes.

No operator command is required to resume recovery: the repeating timer invokes the immutable copied controller directly as `recover --store-path ...`, and the timer stays installed and enabled after a transaction completes. Recovery-arm schema v3 binds the copied controller digest; schema v2 is accepted only when resuming an already-armed legacy transaction. Before arming a transaction, Harness proves that the recovery service and timer were loaded from their exact managed fragment paths without drop-ins and that the enabled timer is active. Its recovery service has `ConditionPathExists=` on the durable arm, so it is idle between transactions while remaining available across every crash boundary. Operators may still rerun a lifecycle command after investigating an interruption; it enters the identical recovery state machine before attempting a new operation.

If the durable generation rename committed before interruption, recovery verifies the committed generation and installed digest, restores enablement, and disarms without rolling back. Corrupt or mismatched recovery material fails closed: the daemon remains disabled, the timer remains armed, and evidence is retained. Failed-candidate state is kept below the root-only transaction store; retries reapply its private ownership and mode before recovery continues.

If automatic recovery reports that rollback failed:

1. stop deployment automation for that unit;
2. preserve the reported generation directory and JSON report;
3. inspect `systemctl status <unit>` and `journalctl -u <unit>`;
4. correct any external cause such as exhausted capacity, then let the still-enabled recovery timer retry the same armed transaction; and
5. verify status and remote health before re-enabling deployment automation.

`harness-systemd rollback` does not accept an arbitrary generation path and will first retry any armed recovery, so it is not an escape hatch for corrupt transaction evidence. Do not start the previous binary against a database already migrated by the candidate, edit the SQLite schema, or copy only `harness.db` out of a generation. If verified managed recovery still cannot restore service, copy the entire backup root before manual investigation and recover only a complete paired binary, unit, environment, and state generation so the original evidence remains intact.
