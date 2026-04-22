#![allow(dead_code)]

use std::error::Error as StdError;
use std::fmt::Display;
use std::path::{Path, PathBuf};

use thiserror::Error;

pub(crate) mod identity;
pub(crate) mod mutation;
pub(crate) mod read;

pub(crate) use read::GitRepository;

pub(crate) type GitResult<T> = Result<T, GitError>;

#[derive(Debug, Error)]
pub(crate) enum GitError {
    #[error("git repository discovery failed for {path}: {message}")]
    Discover { path: PathBuf, message: String },
    #[error("git repository open failed for {path}: {message}")]
    Open { path: PathBuf, message: String },
    #[error("git read failed for {path}: {message}")]
    Read { path: PathBuf, message: String },
    #[error("git mutation failed for {path}: {message}")]
    Mutation { path: PathBuf, message: String },
}

impl GitError {
    pub(crate) fn discover(path: &Path, error: impl StdError) -> Self {
        Self::Discover {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }

    pub(crate) fn open(path: &Path, error: impl StdError) -> Self {
        Self::Open {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }

    pub(crate) fn read(path: &Path, error: impl Display) -> Self {
        Self::Read {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }

    pub(crate) fn mutation(path: &Path, error: impl Display) -> Self {
        Self::Mutation {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }
}
