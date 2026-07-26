#![allow(dead_code)]

use std::error::Error as StdError;
use std::fmt::Display;
use std::path::{Path, PathBuf};

use thiserror::Error;

pub mod bundle;
pub mod bundle_contract;
pub mod bundle_export;
mod bundle_quarantine;
mod bundle_staging;
mod command;
pub mod identity;
pub mod mutation;
#[cfg(test)]
mod quarantine_test_support;
pub mod read;
mod repository_coordinates;
pub mod source_bundle_export;
pub mod source_bundle_import;
mod source_repository_identity;

pub use read::GitRepository;

pub type GitResult<T> = Result<T, GitError>;

#[derive(Debug, Error)]
pub enum GitError {
    #[error("git repository discovery failed for {path}: {message}")]
    Discover { path: PathBuf, message: String },
    #[error("git repository open failed for {path}: {message}")]
    Open { path: PathBuf, message: String },
    #[error("git read failed for {path}: {message}")]
    Read { path: PathBuf, message: String },
    #[error("git state is unsafe for {path}: {message}")]
    Unsafe { path: PathBuf, message: String },
    #[error("git mutation failed for {path}: {message}")]
    Mutation { path: PathBuf, message: String },
}

impl GitError {
    pub fn discover(path: &Path, error: impl StdError) -> Self {
        Self::Discover {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }

    pub fn open(path: &Path, error: impl StdError) -> Self {
        Self::Open {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }

    pub fn read(path: &Path, error: impl Display) -> Self {
        Self::Read {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }

    pub fn unsafe_state(path: &Path, error: impl Display) -> Self {
        Self::Unsafe {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }

    pub fn mutation(path: &Path, error: impl Display) -> Self {
        Self::Mutation {
            path: path.to_path_buf(),
            message: error.to_string(),
        }
    }
}
