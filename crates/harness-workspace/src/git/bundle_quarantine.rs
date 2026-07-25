use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read as _};
use std::path::{Path, PathBuf};
use std::process::Output;
use std::str;
use std::time::Duration;

use fs2::FileExt as _;

use super::bundle_contract::{GitBundleContentLimits, bundle_pack};
use super::command::{GitCommandRunner, GitProcessLimits, stdout};
use super::repository_coordinates::GitRepositoryCoordinates;
use crate::git::{GitError, GitResult};

const QUARANTINE_DIRECTORY: &str = "harness-task-board-quarantine";
const QUARANTINE_LOCK: &str = "harness-task-board-quarantine.lock";

pub(crate) struct GitBundleQuarantine<'a> {
    coordinates: &'a GitRepositoryCoordinates,
    root: GitBundleQuarantineRoot,
    pack_hash: String,
    limits: GitBundleContentLimits,
    _lock: File,
}

impl<'a> GitBundleQuarantine<'a> {
    pub(crate) fn prepare(
        coordinates: &'a GitRepositoryCoordinates,
        bundle: &[u8],
        limits: GitBundleContentLimits,
    ) -> GitResult<Self> {
        coordinates.require_current()?;
        let pack = bundle_pack(bundle).ok_or_else(|| {
            GitError::unsafe_state(
                coordinates.worktree(),
                "remote Git bundle has no exact pack payload",
            )
        })?;
        let lock = acquire_lock(coordinates)?;
        let root = GitBundleQuarantineRoot::prepare(coordinates)?;
        let runner = coordinates.quarantine_runner(root.path())?;
        let process_limits = process_limits(coordinates.worktree(), limits)?;
        let output = runner.contract_resource_limited_with_input(
            [
                "index-pack",
                "--stdin",
                "--fix-thin",
                "--strict",
                "--fsck-objects",
                "--no-rev-index",
            ],
            pack,
            256,
            process_limits,
        )?;
        let pack_hash = parse_pack_hash(coordinates, &output)?;
        let quarantine = Self {
            coordinates,
            root,
            pack_hash,
            limits,
            _lock: lock,
        };
        quarantine.require_full_pack_contract(limits)?;
        Ok(quarantine)
    }

    pub(crate) fn runner(&self) -> GitResult<GitCommandRunner<'_>> {
        self.coordinates.quarantine_runner(self.root.path())
    }

    pub(crate) fn promote(&self, bundle: &[u8]) -> GitResult<()> {
        self.coordinates.require_current()?;
        let pack = bundle_pack(bundle).ok_or_else(|| {
            GitError::unsafe_state(
                self.coordinates.worktree(),
                "remote Git bundle pack disappeared before promotion",
            )
        })?;
        let output = self
            .coordinates
            .runner()?
            .mutation_resource_limited_with_input(
                [
                    "index-pack",
                    "--stdin",
                    "--fix-thin",
                    "--strict",
                    "--fsck-objects",
                    "--no-rev-index",
                ],
                pack,
                256,
                process_limits(self.coordinates.worktree(), self.limits)?,
            )?;
        if parse_pack_hash(self.coordinates, &output)? == self.pack_hash {
            Ok(())
        } else {
            Err(GitError::mutation(
                self.coordinates.worktree(),
                "promoted Git pack differs from its validated quarantine",
            ))
        }
    }

    pub(crate) fn cleanup(&self) -> GitResult<()> {
        remove_quarantine(self.root.path())
            .map_err(|error| GitError::read(self.coordinates.worktree(), error))
    }

    fn require_full_pack_contract(&self, limits: GitBundleContentLimits) -> GitResult<()> {
        let pack = self
            .root
            .path()
            .join("pack")
            .join(format!("pack-{}.pack", self.pack_hash));
        let expected = pack_object_count(self.coordinates.worktree(), &pack)?;
        let index = pack.with_extension("idx");
        let max_output = verify_pack_output_limit(self.coordinates.worktree(), limits)?;
        let output = self.runner()?.read_resource_limited_stdout(
            ["verify-pack", "-v", "--", path(&index)?],
            max_output,
            process_limits(self.coordinates.worktree(), limits)?,
        )?;
        require_inflated_sizes(
            self.coordinates.worktree(),
            &output.stdout,
            expected,
            self.coordinates.object_format(),
            limits,
        )
    }
}

struct GitBundleQuarantineRoot {
    path: PathBuf,
}

impl GitBundleQuarantineRoot {
    fn prepare(coordinates: &GitRepositoryCoordinates) -> GitResult<Self> {
        let path = coordinates.object_directory().join(QUARANTINE_DIRECTORY);
        reset_quarantine(coordinates.worktree(), &path)?;
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for GitBundleQuarantineRoot {
    fn drop(&mut self) {
        let _ = remove_quarantine(&self.path);
    }
}

fn acquire_lock(coordinates: &GitRepositoryCoordinates) -> GitResult<File> {
    let path = coordinates.object_directory().join(QUARANTINE_LOCK);
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&path)
        .map_err(|error| GitError::read(coordinates.worktree(), error))?;
    lock.lock_exclusive()
        .map_err(|error| GitError::read(coordinates.worktree(), error))?;
    Ok(lock)
}

fn reset_quarantine(worktree: &Path, root: &Path) -> GitResult<()> {
    remove_quarantine(root).map_err(|error| GitError::read(worktree, error))?;
    fs::create_dir_all(root.join("pack")).map_err(|error| GitError::read(worktree, error))
}

fn remove_quarantine(root: &Path) -> io::Result<()> {
    let Ok(metadata) = fs::symlink_metadata(root) else {
        return Ok(());
    };
    if metadata.file_type().is_symlink() || metadata.is_file() {
        fs::remove_file(root)
    } else {
        fs::remove_dir_all(root)
    }
}

fn parse_pack_hash(coordinates: &GitRepositoryCoordinates, output: &Output) -> GitResult<String> {
    let rendered = stdout(output);
    let hash = rendered
        .split_ascii_whitespace()
        .next_back()
        .unwrap_or_default();
    if canonical_oid(hash, coordinates.object_format()) {
        Ok(hash.to_owned())
    } else {
        Err(GitError::unsafe_state(
            coordinates.worktree(),
            "Git index-pack returned a noncanonical pack identity",
        ))
    }
}

fn pack_object_count(worktree: &Path, pack: &Path) -> GitResult<u32> {
    let mut header = [0_u8; 12];
    File::open(pack)
        .and_then(|mut file| file.read_exact(&mut header))
        .map_err(|error| GitError::read(worktree, error))?;
    let version = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);
    if &header[..4] != b"PACK" || !matches!(version, 2 | 3) {
        return Err(GitError::unsafe_state(
            worktree,
            "quarantined Git pack header is noncanonical",
        ));
    }
    Ok(u32::from_be_bytes([
        header[8], header[9], header[10], header[11],
    ]))
}

fn verify_pack_output_limit(worktree: &Path, limits: GitBundleContentLimits) -> GitResult<u64> {
    u64::from(limits.pack_objects)
        .checked_mul(256)
        .and_then(|value| value.checked_add(16 * 1024))
        .ok_or_else(|| GitError::unsafe_state(worktree, "Git pack output limit overflowed"))
}

fn process_limits(worktree: &Path, limits: GitBundleContentLimits) -> GitResult<GitProcessLimits> {
    let file_bytes = limits
        .bundle_bytes
        .checked_add(limits.inflated_pack_bytes)
        .and_then(|value| value.checked_add(16 * 1024 * 1024))
        .ok_or_else(|| resource_error(worktree))?;
    let address_space_bytes = limits
        .inflated_pack_bytes
        .checked_mul(3)
        .and_then(|value| value.checked_add(limits.bundle_bytes))
        .and_then(|value| value.checked_add(64 * 1024 * 1024))
        .ok_or_else(|| resource_error(worktree))?;
    Ok(GitProcessLimits {
        wall_time: Duration::from_secs(30),
        cpu_seconds: 20,
        address_space_bytes,
        // No single Git allocation may exceed the whole inflated-pack budget; this leaves
        // ample headroom over one inflated object yet rejects a delta bomb before inflation.
        alloc_limit_bytes: limits.inflated_pack_bytes,
        file_bytes,
    })
}

fn require_inflated_sizes(
    worktree: &Path,
    output: &[u8],
    expected: u32,
    object_format: &str,
    limits: GitBundleContentLimits,
) -> GitResult<()> {
    let text = str::from_utf8(output)
        .map_err(|_| GitError::unsafe_state(worktree, "Git pack index output is not UTF-8"))?;
    let mut objects = HashSet::new();
    let mut total = 0_u64;
    for line in text.lines() {
        let fields = line.split_ascii_whitespace().collect::<Vec<_>>();
        let Some(oid) = fields.first().copied() else {
            continue;
        };
        if !canonical_oid(oid, object_format) {
            continue;
        }
        let size = parse_object_row(worktree, &fields)?;
        if !objects.insert(oid) || size > limits.inflated_object_bytes {
            return Err(inflated_error(worktree));
        }
        total = total
            .checked_add(size)
            .filter(|value| *value <= limits.inflated_pack_bytes)
            .ok_or_else(|| inflated_error(worktree))?;
    }
    if objects.len() == usize::try_from(expected).unwrap_or(usize::MAX) {
        Ok(())
    } else {
        Err(inflated_error(worktree))
    }
}

fn parse_object_row(worktree: &Path, fields: &[&str]) -> GitResult<u64> {
    let exact = matches!(fields.len(), 5 | 7)
        && fields
            .get(1)
            .is_some_and(|kind| matches!(*kind, "blob" | "tree" | "commit" | "tag"));
    if !exact {
        return Err(inflated_error(worktree));
    }
    fields
        .get(2)
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| inflated_error(worktree))
}

fn canonical_oid(value: &str, object_format: &str) -> bool {
    let expected = if object_format == "sha256" { 64 } else { 40 };
    value.len() == expected
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn inflated_error(worktree: &Path) -> GitError {
    GitError::unsafe_state(
        worktree,
        "remote Git bundle exceeds its full-pack inflated-byte contract",
    )
}

fn resource_error(worktree: &Path) -> GitError {
    GitError::unsafe_state(worktree, "remote Git resource limit overflowed")
}

fn path(path: &Path) -> GitResult<&str> {
    path.to_str()
        .ok_or_else(|| GitError::unsafe_state(path, "Git pack index path is not UTF-8"))
}

#[cfg(test)]
#[path = "bundle_quarantine/tests.rs"]
mod tests;
