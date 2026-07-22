use std::path::Path;

use super::ChangedPath;
use crate::git::command::GitCommandRunner;
use crate::git::{GitError, GitResult};

pub(super) const MAX_TARGET_BYTES: u64 = 4096;

pub(super) fn require_safe(
    repository: &Path,
    runner: &GitCommandRunner<'_>,
    symlinks: &[(&ChangedPath, u64)],
) -> GitResult<()> {
    if symlinks.is_empty() {
        return Ok(());
    }
    let mut input = Vec::new();
    for (entry, size) in symlinks {
        if *size == 0 || *size > MAX_TARGET_BYTES {
            return Err(error(repository));
        }
        input.extend_from_slice(entry.object_id.as_deref().unwrap_or_default().as_bytes());
        input.push(b'\n');
    }
    let output = runner.read_bounded_stdout_with_input(
        ["cat-file", "--batch"],
        &input,
        output_limit(repository, symlinks)?,
    )?;
    parse_batch(repository, &output.stdout, symlinks)
}

fn parse_batch(
    repository: &Path,
    output: &[u8],
    symlinks: &[(&ChangedPath, u64)],
) -> GitResult<()> {
    let mut remaining = output;
    for (entry, size) in symlinks {
        let newline = remaining
            .iter()
            .position(|byte| *byte == b'\n')
            .ok_or_else(|| error(repository))?;
        let header = std::str::from_utf8(&remaining[..newline]).map_err(|_| error(repository))?;
        let fields = header.split(' ').collect::<Vec<_>>();
        let exact = fields.len() == 3
            && fields.first().copied() == entry.object_id.as_deref()
            && fields.get(1).copied() == Some("blob")
            && fields.get(2).and_then(|value| value.parse::<u64>().ok()) == Some(*size);
        let content_start = newline + 1;
        let content_end = content_start
            .checked_add(usize::try_from(*size).map_err(|_| error(repository))?)
            .ok_or_else(|| error(repository))?;
        let target = remaining
            .get(content_start..content_end)
            .ok_or_else(|| error(repository))?;
        if !exact || remaining.get(content_end) != Some(&b'\n') || !safe_target(&entry.path, target)
        {
            return Err(error(repository));
        }
        remaining = remaining
            .get(content_end + 1..)
            .ok_or_else(|| error(repository))?;
    }
    if remaining.is_empty() {
        Ok(())
    } else {
        Err(error(repository))
    }
}

fn safe_target(link_path: &[u8], target: &[u8]) -> bool {
    if target.is_empty()
        || target.contains(&0)
        || target.contains(&b'\\')
        || target.starts_with(b"/")
    {
        return false;
    }
    let mut depth = link_path
        .split(|byte| *byte == b'/')
        .count()
        .saturating_sub(1);
    for component in target.split(|byte| *byte == b'/') {
        match component {
            b"" | b"." => {}
            b".." if depth == 0 => return false,
            b".." => depth -= 1,
            _ => depth += 1,
        }
    }
    true
}

fn output_limit(repository: &Path, symlinks: &[(&ChangedPath, u64)]) -> GitResult<u64> {
    symlinks.iter().try_fold(0_u64, |total, (entry, size)| {
        let oid = entry.object_id.as_deref().unwrap_or_default();
        u64::try_from(oid.len())
            .ok()
            .and_then(|oid| oid.checked_add(32))
            .and_then(|header| header.checked_add(*size))
            .and_then(|row| total.checked_add(row))
            .ok_or_else(|| error(repository))
    })
}

pub(super) fn error(repository: &Path) -> GitError {
    GitError::unsafe_state(
        repository,
        "remote Git result contains an unsafe symbolic-link target",
    )
}
