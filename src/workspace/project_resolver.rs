//! Project directory name resolution with collision handling.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use thiserror::Error;

const ORIGIN_MARKER: &str = ".origin";
const SUFFIX_LEN: usize = 4;

#[derive(Debug, Error)]
pub enum ResolverError {
    #[error("I/O: {0}")]
    Io(#[from] io::Error),
    #[error("canonical path has no file name: {0:?}")]
    NoBasename(PathBuf),
}

/// # Errors
/// Returns `ResolverError::Io` on filesystem errors, `ResolverError::NoBasename` when canonical path lacks a basename.
pub fn resolve_name(canonical_path: &Path, sessions_root: &Path) -> Result<String, ResolverError> {
    let base = canonical_path
        .file_name()
        .ok_or_else(|| ResolverError::NoBasename(canonical_path.to_path_buf()))?
        .to_string_lossy()
        .into_owned();
    let candidate = sessions_root.join(&base);
    if candidate.exists() {
        if read_origin_marker(&candidate)?.as_deref() == Some(&canonical_path.to_string_lossy()) {
            return Ok(base);
        }
    } else {
        return Ok(base);
    }
    let suffix = digest_suffix(canonical_path);
    Ok(format!("{base}-{suffix}"))
}

/// # Errors
/// Returns `io::Error` on filesystem errors.
pub fn write_origin_marker(project_dir: &Path, canonical_path: &Path) -> io::Result<()> {
    fs::write(
        project_dir.join(ORIGIN_MARKER),
        canonical_path.to_string_lossy().as_bytes(),
    )
}

fn read_origin_marker(project_dir: &Path) -> io::Result<Option<String>> {
    let marker = project_dir.join(ORIGIN_MARKER);
    if !marker.exists() {
        return Ok(None);
    }
    Ok(Some(fs::read_to_string(marker)?.trim().to_string()))
}

fn digest_suffix(canonical_path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(canonical_path.to_string_lossy().as_bytes());
    let hash = hasher.finalize();
    hash.iter()
        .take(SUFFIX_LEN / 2)
        .fold(String::with_capacity(SUFFIX_LEN), |mut acc, b| {
            use std::fmt::Write as _;
            let _ = write!(acc, "{b:02x}");
            acc
        })
}

#[cfg(test)]
mod tests;
