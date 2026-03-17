use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::errors::{CliError, CliErrorKind};

/// SHA256 digest of a source file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceDigest {
    pub source_path: String,
    pub digest: String,
}

pub(super) fn source_digest(path: &Path, source_path: &str) -> Result<SourceDigest, CliError> {
    Ok(SourceDigest {
        source_path: source_path.to_string(),
        digest: file_sha256(path)?,
    })
}

pub(super) fn file_sha256(path: &Path) -> Result<String, CliError> {
    let bytes = fs::read(path)
        .map_err(|error| CliErrorKind::io(format!("read {}: {error}", path.display())))?;
    let digest = Sha256::digest(&bytes);
    Ok(hex::encode(digest))
}

pub(super) fn text_sha256(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}
