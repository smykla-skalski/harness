#![allow(dead_code)]

use std::error::Error as StdError;
use std::fmt::Display;
use std::path::{Path, PathBuf};

use thiserror::Error;

#[path = "../../../src/git/bundle.rs"]
pub(crate) mod bundle;
#[path = "../../../src/git/bundle_contract.rs"]
pub(crate) mod bundle_contract;
#[path = "../../../src/git/bundle_export.rs"]
pub(crate) mod bundle_export;
#[path = "../../../src/git/bundle_quarantine.rs"]
mod bundle_quarantine;
#[path = "../../../src/git/bundle_staging.rs"]
mod bundle_staging;
#[path = "../../../src/git/command.rs"]
mod command;
#[path = "../../../src/git/identity.rs"]
pub(crate) mod identity;
#[path = "../../../src/git/mutation.rs"]
pub(crate) mod mutation;
#[path = "../../../src/git/read.rs"]
pub(crate) mod read;
#[path = "../../../src/git/repository_coordinates.rs"]
mod repository_coordinates;
#[path = "../../../src/git/source_bundle_export.rs"]
pub(crate) mod source_bundle_export;
#[path = "../../../src/git/source_bundle_import.rs"]
pub(crate) mod source_bundle_import;
#[path = "../../../src/git/source_repository_identity.rs"]
mod source_repository_identity;

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
    #[error("git state is unsafe for {path}: {message}")]
    Unsafe { path: PathBuf, message: String },
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

    pub(crate) fn unsafe_state(path: &Path, error: impl Display) -> Self {
        Self::Unsafe {
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
