use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use super::WorkerError;

pub(super) fn validate_trusted_ancestors(path: &Path, name: &str) -> Result<(), WorkerError> {
    let trusted_uid = uzers::get_effective_uid();
    // Walk root-to-leaf (`Path::ancestors` yields the opposite order) so a
    // sticky root like `/tmp` is seen before the trusted user's own
    // directories beneath it, which the group-write exception below depends
    // on having already observed.
    let ancestors: Vec<&Path> = path
        .parent()
        .into_iter()
        .flat_map(Path::ancestors)
        .collect();
    let mut under_sticky_root = false;
    for ancestor in ancestors.into_iter().rev() {
        let metadata = ancestor.symlink_metadata().map_err(|error| {
            WorkerError::new(format!(
                "inspect trusted Harness worker {name} ancestor {}: {error}",
                ancestor.display()
            ))
        })?;
        let trusted_owner = metadata.uid() == trusted_uid || metadata.uid() == 0;
        let is_sticky_root = metadata.uid() == 0 && metadata.mode() & 0o1000 != 0;
        under_sticky_root |= is_sticky_root;
        // World-write always disqualifies an ancestor unless it is itself the
        // sticky root (matching `/tmp`'s own 1777 mode: its sticky bit already
        // stops anyone but a file's owner from renaming or deleting it).
        //
        // Group-write is weaker, and only forgiven once under a sticky root,
        // for every ancestor from there down that the trusted user themselves
        // own: an ambient `umask 002` is enough to leave a plain
        // `tempfile::tempdir()` group-writable (issue #1239), and rejecting
        // that made every worker-override test under a permissive umask fail
        // before reaching the fake worker it stood up. This has to reach more
        // than the sticky root's immediate children: `TMPDIR` and equivalent
        // sandboxing routinely nest a process- or lane-scoped scratch
        // directory (still trusted-user-owned, still under the same umask)
        // between the sticky root and the actual leaf tempdir, exactly as
        // this repository's own test lane does; restricting the exception to
        // one hop reopens the original bug there. `trusted_owner` above is
        // still checked unconditionally on every ancestor in the chain, so
        // the exception never crosses into a directory some other identity
        // owns - only the trusted user's own group-write policy is being
        // forgiven, matching the issue's own framing of "not writable by
        // anyone outside the trusted user's own group-write policy". This is
        // a deliberate, narrower trust boundary, not a fully closed one: even
        // a direct child lets a member of its owning group replace entries
        // *inside* it - including the worker binary - between this check and
        // the later `Command::new(&worker)` exec. Closing that gap needs
        // opening the worker by fd and exec'ing the already-open,
        // already-validated fd instead of a path (tracked in #1242).
        // Outside a sticky root, group-write on a trusted-owned ancestor
        // still disqualifies it unconditionally.
        let disqualifying_mode = if is_sticky_root {
            false
        } else {
            metadata.mode() & 0o002 != 0
                || (metadata.mode() & 0o020 != 0
                    && !(under_sticky_root && metadata.uid() == trusted_uid))
        };
        if !metadata.is_dir() || !trusted_owner || disqualifying_mode {
            return Err(WorkerError::new(format!(
                "trusted Harness worker {name} has an untrusted ancestor: {}",
                ancestor.display()
            )));
        }
    }
    Ok(())
}
