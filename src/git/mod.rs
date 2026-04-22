#![allow(dead_code)]

use std::path::{Path, PathBuf};

use thiserror::Error;

pub(crate) mod identity;
pub(crate) mod mutation;
pub(crate) mod read;

pub(crate) type GitResult<T> = Result<T, GitError>;

#[derive(Debug, Error)]
pub(crate) enum GitError {
    #[error("git repository discovery failed for {path}: {message}")]
    Discover { path: PathBuf, message: String },
    #[error("git repository open failed for {path}: {message}")]
    Open { path: PathBuf, message: String },
}

impl GitError {
    pub(crate) fn discover(path: &Path, error: impl std::error::Error) -> Self {
        Self::Discover {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }

    pub(crate) fn open(path: &Path, error: impl std::error::Error) -> Self {
        Self::Open {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }
}
