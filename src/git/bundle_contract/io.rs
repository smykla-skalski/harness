use std::fs::File;
use std::io::Read as _;
use std::path::Path;

use crate::git::{GitError, GitResult};

pub(crate) fn read_bounded_bundle_file(path: &Path, max_bytes: u64) -> GitResult<Vec<u8>> {
    let file = File::open(path).map_err(|error| GitError::read(path, error))?;
    let metadata = file
        .metadata()
        .map_err(|error| GitError::read(path, error))?;
    if !metadata.file_type().is_file() {
        return Err(GitError::unsafe_state(
            path,
            "remote Git bundle must be a regular file",
        ));
    }
    let capacity = usize::try_from(max_bytes.min(1024 * 1024))
        .map_err(|_| GitError::unsafe_state(path, "remote Git bundle limit overflowed"))?;
    let mut bytes = Vec::with_capacity(capacity);
    file.take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| GitError::read(path, error))?;
    if u64::try_from(bytes.len())
        .ok()
        .is_none_or(|size| size > max_bytes)
    {
        return Err(GitError::unsafe_state(
            path,
            "remote Git bundle exceeds its byte contract",
        ));
    }
    Ok(bytes)
}
