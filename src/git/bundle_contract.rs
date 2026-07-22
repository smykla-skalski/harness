use std::path::Path;
use std::str;

use super::command::GitCommandRunner;
use crate::git::{GitError, GitResult};

pub(crate) const MAX_REMOTE_GIT_BUNDLE_BYTES: u64 = 32 * 1024 * 1024;
pub(crate) const MAX_REMOTE_GIT_BUNDLE_OBJECTS: u32 = 100_000;
pub(crate) const MAX_REMOTE_GIT_CHANGED_PATHS: usize = 10_000;
pub(crate) const MAX_REMOTE_GIT_CHANGED_BLOB_BYTES: u64 = 64 * 1024 * 1024;
pub(crate) const MAX_REMOTE_GIT_INFLATED_OBJECT_BYTES: u64 = 64 * 1024 * 1024;
pub(crate) const MAX_REMOTE_GIT_INFLATED_PACK_BYTES: u64 = 128 * 1024 * 1024;
const MAX_CHANGED_PATH_BYTES: u64 = 4096;
#[path = "bundle_contract/io.rs"]
mod io;
#[path = "bundle_contract/symlink.rs"]
mod symlink;
pub(crate) use io::read_bounded_bundle_file;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(clippy::struct_field_names)]
pub(crate) struct GitBundleContentLimits {
    pub(crate) max_bundle_bytes: u64,
    pub(crate) max_pack_objects: u32,
    pub(crate) max_changed_paths: usize,
    pub(crate) max_changed_blob_bytes: u64,
    pub(crate) max_inflated_object_bytes: u64,
    pub(crate) max_inflated_pack_bytes: u64,
}

impl GitBundleContentLimits {
    pub(crate) const REMOTE_RESULT: Self = Self {
        max_bundle_bytes: MAX_REMOTE_GIT_BUNDLE_BYTES,
        max_pack_objects: MAX_REMOTE_GIT_BUNDLE_OBJECTS,
        max_changed_paths: MAX_REMOTE_GIT_CHANGED_PATHS,
        max_changed_blob_bytes: MAX_REMOTE_GIT_CHANGED_BLOB_BYTES,
        max_inflated_object_bytes: MAX_REMOTE_GIT_INFLATED_OBJECT_BYTES,
        max_inflated_pack_bytes: MAX_REMOTE_GIT_INFLATED_PACK_BYTES,
    };
}

pub(crate) fn require_bounded_bundle(
    repository: &Path,
    bytes: &[u8],
    limits: GitBundleContentLimits,
) -> GitResult<()> {
    let size = u64::try_from(bytes.len())
        .map_err(|_| GitError::unsafe_state(repository, "remote Git bundle length overflowed"))?;
    let pack = bundle_pack(bytes).ok_or_else(|| {
        GitError::unsafe_state(repository, "remote Git bundle has no exact pack header")
    })?;
    let version = u32::from_be_bytes([pack[4], pack[5], pack[6], pack[7]]);
    let objects = u32::from_be_bytes([pack[8], pack[9], pack[10], pack[11]]);
    if size == 0
        || size > limits.max_bundle_bytes
        || !matches!(version, 2 | 3)
        || objects == 0
        || objects > limits.max_pack_objects
    {
        return Err(GitError::unsafe_state(
            repository,
            "remote Git bundle exceeds its bounded pack contract",
        ));
    }
    Ok(())
}

pub(crate) fn require_self_contained_bundle(repository: &Path, bytes: &[u8]) -> GitResult<()> {
    let header_end = bytes
        .windows(2)
        .position(|window| window == b"\n\n")
        .ok_or_else(|| GitError::read(repository, "source bundle header is incomplete"))?;
    let header = bytes
        .get(..header_end)
        .ok_or_else(|| GitError::read(repository, "source bundle header is invalid"))?;
    if header
        .split(|byte| *byte == b'\n')
        .any(|line| line.starts_with(b"-"))
    {
        Err(GitError::unsafe_state(
            repository,
            "source bundle unexpectedly requires prerequisite objects",
        ))
    } else {
        Ok(())
    }
}

pub(crate) fn require_bounded_result_delta(
    repository: &Path,
    base_revision: &str,
    result_revision: &str,
    limits: GitBundleContentLimits,
) -> GitResult<()> {
    let runner = GitCommandRunner::new(repository);
    require_bounded_result_delta_with_runner(
        repository,
        &runner,
        base_revision,
        result_revision,
        limits,
    )
}

pub(super) fn require_bounded_result_delta_with_runner(
    repository: &Path,
    runner: &GitCommandRunner<'_>,
    base_revision: &str,
    result_revision: &str,
    limits: GitBundleContentLimits,
) -> GitResult<()> {
    let output = runner.read_bounded_stdout(
        [
            "diff-tree",
            "-r",
            "--no-commit-id",
            "--raw",
            "-z",
            "--no-renames",
            base_revision,
            result_revision,
        ],
        delta_output_limit(repository, result_revision.len(), limits)?,
    )?;
    let entries = parse_delta(repository, &output.stdout, result_revision.len(), limits)?;
    let symlinks = require_bounded_objects(repository, runner, &entries, limits)?;
    symlink::require_safe(repository, runner, &symlinks)?;
    require_checkout_without_external_filters(repository, runner, result_revision, &entries)
}

pub(crate) fn require_bounded_revision_tree(
    repository: &Path,
    revision: &str,
    limits: GitBundleContentLimits,
) -> GitResult<()> {
    let runner = GitCommandRunner::new(repository);
    require_bounded_revision_tree_with_runner(repository, &runner, revision, limits)
}

pub(super) fn require_bounded_revision_tree_with_runner(
    repository: &Path,
    runner: &GitCommandRunner<'_>,
    revision: &str,
    limits: GitBundleContentLimits,
) -> GitResult<()> {
    let output = runner.read_bounded_stdout(
        ["ls-tree", "-r", "-z", "--full-tree", revision],
        tree_output_limit(repository, revision.len(), limits)?,
    )?;
    let entries = parse_tree(repository, &output.stdout, revision.len(), limits)?;
    let source_symlinks = require_bounded_objects(repository, runner, &entries, limits)?;
    // This snapshot checks out on the executor host, so its symlinks need the same
    // escape/absolute-target guard the result-delta path applies; an unchecked one
    // in the base revision would resolve outside the worktree.
    symlink::require_safe(repository, runner, &source_symlinks)?;
    require_checkout_without_external_filters(repository, runner, revision, &entries)
}

pub(super) fn bundle_pack(bytes: &[u8]) -> Option<&[u8]> {
    let header_end = bytes.windows(2).position(|window| window == b"\n\n")? + 2;
    let pack = bytes.get(header_end..)?;
    (pack.len() >= 12 && &pack[..4] == b"PACK").then_some(pack)
}

#[derive(Debug, PartialEq, Eq)]
struct ChangedPath {
    path: Vec<u8>,
    object_id: Option<String>,
    gitlink: bool,
    symlink: bool,
}

fn parse_delta(
    repository: &Path,
    output: &[u8],
    oid_len: usize,
    limits: GitBundleContentLimits,
) -> GitResult<Vec<ChangedPath>> {
    let chunks = nul_chunks(output);
    let mut entries = Vec::new();
    for pair in chunks.chunks(2) {
        let [header, path] = pair else {
            return Err(delta_error(repository));
        };
        if entries.len() == limits.max_changed_paths
            || path.is_empty()
            || u64::try_from(path.len())
                .ok()
                .is_none_or(|size| size > MAX_CHANGED_PATH_BYTES)
        {
            return Err(GitError::unsafe_state(
                repository,
                "remote Git result exceeds its changed-path contract",
            ));
        }
        entries.push(parse_delta_entry(repository, header, path, oid_len)?);
    }
    Ok(entries)
}

fn parse_delta_entry(
    repository: &Path,
    header: &[u8],
    path: &[u8],
    oid_len: usize,
) -> GitResult<ChangedPath> {
    let header = str::from_utf8(header).map_err(|_| delta_error(repository))?;
    let fields = header.split(' ').collect::<Vec<_>>();
    let old_mode = fields
        .first()
        .and_then(|value| value.strip_prefix(':'))
        .unwrap_or_default();
    let valid = fields.len() == 5
        && canonical_mode(old_mode)
        && canonical_mode(fields[1])
        && canonical_or_zero_oid(fields[2], oid_len)
        && matches!(fields[4], "A" | "D" | "M" | "T")
        && canonical_tree_path(path);
    if !valid {
        return Err(delta_error(repository));
    }
    let mode = fields[1];
    let object_id = fields[3];
    let deleted = mode == "000000" && object_id.bytes().all(|byte| byte == b'0');
    let materialized =
        matches!(mode, "100644" | "100755" | "120000") && canonical_oid(object_id, oid_len);
    if !deleted && !materialized {
        return Err(delta_error(repository));
    }
    Ok(ChangedPath {
        path: path.to_vec(),
        object_id: (!deleted).then(|| object_id.to_owned()),
        gitlink: false,
        symlink: mode == "120000",
    })
}

fn parse_tree(
    repository: &Path,
    output: &[u8],
    oid_len: usize,
    limits: GitBundleContentLimits,
) -> GitResult<Vec<ChangedPath>> {
    let mut entries = Vec::new();
    for row in nul_chunks(output) {
        if entries.len() == limits.max_changed_paths {
            return Err(tree_error(repository));
        }
        entries.push(parse_tree_entry(repository, row, oid_len)?);
    }
    Ok(entries)
}

fn parse_tree_entry(repository: &Path, row: &[u8], oid_len: usize) -> GitResult<ChangedPath> {
    let separator = row
        .iter()
        .position(|byte| *byte == b'\t')
        .ok_or_else(|| tree_error(repository))?;
    let (header, path) = row.split_at(separator);
    let path = path.get(1..).ok_or_else(|| tree_error(repository))?;
    let fields = str::from_utf8(header)
        .map_err(|_| tree_error(repository))?
        .split(' ')
        .collect::<Vec<_>>();
    let mode = fields.first().copied().unwrap_or_default();
    let gitlink = false;
    let expected_type = "blob";
    let exact = fields.len() == 3
        && matches!(mode, "100644" | "100755" | "120000")
        && fields.get(1).copied() == Some(expected_type)
        && fields.get(2).is_some_and(|oid| canonical_oid(oid, oid_len))
        && canonical_tree_path(path);
    if !exact {
        return Err(tree_error(repository));
    }
    Ok(ChangedPath {
        path: path.to_vec(),
        object_id: fields.get(2).map(|value| (*value).to_owned()),
        gitlink,
        symlink: mode == "120000",
    })
}

fn require_bounded_objects<'a>(
    repository: &Path,
    runner: &GitCommandRunner<'_>,
    entries: &'a [ChangedPath],
    limits: GitBundleContentLimits,
) -> GitResult<Vec<(&'a ChangedPath, u64)>> {
    let mut input = Vec::new();
    let expected = entries
        .iter()
        .filter_map(|entry| entry.object_id.as_ref().map(|oid| (entry, oid)))
        .collect::<Vec<_>>();
    for (_, object_id) in &expected {
        input.extend_from_slice(object_id.as_bytes());
        input.push(b'\n');
    }
    let output = runner.read_bounded_stdout_with_input(
        [
            "cat-file",
            "--batch-check=%(objectname) %(objecttype) %(objectsize)",
        ],
        &input,
        object_output_limit(repository, &expected)?,
    )?;
    let rows = str::from_utf8(&output.stdout)
        .map_err(|_| delta_error(repository))?
        .lines()
        .collect::<Vec<_>>();
    if rows.len() != expected.len() {
        return Err(delta_error(repository));
    }
    let mut total = 0_u64;
    let mut symlinks = Vec::new();
    for (row, (entry, expected_oid)) in rows.iter().zip(expected) {
        let fields = row.split(' ').collect::<Vec<_>>();
        let size = fields.get(2).and_then(|value| value.parse::<u64>().ok());
        let expected_type = if entry.gitlink { "commit" } else { "blob" };
        let exact = fields.first() == Some(&expected_oid.as_str())
            && fields.get(1) == Some(&expected_type)
            && size.is_some();
        if !exact {
            return Err(delta_error(repository));
        }
        if !entry.gitlink {
            let Some(size) = size else {
                return Err(delta_error(repository));
            };
            total = total
                .checked_add(size)
                .filter(|value| *value <= limits.max_changed_blob_bytes)
                .ok_or_else(|| {
                    GitError::unsafe_state(
                        repository,
                        "remote Git result exceeds its materialized-byte contract",
                    )
                })?;
        }
        if entry.symlink {
            let size = size.ok_or_else(|| delta_error(repository))?;
            symlinks.push((entry, size));
        }
    }
    Ok(symlinks)
}

fn require_checkout_without_external_filters(
    repository: &Path,
    runner: &GitCommandRunner<'_>,
    result_revision: &str,
    entries: &[ChangedPath],
) -> GitResult<()> {
    let mut input = Vec::new();
    for entry in entries.iter().filter(|entry| entry.object_id.is_some()) {
        input.extend_from_slice(&entry.path);
        input.push(0);
    }
    let source = format!("--source={result_revision}");
    let output = runner.read_bounded_stdout_with_input(
        [
            "check-attr",
            "-z",
            source.as_str(),
            "--stdin",
            "filter",
            "working-tree-encoding",
        ],
        &input,
        attribute_output_limit(repository, entries)?,
    )?;
    let values = nul_chunks(&output.stdout);
    let mut path_count = 0_usize;
    for byte in &input {
        if *byte == 0 {
            path_count += 1;
        }
    }
    if values.len() != path_count * 6
        || values.chunks(3).any(|triple| {
            triple.len() != 3
                || (triple[1] != b"filter" && triple[1] != b"working-tree-encoding")
                || (triple[2] != b"unspecified" && triple[2] != b"unset")
        })
    {
        return Err(GitError::unsafe_state(
            repository,
            "remote Git result requires an external checkout transformation",
        ));
    }
    Ok(())
}

fn delta_output_limit(
    repository: &Path,
    oid_len: usize,
    limits: GitBundleContentLimits,
) -> GitResult<u64> {
    let oid_len = u64::try_from(oid_len).map_err(|_| delta_error(repository))?;
    let paths = u64::try_from(limits.max_changed_paths).map_err(|_| delta_error(repository))?;
    let entry_bytes = MAX_CHANGED_PATH_BYTES
        .checked_add(20)
        .and_then(|value| value.checked_add(oid_len.checked_mul(2)?))
        .ok_or_else(|| delta_error(repository))?;
    paths
        .checked_mul(entry_bytes)
        .ok_or_else(|| delta_error(repository))
}

fn tree_output_limit(
    repository: &Path,
    oid_len: usize,
    limits: GitBundleContentLimits,
) -> GitResult<u64> {
    let oid_len = u64::try_from(oid_len).map_err(|_| tree_error(repository))?;
    let paths = u64::try_from(limits.max_changed_paths).map_err(|_| tree_error(repository))?;
    let row_bytes = MAX_CHANGED_PATH_BYTES
        .checked_add(16)
        .and_then(|value| value.checked_add(oid_len))
        .ok_or_else(|| tree_error(repository))?;
    paths
        .checked_mul(row_bytes)
        .ok_or_else(|| tree_error(repository))
}

fn object_output_limit(repository: &Path, expected: &[(&ChangedPath, &String)]) -> GitResult<u64> {
    let oid_len = expected.first().map_or(64, |(_, oid)| oid.len());
    let row_bytes = u64::try_from(oid_len)
        .ok()
        .and_then(|value| value.checked_add(29))
        .ok_or_else(|| delta_error(repository))?;
    u64::try_from(expected.len())
        .ok()
        .and_then(|rows| rows.checked_mul(row_bytes))
        .ok_or_else(|| delta_error(repository))
}

fn attribute_output_limit(repository: &Path, entries: &[ChangedPath]) -> GitResult<u64> {
    entries
        .iter()
        .filter(|entry| entry.object_id.is_some())
        .try_fold(0_u64, |total, entry| {
            u64::try_from(entry.path.len())
                .ok()
                .and_then(|path| path.checked_mul(2))
                .and_then(|path| path.checked_add(55))
                .and_then(|row| total.checked_add(row))
                .ok_or_else(|| delta_error(repository))
        })
}

fn nul_chunks(bytes: &[u8]) -> Vec<&[u8]> {
    let mut chunks = bytes.split(|byte| *byte == 0).collect::<Vec<_>>();
    if chunks.last().is_some_and(|chunk| chunk.is_empty()) {
        chunks.pop();
    }
    chunks
}

fn canonical_mode(value: &str) -> bool {
    matches!(value, "000000" | "100644" | "100755" | "120000" | "160000")
}

fn canonical_tree_path(path: &[u8]) -> bool {
    !path.is_empty()
        && u64::try_from(path.len())
            .ok()
            .is_some_and(|size| size <= MAX_CHANGED_PATH_BYTES)
        && !path.starts_with(b"/")
        && !path.ends_with(b"/")
        && path.split(|byte| *byte == b'/').all(|part| {
            !part.is_empty()
                && part != b"."
                && part != b".."
                && !is_git_administration_component(part)
        })
}

fn is_git_administration_component(component: &[u8]) -> bool {
    component.eq_ignore_ascii_case(b".git")
}

fn canonical_or_zero_oid(value: &str, expected_len: usize) -> bool {
    canonical_oid(value, expected_len)
        || (value.len() == expected_len && value.bytes().all(|byte| byte == b'0'))
}

fn canonical_oid(value: &str, expected_len: usize) -> bool {
    value.len() == expected_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn delta_error(repository: &Path) -> GitError {
    GitError::unsafe_state(repository, "remote Git result delta is noncanonical")
}

fn tree_error(repository: &Path) -> GitError {
    GitError::unsafe_state(repository, "remote Git source tree is noncanonical")
}

#[cfg(test)]
#[path = "bundle_contract/tests.rs"]
mod tests;
